import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import RequestmanCore

/// All access stays on one NIO EventLoop, including peer callbacks. No Task per packet or UI call here.
final class ProxyConnection: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    let configuration: ExplicitProxyConfiguration
    let shared: ProxySharedState
    let records: CaptureRecordBuffer
    let tlsAuthority: String?
    let plainAuthority: String?
    var webSocketRequest = false
    var webSocketUpgrading = false
    var pendingTunnelHead: HTTPRequestHead?
    var pendingWebSocketResponse: HTTPResponseHead?
    var client: Channel?
    var upstream: Channel?
    var timer: Scheduled<Void>?
    var recordTimer: Scheduled<Void>?
    var recordGeneration: UInt64 = 0
    var lastStreamWrite: EventLoopFuture<Void>?
    var sseWaiting = false
    var ssePending: [ByteBuffer] = []
    var certificateTask: Task<Void, Never>?
    var replaySession: ProxyReplaySession?
    var record: CaptureRecord?
    var recordOwnershipTransferred = false
    var started = ContinuousClock.now
    var traceRecorder: TransactionTraceRecorder?
    var transaction: TransactionCoordinator?
    var requestDisposition: ExecutionDisposition = .forward
    var match: WorkflowMatch? { transaction?.match }
    var request: HTTPMessageDraft?
    var response: HTTPMessageDraft?
    var pending: [HTTPServerRequestPart] = []
    var lastRequestWrite: EventLoopFuture<Void>?
    var lastResponseWrite: EventLoopFuture<Void>?
    var responseEnded = false
    var informationalResponse = false
    var connected = false
    var requestEnded = false
    var responseStarted = false
    var finished = false
    var failureMessage: String?
    var isProcessing: Bool { !finished && failureMessage == nil }
    var tunnel = false
    var originalMethod = "GET"
    var requestBodyCollector: CaptureBodyCollector?
    var sentBodyCollector: CaptureBodyCollector?
    var receivedBodyCollector: CaptureBodyCollector?
    var responseBodyCollector: CaptureBodyCollector?
    var requestWriteFailed = false
    var responseWriteFailed = false
    var requestWriteComplete = false
    var responseWriteComplete = false
    var clientKeepsAlive = false
    var responseKeepsAlive = false
    var originKeepsAlive = false
    var upstreamTarget: String?
    var scriptLease: ScriptFlowLease?
    var suspendedFlowControl: ScriptExecutionControl?
    var scriptRequestHead: HTTPRequestHead?
    var scriptRequestDraft: HTTPMessageDraft?
    var scriptResponseDraft: HTTPMessageDraft?
    var readingResponseBodyFile = false
    var scriptRequestBytes = Data()
    var scriptResponseBytes = Data()

    init(configuration: ExplicitProxyConfiguration, shared: ProxySharedState, records: CaptureRecordBuffer, tlsAuthority: String? = nil, plainAuthority: String? = nil) {
        self.configuration = configuration; self.shared = shared; self.records = records
        self.tlsAuthority = tlsAuthority; self.plainAuthority = plainAuthority
    }
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { activate(context) }
    }
    func channelActive(context: ChannelHandlerContext) { activate(context) }
    func activate(_ context: ChannelHandlerContext) {
        guard client == nil else { return }
        client = context.channel
        timer = context.eventLoop.scheduleTask(in: .seconds(30)) { [self] in fail("等待请求超时", status: 504) }
        context.read()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard isProcessing else { return }
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            guard record == nil else { return fail("不支持同一连接上的流水线请求", status: 400) }
            begin(head)
        case .body(let buffer):
            record?.requestBytes += buffer.readableBytes
            requestBodyCollector?.append(buffer.readableBytesView)
            if scriptRequestHead != nil {
                scriptRequestBytes.append(contentsOf: buffer.readableBytesView)
            } else if !connected { enqueue(part) } else { forward(part) }
        case .end:
            requestEnded = true
            if let head = pendingTunnelHead {
                pendingTunnelHead = nil
                context.eventLoop.execute { [self] in if isProcessing { beginTunnel(head) } }
                return
            }
            if let head = scriptRequestHead, var draft = scriptRequestDraft {
                scriptRequestHead = nil; scriptRequestDraft = nil
                draft.bodyData = scriptRequestBytes
                pending = [.body(context.channel.allocator.buffer(bytes: scriptRequestBytes)), .end(nil)]
                scriptRequestBytes = Data()
                executeScriptFlow(response: false, draft: draft) { [self, head] result in
                    do { try continueRequest(head, draft: result) }
                    catch { fail(error.localizedDescription, status: 400) }
                }
                return
            }
            if !connected { enqueue(part) } else { forward(part) }
        }
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        guard isProcessing, !tunnel else { return }
        // A header can span multiple socket reads before the decoder emits its head.
        if record == nil { context.read(); return }
        if scriptRequestHead != nil { context.read(); return }
        guard connected else { return }
        flushRequest()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if record == nil, let tlsAuthority {
            // Browsers may close a speculative or idle TLS connection without close_notify.
            // NIOSSL reports EOF during an actual handshake as handshakeFailed instead.
            if error as? NIOSSLError == .uncleanShutdown {
                finish()
                context.close(promise: nil)
                return
            }
            record = CaptureRecord(method: "CONNECT", url: "https://" + tlsAuthority)
            finish(error: "客户端 TLS 连接失败：" + ProxyTLS.errorDescription(error))
            context.close(promise: nil)
        } else { fail(ProxyTLS.errorDescription(error), status: 400) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        timer?.cancel(); certificateTask?.cancel()
        if !finished {
            if record?.captureProtocol == .sse { record?.closeReason = shared.isStopping ? "捕获已停止" : "客户端已关闭连接"; finish() }
            else { finish(error: "客户端连接已关闭") }
        }
        if let upstream { closeProxyChannel(upstream) }
    }
    func prepareNextRequest() {
        if !originKeepsAlive, let previous = upstream {
            upstream = nil; upstreamTarget = nil
            closeProxyChannel(previous)
        }
        recordTimer?.cancel(); recordTimer = nil
        webSocketRequest = false; webSocketUpgrading = false
        lastStreamWrite = nil; sseWaiting = false; ssePending.removeAll()
        transaction?.cancel()
        transaction = nil; traceRecorder = nil; requestDisposition = .forward
        replaySession = nil
        record = nil; recordOwnershipTransferred = false; request = nil; response = nil
        scriptLease?.control.cancel()
        scriptLease = nil; scriptRequestHead = nil; scriptRequestDraft = nil; scriptResponseDraft = nil
        scriptRequestBytes = Data(); scriptResponseBytes = Data(); readingResponseBodyFile = false
        pending.removeAll(keepingCapacity: true)
        lastRequestWrite = nil; lastResponseWrite = nil
        requestBodyCollector = nil; sentBodyCollector = nil
        receivedBodyCollector = nil; responseBodyCollector = nil
        connected = false; requestEnded = false; responseStarted = false; responseEnded = false
        informationalResponse = false; finished = false; failureMessage = nil
        requestWriteFailed = false; responseWriteFailed = false
        requestWriteComplete = false; responseWriteComplete = false
        clientKeepsAlive = false; responseKeepsAlive = false; originKeepsAlive = false
        // Idle keep-alive sockets are bounded by the existing connection limit.
        // Expiry closes quietly rather than creating a fictitious failed request.
        if let client {
            timer = client.eventLoop.scheduleTask(in: .seconds(30)) { closeProxyChannel(client) }
            upstream?.read() // Observe an origin's idle FIN before considering reuse.
            client.read()
        }
    }

}
