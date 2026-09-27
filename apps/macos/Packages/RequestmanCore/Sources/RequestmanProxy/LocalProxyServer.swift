import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOWebSocket
import CryptoKit
import RequestmanCertificates
import RequestmanCore
import os

/// Explicit loopback proxy. Every connection handler is confined to the group's single event loop.
public actor LocalProxyServer {
    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private let shared: ProxySharedState
    public nonisolated let records = CaptureRecordBuffer()
    public nonisolated var ruleHitNotifications: RuleHitNotificationBuffer { shared.ruleHitNotifications }
    public init(certificateProvider: (any TLSCertificateProviding)? = nil) {
        shared = ProxySharedState(certificateProvider: certificateProvider)
    }
    // In-memory test anchors only. Production always evaluates the macOS trust store.
    init(certificateProvider: any TLSCertificateProviding, upstreamTrustRoots: [NIOSSLCertificate]) {
        shared = ProxySharedState(certificateProvider: certificateProvider, upstreamTrustRoots: upstreamTrustRoots)
    }
    public func update(_ document: WorkspaceDocument) { shared.document.withLock { $0 = document } }
    public func updateConfiguration(_ configuration: ExplicitProxyConfiguration) throws {
        try configuration.validate()
        guard listener?.localAddress?.port == configuration.port else {
            throw WorkflowError.invalid("监听端口变更需要切换监听")
        }
        shared.configuration.withLock { $0 = configuration }
    }
    public func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        guard listener == nil, group == nil else { throw WorkflowError.invalid("代理已启动") }
        try configuration.validate()
        update(document)
        shared.configuration.withLock { $0 = configuration }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        shared.prepareForStart()
        let shared = shared, records = records
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: Int32(ProxySharedState.maximumConnections))
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
                .childChannelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 16_384, high: 65_536))
                .childChannelInitializer { channel in
                    guard shared.register(channel) else {
                        var record = CaptureRecord(method: "—", url: "连接未受理")
                        record.outcome = .failed; record.workflow = "连接容量上限"
                        record.error = "当前已有 \(ProxySharedState.maximumConnections) 个连接"
                        records.append(record)
                        return channel.close()
                    }
                    return channel.eventLoop.makeCompletedFuture { () throws -> Void in
                        var encoder = HTTPResponseEncoder.Configuration()
                        encoder.automaticallySetFramingHeaders = false
                        try channel.pipeline.syncOperations.addHandlers([
                            HTTPResponseEncoder(configuration: encoder),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes, limitConfiguration: proxyDecoderLimits())),
                            ProxyConnection(configuration: shared.configuration.withLock { $0 }, shared: shared, records: records)
                        ])
                    }
                }.bind(host: "127.0.0.1", port: configuration.port).get()
            listener = channel
            return channel.localAddress?.port ?? configuration.port
        } catch {
            try? await group.shutdownGracefully()
            self.group = nil
            throw error
        }
    }
    public func stop() async {
        try? await listener?.close().get()
        listener = nil
        // Stop is cancellation: close every transport without waiting for peer TLS close_notify.
        // Initiate all closes before awaiting them, including upstreams still connecting or closing.
        let closes = shared.beginShutdown().map { channel in
            channel.eventLoop.flatSubmit {
                if let tls = try? channel.pipeline.syncOperations.context(handlerType: NIOSSLHandler.self) {
                    tls.close(promise: nil)
                } else {
                    channel.close(promise: nil)
                }
                return channel.closeFuture
            }
        }
        for close in closes { try? await close.get() }
        try? await group?.shutdownGracefully()
        group = nil
    }
}

final class ProxySharedState: Sendable {
    static let maximumConnections = 256
    let ruleHitNotifications = RuleHitNotificationBuffer()
    let tlsContexts = ProxyTLSContexts()
    let certificateProvider: (any TLSCertificateProviding)?
    let upstreamTrustRoots: [NIOSSLCertificate]?
    init(certificateProvider: (any TLSCertificateProviding)? = nil, upstreamTrustRoots: [NIOSSLCertificate]? = nil) {
        self.certificateProvider = certificateProvider
        self.upstreamTrustRoots = upstreamTrustRoots
    }
    let configuration = OSAllocatedUnfairLock(initialState: ExplicitProxyConfiguration())
    let document = OSAllocatedUnfairLock(initialState: WorkspaceDocument())
    private struct Connections {
        var accepting = true
        var downstream: [ObjectIdentifier: Channel] = [:]
        var upstream: [ObjectIdentifier: Channel] = [:]
    }
    private let connections = OSAllocatedUnfairLock(initialState: Connections())
    var isStopping: Bool { connections.withLock { !$0.accepting } }
    func prepareForStart() { connections.withLock { $0.accepting = true } }
    func beginShutdown() -> [Channel] {
        connections.withLock {
            $0.accepting = false
            // Downstream cancellation records incomplete transactions before upstream teardown.
            return Array($0.downstream.values) + Array($0.upstream.values)
        }
    }
    func register(_ channel: Channel, downstream: Bool = true) -> Bool {
        let registered = connections.withLock { connections in
            guard connections.accepting else { return false }
            if downstream {
                guard connections.downstream.count < Self.maximumConnections else { return false }
                connections.downstream[ObjectIdentifier(channel)] = channel
            } else {
                connections.upstream[ObjectIdentifier(channel)] = channel
            }
            return true
        }
        if registered { channel.closeFuture.whenComplete { [self] _ in unregister(channel) } }
        return registered
    }
    private func unregister(_ channel: Channel) {
        connections.withLock {
            $0.downstream.removeValue(forKey: ObjectIdentifier(channel))
            $0.upstream.removeValue(forKey: ObjectIdentifier(channel))
        }
    }
}

/// All access stays on one NIO EventLoop, including peer callbacks. No Task per packet or UI call here.
final class ProxyConnection: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    private let configuration: ExplicitProxyConfiguration
    private let shared: ProxySharedState
    private let records: CaptureRecordBuffer
    private let tlsAuthority: String?
    private let plainAuthority: String?
    private var webSocketRequest = false
    private var webSocketUpgrading = false
    private var pendingTunnelHead: HTTPRequestHead?
    private var pendingWebSocketResponse: HTTPResponseHead?
    private var client: Channel?
    private var upstream: Channel?
    private var timer: Scheduled<Void>?
    private var recordTimer: Scheduled<Void>?
    private var recordGeneration: UInt64 = 0
    private var lastStreamWrite: EventLoopFuture<Void>?
    private var sseWaiting = false
    private var ssePending: [ByteBuffer] = []
    private var certificateTask: Task<Void, Never>?
    private var record: CaptureRecord?
    private var templateContext: WorkflowTemplateContext?
    private var started = ContinuousClock.now
    private var match: WorkflowMatch?
    private var request: HTTPMessageDraft?
    private var response: HTTPMessageDraft?
    private var pending: [HTTPServerRequestPart] = []
    private var lastRequestWrite: EventLoopFuture<Void>?
    private var lastResponseWrite: EventLoopFuture<Void>?
    private var responseEnded = false
    private var informationalResponse = false
    private var connected = false
    private var requestEnded = false
    private var responseStarted = false
    private var finished = false
    private var failureMessage: String?
    private var isProcessing: Bool { !finished && failureMessage == nil }
    private var tunnel = false
    private var originalMethod = "GET"
    private var requestBodyCollector: CaptureBodyCollector?
    private var sentBodyCollector: CaptureBodyCollector?
    private var receivedBodyCollector: CaptureBodyCollector?
    private var responseBodyCollector: CaptureBodyCollector?
    private var requestWriteFailed = false
    private var responseWriteFailed = false
    private var requestWriteComplete = false
    private var responseWriteComplete = false
    private var clientKeepsAlive = false
    private var responseKeepsAlive = false
    private var originKeepsAlive = false
    private var upstreamTarget: String?
    private var scriptLease: ScriptFlowLease?
    private var suspendedFlowControl: ScriptExecutionControl?
    private var scriptRequestHead: HTTPRequestHead?
    private var scriptRequestDraft: HTTPMessageDraft?
    private var scriptResponseDraft: HTTPMessageDraft?
    private var readingResponseBodyFile = false
    private var scriptRequestBytes = Data()
    private var scriptResponseBytes = Data()

    init(configuration: ExplicitProxyConfiguration, shared: ProxySharedState, records: CaptureRecordBuffer, tlsAuthority: String? = nil, plainAuthority: String? = nil) {
        self.configuration = configuration; self.shared = shared; self.records = records
        self.tlsAuthority = tlsAuthority; self.plainAuthority = plainAuthority
    }
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { activate(context) }
    }
    func channelActive(context: ChannelHandlerContext) { activate(context) }
    private func activate(_ context: ChannelHandlerContext) {
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
    private func enqueue(_ part: HTTPServerRequestPart) {
        guard pending.count < 128 else { return fail("连接预读缓冲已满", status: 503) }
        pending.append(part)
    }
    private func begin(_ input: HTTPRequestHead) {
        guard let client else { return }
        timer?.cancel(); timer = nil
        // Bound tunnel establishment, but do not put a deadline on an HTTP transaction.
        if input.method == .CONNECT {
            timer = client.eventLoop.scheduleTask(in: .seconds(30)) { [self] in fail("CONNECT 建立超时", status: 504) }
        }
        clientKeepsAlive = input.isKeepAlive
        var head = input
        if let authority = tlsAuthority ?? plainAuthority {
            let scheme = tlsAuthority == nil ? "http" : "https"
            let defaultPort = tlsAuthority == nil ? 80 : 443
            let expected = URLComponents(string: scheme + "://" + authority)
            let hostHeader = head.headers["host"]
            let supplied = hostHeader.count == 1 ? URLComponents(string: scheme + "://" + hostHeader[0]) : nil
            let originAuthority = (expected?.percentEncodedHost ?? "")
                + (expected?.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? "")
            let fullURL = head.uri.hasPrefix("/") ? scheme + "://" + originAuthority + head.uri : head.uri
            let target = URLComponents(string: fullURL)
            guard head.method != .CONNECT, target?.scheme == scheme,
                  target?.host?.lowercased() == expected?.host?.lowercased(),
                  (target?.port ?? defaultPort) == (expected?.port ?? defaultPort),
                  supplied?.host?.lowercased() == expected?.host?.lowercased(),
                  (supplied?.port ?? defaultPort) == (expected?.port ?? defaultPort),
                  supplied?.user == nil, supplied?.path.isEmpty == true,
                  supplied?.query == nil, supplied?.fragment == nil else {
                record = CaptureRecord(method: head.method.rawValue, url: fullURL)
                return fail("HTTPS 请求与 CONNECT 目标不一致", status: 400)
            }
            head.uri = fullURL
        }
        if head.uri.hasPrefix("ws://") { head.uri = "http://" + head.uri.dropFirst(5) }
        if head.uri.hasPrefix("wss://") { head.uri = "https://" + head.uri.dropFirst(6) }
        originalMethod = head.method.rawValue
        record = CaptureRecord(method: originalMethod, url: head.uri)
        record?.requestHeaders = fields(head.headers)
        record?.environment = shared.document.withLock { $0.environment?.name ?? "无环境" }
        started = .now
        recordGeneration = records.generation
        record?.connectionState = .connecting
        if head.method == .CONNECT {
            if let previous = upstream {
                upstream = nil; upstreamTarget = nil
                closeProxyChannel(previous)
            }
            record?.requestBody = .unavailable("加密隧道不采集 HTTP 内容")
            record?.sentBody = .unavailable("加密隧道不采集 HTTP 内容")
            record?.receivedBody = .unavailable("加密隧道不采集 HTTP 内容")
            record?.responseBody = .unavailable("加密隧道不采集 HTTP 内容")
            pendingTunnelHead = head
            return
        }
        requestBodyCollector = CaptureBodyCollector(headers: fields(head.headers))
        record?.sentBody = .unavailable("请求未发送至上游")
        record?.receivedBody = .unavailable("尚未收到上游响应")
        webSocketRequest = head.headers["upgrade"].contains { $0.lowercased() == "websocket" }
        guard head.method != .TRACE, head.headers["upgrade"].isEmpty || webSocketRequest else { return fail("不支持此协议升级或 TRACE", status: 501) }
        if webSocketRequest {
            guard head.method == .GET, headerTokens(head.headers, name: "connection").contains("upgrade"),
                  head.headers["sec-websocket-version"] == ["13"], head.headers["sec-websocket-key"].count == 1,
                  Data(base64Encoded: head.headers["sec-websocket-key"][0])?.count == 16,
                  head.headers["transfer-encoding"].isEmpty,
                  head.headers["content-length"].allSatisfy({ $0 == "0" }) else { return fail("WebSocket 握手无效", status: 400) }
            record?.captureProtocol = .webSocket
        }
        guard let url = URL(string: head.uri), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.fragment == nil else { return fail("需要 HTTP 或 HTTPS 绝对请求地址", status: 400) }
        do {
            let document = shared.document.withLock { $0 }
            match = WorkflowEngine.match(document, method: originalMethod, url: head.uri, headers: fields(head.headers))
            record?.environment = document.environment?.name ?? "无环境"
            var draft = HTTPMessageDraft(method: originalMethod, url: head.uri, headers: fields(head.headers))
            if let match {
                if let record {
                    templateContext = WorkflowTemplateContext(id: record.id, date: record.startedAt, request: draft)
                }
                self.record?.project = match.project; self.record?.workflow = match.workflow.name
                self.record?.matchedWorkflowID = match.workflow.id
                shared.ruleHitNotifications.append(workflowID: match.workflow.id, name: match.workflow.name)
                if match.workflow.requestSteps.contains(where: { $0.enabled && $0.kind == .script }) {
                    guard reserveScriptFlow() else { return }
                    scriptRequestHead = head; scriptRequestDraft = draft
                    if head.headers["expect"].contains(where: { $0.lowercased() == "100-continue" }) {
                        client.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .continue)), promise: nil)
                        scriptRequestHead?.headers.remove(name: "Expect")
                    }
                    return
                }
                if match.workflow.requestSteps.contains(where: { $0.enabled && $0.usesBodyFile }) {
                    executeScriptFlow(response: false, draft: draft) { [self, head] result in
                        do { try continueRequest(head, draft: result) }
                        catch { fail(error.localizedDescription, status: 400) }
                    }
                    return
                }
                try applyRecordedSteps(match.workflow.requestSteps, response: false, to: &draft)
            }
            try continueRequest(head, draft: draft)
        } catch { fail(error.localizedDescription, status: 400) }
    }
    private func continueRequest(_ head: HTTPRequestHead, draft: HTTPMessageDraft) throws {
        guard let client, isProcessing else { return }
            record?.finalURL = draft.url; record?.sentMethod = draft.method
            request = draft
            startRecordUpdates()
            if webSocketRequest && (draft.method != "GET" || draft.hasReplacementBody) && !draft.isMock {
                throw WorkflowError.invalid("WebSocket 握手必须使用 GET 且不含 Body")
            }
            if draft.isMock {
                record?.outcome = .mocked
                record?.sentBody = .unavailable("本地响应，请求未发送至上游")
                record?.receivedBody = .unavailable("本地响应，没有上游响应")
                var reply = draft
                if match?.workflow.responseSteps.contains(where: { $0.enabled && ([.script, .delay].contains($0.kind) || $0.usesBodyFile) }) == true {
                    executeScriptFlow(response: true, draft: reply) { [self] in sendStatic($0) }
                    return
                }
                if let match { try applyRecordedSteps(match.workflow.responseSteps, response: true, to: &reply) }
                return sendStatic(reply)
            }
            guard let target = URLComponents(string: draft.url), let host = target.host else { throw WorkflowError.invalid("目标地址无效") }
            let secure = target.scheme == "https"
            let port = target.port ?? (secure ? 443 : 80)
            guard !isLoop(host, port: port) else { throw WorkflowError.invalid("请求目标会形成代理循环") }
            var headers = cleanHeaders(draft.headers)
            headers.replaceOrAdd(name: "Host", value: target.percentEncodedHost.map { $0 + (target.port.map { ":\($0)" } ?? "") } ?? host)
            headers.replaceOrAdd(name: "Connection", value: clientKeepsAlive ? "keep-alive" : "close")
            if webSocketRequest {
                headers.replaceOrAdd(name: "Connection", value: "Upgrade")
                headers.replaceOrAdd(name: "Upgrade", value: "websocket")
                headers.replaceOrAdd(name: "Sec-WebSocket-Key", value: head.headers["sec-websocket-key"][0])
                headers.replaceOrAdd(name: "Sec-WebSocket-Version", value: "13")
                // Base support deliberately negotiates no extensions. Never advertise compression we cannot inspect.
                headers.remove(name: "Sec-WebSocket-Extensions")
            }
            headers.remove(name: "Expect")
            if let body = draft.replacementBytes {
                headers.remove(name: "Transfer-Encoding"); headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
            } else if head.headers.contains(name: "transfer-encoding") {
                headers.remove(name: "Content-Length"); headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            }
            let uri: String
            let endpoint: ProxyEndpoint
            if case .httpProxy(let proxy) = configuration.upstream { endpoint = proxy }
            else { endpoint = ProxyEndpoint(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port) }
            if case .httpProxy = configuration.upstream, !secure { uri = draft.url }
            else { uri = (target.percentEncodedPath.isEmpty ? "/" : target.percentEncodedPath) + (target.percentEncodedQuery.map { "?\($0)" } ?? "") }
            record?.sentHeaders = fields(headers)
            record?.hasSentRequestHeaders = true
            let forwarded = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: draft.method), uri: uri, headers: headers)
            if head.headers["expect"].contains(where: { $0.lowercased() == "100-continue" }) {
                client.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .continue)), promise: nil)
            }
            connectHTTP(endpoint: endpoint, targetHost: host, targetPort: port, secure: secure, on: client.eventLoop).whenComplete { [self] result in
                switch result {
                case .failure(let error): fail(error.localizedDescription, status: 502)
                case .success(let channel):
                    guard isProcessing else { closeProxyChannel(channel); return }
                    guard !isLoopChannel(channel) else { closeProxyChannel(channel); fail("目标解析后指向代理自身", status: 502); return }
                    upstream = channel; connected = true
                    sentBodyCollector = CaptureBodyCollector(headers: record?.sentHeaders ?? [])
                    trackRequestWrite(channel.write(HTTPClientRequestPart.head(forwarded)))
                    if let body = request?.replacementBytes {
                        sentBodyCollector?.append(body)
                        trackRequestWrite(channel.write(HTTPClientRequestPart.body(.byteBuffer(channel.allocator.buffer(bytes: body)))))
                    }
                    for part in pending { forward(part) }
                    pending.removeAll()
                    flushRequest()
                    channel.read()
                }
            }
    }
    private func connectHTTP(endpoint: ProxyEndpoint, targetHost: String, targetPort: Int, secure: Bool, on loop: EventLoop) -> EventLoopFuture<Channel> {
        // One reusable origin per downstream connection, including its TLS session.
        // Never share a socket across targets, routes or concurrent transactions.
        let key = "\(secure)-\(targetHost.lowercased()):\(targetPort)-\(endpoint.host):\(endpoint.port)"
        if let upstream, upstream.isActive, upstreamTarget == key {
            return loop.makeSucceededFuture(upstream)
        }
        if let previous = upstream {
            upstream = nil
            closeProxyChannel(previous)
        }
        upstreamTarget = key
        return bootstrap(on: loop).connect(host: endpoint.host, port: endpoint.port).flatMap { [self] channel in
            guard isProcessing, !isLoopChannel(channel) else {
                closeProxyChannel(channel)
                return loop.makeFailedFuture(WorkflowError.invalid("连接已取消或指向代理自身"))
            }
            upstream = channel
            let ready: EventLoopFuture<Void>
            if secure, case .httpProxy = configuration.upstream {
                let handshake = loop.makePromise(of: Void.self)
                let authority = targetHost + ":" + String(targetPort)
                ready = channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                    channel.pipeline.addHandler(TunnelHandshake(ready: handshake))
                }.flatMap {
                    channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: authority, headers: HTTPHeaders([("Host", authority)]))), promise: nil)
                    channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                    channel.read()
                    return handshake.futureResult
                }
            } else { ready = loop.makeSucceededFuture(()) }
            return ready.flatMap { [self] in
                loop.makeCompletedFuture {
                    guard self.isProcessing else { throw WorkflowError.invalid("连接已取消") }
                    if secure {
                        try channel.pipeline.syncOperations.addHandler(ProxyTLS.client(host: targetHost, testTrustRoots: self.shared.upstreamTrustRoots))
                    }
                }
            }.flatMap {
                channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits())
            }.flatMap {
                channel.pipeline.addHandler(ProxyResponseHandler(owner: self))
            }.map { channel }
        }
    }

    private func forward(_ part: HTTPServerRequestPart) {
        guard let upstream, !tunnel else { return }
        switch part {
        case .body(let bytes):
            if request?.hasReplacementBody != true {
                sentBodyCollector?.append(bytes.readableBytesView)
                trackRequestWrite(upstream.write(HTTPClientRequestPart.body(.byteBuffer(bytes))))
            }
        case .end:
            let written = upstream.write(HTTPClientRequestPart.end(nil))
            trackRequestWrite(written)
            written.whenSuccess { [self] in requestWriteComplete = !requestWriteFailed }
        case .head: break
        }
    }
    private func trackRequestWrite(_ future: EventLoopFuture<Void>) {
        lastRequestWrite = future
        future.whenFailure { [self] error in
            requestWriteFailed = true
            requestWriteComplete = false
            fail(error.localizedDescription, status: 502)
        }
    }
    private func trackResponseWrite(_ future: EventLoopFuture<Void>) {
        lastResponseWrite = future
        future.whenFailure { [self] error in
            responseWriteFailed = true
            responseWriteComplete = false
            fail(error.localizedDescription, status: 502)
        }
    }
    private func flushRequest() {
        guard let upstream else { return }
        upstream.flush()
        let flushed = lastRequestWrite ?? upstream.eventLoop.makeSucceededFuture(())
        flushed.whenComplete { [self] result in
            if case .failure(let error) = result { fail(error.localizedDescription, status: 502) }
            else if !requestEnded && isProcessing { client?.read() }
        }
    }
    func receive(_ part: HTTPClientResponsePart, channel: Channel) {
        guard isProcessing, record != nil, channel === upstream else { return }
        do {
            switch part {
            case .head(let head):
                if head.status.code < 200 {
                    informationalResponse = true
                    if head.status == .switchingProtocols { pendingWebSocketResponse = head; webSocketUpgrading = true }
                    return
                }
                informationalResponse = false
                originKeepsAlive = head.isKeepAlive
                guard !responseStarted else { return fail("重复响应头", status: 502) }
                var draft = HTTPMessageDraft(method: originalMethod, url: request?.url ?? "", status: Int(head.status.code), headers: fields(head.headers))
                record?.receivedHeaders = draft.headers
                record?.originalStatus = draft.status
                receivedBodyCollector = CaptureBodyCollector(headers: draft.headers)
                if match?.workflow.isSSE == true || isSSE(draft.headers) {
                    try receiveSSEHead(draft)
                    return
                }
                if match?.workflow.responseSteps.contains(where: { $0.enabled && [.script, .delay].contains($0.kind) }) == true {
                    if match?.workflow.responseSteps.contains(where: { $0.enabled && $0.kind == .script }) == true {
                        guard reserveScriptFlow() else { return }
                    }
                    scriptResponseDraft = draft
                    return
                }
                if match?.workflow.responseSteps.contains(where: { $0.enabled && $0.usesBodyFile }) == true {
                    readingResponseBodyFile = true
                    executeScriptFlow(response: true, draft: draft) { [self] result in
                        readingResponseBodyFile = false
                        startStreamingResponse(result)
                        if responseEnded { endStreamingResponse(channel) }
                        else { responseReadComplete(channel) }
                    }
                    return
                }
                if let match { try applyRecordedSteps(match.workflow.responseSteps, response: true, to: &draft) }
                startStreamingResponse(draft)
            case .body(let buffer):
                record?.responseBytes += buffer.readableBytes
                receivedBodyCollector?.append(buffer.readableBytesView)
                if let stream = record?.receivedStream { appendSSE(buffer, to: stream) }
                if sseWaiting { ssePending.append(buffer); return }
                // File replacement never needs the original body; only capture the current read batch.
                if readingResponseBodyFile { return }
                if scriptResponseDraft != nil {
                    scriptResponseBytes.append(contentsOf: buffer.readableBytesView)
                    return
                }
                if let response, !response.hasReplacementBody, allowsBody(response.status) {
                    responseBodyCollector?.append(buffer.readableBytesView)
                    if let client { trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))) }
                }
            case .end:
                if let upgrade = pendingWebSocketResponse {
                    pendingWebSocketResponse = nil
                    channel.eventLoop.execute { [self] in
                        guard isProcessing else { return }
                        do { try upgradeWebSocket(upgrade) }
                        catch { fail(error.localizedDescription, status: 502) }
                    }
                    return
                }
                if informationalResponse { informationalResponse = false; return }
                if readingResponseBodyFile || sseWaiting { responseEnded = true; return }
                if var draft = scriptResponseDraft {
                    scriptResponseDraft = nil; responseEnded = true
                    draft.bodyData = scriptResponseBytes
                    executeScriptFlow(response: true, draft: draft) { [self] result in
                        sendBufferedResponse(result)
                    }
                    return
                }
                endStreamingResponse(channel)
            }
        } catch { fail(error.localizedDescription, status: 502) }
    }
    private func startStreamingResponse(_ draft: HTTPMessageDraft) {
        response = draft
        record?.connectionState = .open
        responseKeepsAlive = clientKeepsAlive && requestEnded && requestWriteComplete
        let headers = responseHeaders(draft, keepAlive: responseKeepsAlive)
        record?.responseHeaders = fields(headers); record?.status = draft.status
        responseBodyCollector = CaptureBodyCollector(headers: fields(headers))
        if record?.captureProtocol == .sse {
            let stream = record?.receivedStream
            record?.stream = stream
            responseBodyCollector = nil
            record?.responseBody = .unavailable("SSE 内容保存在事件流中")
        }
        responseStarted = true
        if let client {
            trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: draft.status), headers: headers))))
        }
        if let body = draft.replacementBytes, allowsBody(draft.status), let client {
            responseBodyCollector?.append(body)
            trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(bytes: body)))))
        }
    }
    private func endStreamingResponse(_ channel: Channel) {
        guard responseStarted, let client else { return fail("上游未返回完整响应", status: 502) }
        responseEnded = true
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [self] result in
            if case .success = result, !responseWriteFailed, responseKeepsAlive, failureMessage == nil {
                responseWriteComplete = true
                finish()
                prepareNextRequest()
            } else {
                if case .failure(let error) = result { finish(error: error.localizedDescription) }
                else { responseWriteComplete = !responseWriteFailed; finish() }
                closeProxyChannel(client); closeProxyChannel(channel)
            }
        }
    }
    func responseReadComplete(_ channel: Channel) {
        guard let client, isProcessing, record != nil, channel === upstream else { return }
        client.flush()
        guard !responseEnded, !readingResponseBodyFile, !sseWaiting, !webSocketUpgrading else { return }
        let flushed = lastResponseWrite ?? channel.eventLoop.makeSucceededFuture(())
        let ready = flushed.and(lastStreamWrite ?? channel.eventLoop.makeSucceededVoidFuture())
        ready.whenComplete { [self] result in
            if case .failure(let error) = result { fail(error.localizedDescription, status: 502) }
            else if isProcessing { channel.read() }
        }
    }
    func upstreamClosed(_ channel: Channel) {
        guard channel === upstream else { return }
        upstream = nil; upstreamTarget = nil
        if record != nil, isProcessing && !responseEnded { fail("上游连接提前关闭", status: 502) }
    }
    func upstreamError(_ error: Error, channel: Channel) {
        guard channel === upstream else { return }
        if record == nil { upstream = nil; upstreamTarget = nil; closeProxyChannel(channel) }
        else { fail(ProxyTLS.errorDescription(error), status: 502) }
    }

    private func prepareNextRequest() {
        if !originKeepsAlive, let previous = upstream {
            upstream = nil; upstreamTarget = nil
            closeProxyChannel(previous)
        }
        recordTimer?.cancel(); recordTimer = nil
        webSocketRequest = false; webSocketUpgrading = false
        lastStreamWrite = nil; sseWaiting = false; ssePending.removeAll()
        record = nil; match = nil; request = nil; response = nil; templateContext = nil
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

    private func sendStatic(_ draft: HTTPMessageDraft) {
        guard let client else { return }
        responseStarted = true
        let headers = responseHeaders(draft)
        record?.status = draft.status; record?.responseHeaders = fields(headers)
        responseBodyCollector = CaptureBodyCollector(headers: fields(headers))
        if match?.workflow.isSSE == true || isSSE(fields(headers)) {
            record?.captureProtocol = .sse
            let stream = CaptureStreamStore(contentEncoding: headers["content-encoding"].first)
            record?.stream = stream
            if let body = draft.replacementBytes { appendSSE(client.allocator.buffer(bytes: body), to: stream) }
        }
        trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: draft.status), headers: headers))))
        if allowsBody(draft.status), let body = draft.replacementBytes {
            record?.responseBytes = body.count
            responseBodyCollector?.append(body)
            trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(bytes: body)))))
        }
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [self] result in
            if case .failure(let error) = result { finish(error: error.localizedDescription) }
            else { responseWriteComplete = !responseWriteFailed; finish() }
            closeProxyChannel(client)
        }
    }
    private func responseHeaders(_ draft: HTTPMessageDraft, keepAlive: Bool = false) -> HTTPHeaders {
        var headers = cleanHeaders(draft.headers)
        headers.remove(name: "Content-Length"); headers.remove(name: "Transfer-Encoding")
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        if let body = draft.replacementBytes, draft.status != 204, draft.status != 205, draft.status != 304 {
            headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
        } else if allowsBody(draft.status) { headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked") }
        return headers
    }
    private func allowsBody(_ status: Int) -> Bool { originalMethod != "HEAD" && status != 204 && status != 205 && status != 304 }
    private func fail(_ message: String, status: Int) {
        guard isProcessing else { return }
        failureMessage = message
        suspendedFlowControl?.cancel()
        scriptLease?.control.cancel()
        timer?.cancel(); certificateTask?.cancel()
        if let upstream { closeProxyChannel(upstream) }
        guard let client else { finish(error: message); return }
        if responseStarted || tunnel { finish(error: message); closeProxyChannel(client); return }
        record?.status = status
        responseStarted = true
        let body = "Requestman: \(message)"
        let headers = HTTPHeaders([("Connection", "close"), ("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(body.utf8.count))])
        record?.responseHeaders = fields(headers)
        responseBodyCollector = CaptureBodyCollector(headers: fields(headers))
        trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: status), headers: headers))))
        if originalMethod != "HEAD" {
            responseBodyCollector?.append(body.utf8)
            trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(string: body)))))
        }
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [self] result in
            if case .success = result { responseWriteComplete = !responseWriteFailed }
            finish(error: message)
            closeProxyChannel(client)
        }
    }
    private func applyRecordedSteps(_ steps: [ModificationStep], response: Bool,
                                    to draft: inout HTTPMessageDraft) throws {
        guard let match, let snapshot = record else { return }
        _ = try WorkflowEngine.apply(steps, response: response, to: &draft,
            environment: match.environment?.values ?? [:], id: snapshot.id, date: snapshot.startedAt, request: request, templateContext: templateContext, environmentTypes: match.environment?.valueTypes ?? [:]) { kind in
                self.record?.steps.append(kind.title)
                self.record?.matchedRules.append(CaptureMatchedRule(
                    kind: kind, name: match.workflow.name, response: response
                ))
            }
    }

    private func reserveScriptFlow() -> Bool {
        if scriptLease != nil { return true }
        scriptLease = ScriptFlowLease.acquire()
        if scriptLease == nil { fail("脚本流程执行已满", status: 503); return false }
        return true
    }

    private func executeScriptFlow(response isResponse: Bool, draft: HTTPMessageDraft,
                                   completion: @escaping @Sendable (HTTPMessageDraft) -> Void) {
        guard let client, let match, let snapshot = record else { return }
        let steps = isResponse ? match.workflow.responseSteps : match.workflow.requestSteps
        let hasScript = steps.contains { $0.enabled && $0.kind == .script }
        if hasScript { guard reserveScriptFlow() else { return } }
        let lease = scriptLease
        let control = ScriptExecutionControl()
        suspendedFlowControl = control
        var requestSnapshot = request
        if isResponse, requestSnapshot?.bodyText == nil, let requestBodyCollector, requestEnded {
            let body = requestBodyCollector.snapshot(isComplete: true)
            requestSnapshot?.bodyData = body.data
        }
        if snapshot.hasSentRequestHeaders { requestSnapshot?.headers = snapshot.sentHeaders }
        let inputRequest = requestSnapshot
        let inputTemplateContext = templateContext
        Task.detached(priority: .userInitiated) { [self, lease] in
            // Keep the admission slot until the worker exits, including across suspended delays.
            defer { withExtendedLifetime(lease) {} }
            var output = draft
            var kinds: [ModificationKind] = []
            let result: Result<HTTPMessageDraft, Error>
            do {
                try control.check()
                if hasScript, !output.hasReplacementBody, let data = output.bodyData { output.bodyText = try ScriptBodyText.decode(data, headers: output.headers, control: control) }
                var preparedRequest = inputRequest
                if hasScript, let data = preparedRequest?.bodyData, preparedRequest?.hasReplacementBody != true {
                    let headers = preparedRequest?.headers ?? []
                    preparedRequest?.bodyText = try ScriptBodyText.decode(data, headers: headers, control: control)
                }
                _ = try await WorkflowEngine.applyAsync(steps, response: isResponse, to: &output,
                    environment: match.environment?.values ?? [:], id: snapshot.id, date: snapshot.startedAt,
                    request: preparedRequest, control: control, templateContext: inputTemplateContext, environmentTypes: match.environment?.valueTypes ?? [:], onApplied: { kinds.append($0) })
                result = .success(output)
            } catch { result = .failure(error) }
            let appliedKinds = kinds
            client.eventLoop.execute { [self] in
                guard isProcessing, record?.id == snapshot.id else { return }
                for kind in appliedKinds {
                    record?.steps.append(kind.title)
                    record?.matchedRules.append(CaptureMatchedRule(kind: kind, name: match.workflow.name, response: isResponse))
                }
                switch result {
                case .success(let output): completion(output)
                case .failure(let error): fail(error.localizedDescription, status: isResponse ? 502 : 400)
                }
            }
        }
    }

    private func sendBufferedResponse(_ draft: HTTPMessageDraft) {
        guard let client, isProcessing else { return }
        response = draft; responseStarted = true
        let bytes = draft.replacementBytes ?? scriptResponseBytes
        scriptResponseBytes = Data()
        var headers = responseHeaders(draft)
        headers.remove(name: "Transfer-Encoding")
        if allowsBody(draft.status) { headers.replaceOrAdd(name: "Content-Length", value: String(bytes.count)) }
        record?.status = draft.status; record?.responseHeaders = fields(headers)
        responseBodyCollector = CaptureBodyCollector(headers: fields(headers))
        trackResponseWrite(client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: draft.status), headers: headers))))
        if allowsBody(draft.status) {
            responseBodyCollector?.append(bytes)
            trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(bytes: bytes)))))
        }
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [self] result in
            if case .failure(let error) = result { finish(error: error.localizedDescription) }
            else { responseWriteComplete = !responseWriteFailed; finish() }
            closeProxyChannel(client)
            if let upstream { closeProxyChannel(upstream) }
        }
    }

    private func finish(error: String? = nil) {
        guard !finished else { return }
        finished = true; timer?.cancel(); recordTimer?.cancel(); recordTimer = nil; certificateTask?.cancel()
        suspendedFlowControl?.cancel(); suspendedFlowControl = nil
        scriptLease?.control.cancel()
        scriptLease = nil; scriptRequestHead = nil; scriptRequestDraft = nil; scriptResponseDraft = nil
        scriptRequestBytes = Data(); scriptResponseBytes = Data(); readingResponseBodyFile = false
        pending.removeAll()
        guard var record else { return }
        let elapsed = started.duration(to: .now).components
        record.duration = Double(elapsed.attoseconds) / 1e18 + Double(elapsed.seconds)
        record.error = failureMessage ?? error
        if let requestBodyCollector { record.requestBody = requestBodyCollector.snapshot(isComplete: requestEnded) }
        if let sentBodyCollector { record.sentBody = sentBodyCollector.snapshot(isComplete: requestWriteComplete) }
        if let receivedBodyCollector { record.receivedBody = receivedBodyCollector.snapshot(isComplete: responseEnded) }
        if let responseBodyCollector { record.responseBody = responseBodyCollector.snapshot(isComplete: responseWriteComplete) }
        if record.error != nil { record.outcome = .failed }
        else if record.outcome == .forwarded && !record.steps.isEmpty { record.outcome = .modified }
        record.connectionState = record.error == nil ? .closed : .failed
        record.revision &+= 1
        let finalRecord = record, generation = recordGeneration, records = records
        if let lastStreamWrite {
            lastStreamWrite.whenComplete { _ in records.append(finalRecord, generation: generation) }
        } else { records.append(finalRecord, generation: generation) }
    }

    private func startRecordUpdates() {
        guard let client, recordTimer == nil else { return }
        publishRecord()
        recordTimer = client.eventLoop.scheduleTask(in: .milliseconds(200)) { [self] in
            recordTimer = nil
            if isProcessing { startRecordUpdates() }
        }
    }
    private func publishRecord() {
        guard record != nil else { return }
        if !records.isCurrent(recordGeneration) {
            record?.stream = nil; record?.receivedStream = nil
            requestBodyCollector = nil; sentBodyCollector = nil; receivedBodyCollector = nil; responseBodyCollector = nil
        }
        let elapsed = started.duration(to: .now).components
        record?.duration = Double(elapsed.attoseconds) / 1e18 + Double(elapsed.seconds)
        record?.revision &+= 1
        if requestEnded, let requestBodyCollector { record?.requestBody = requestBodyCollector.snapshot(isComplete: true) }
        if requestWriteComplete, let sentBodyCollector { record?.sentBody = sentBodyCollector.snapshot(isComplete: true) }
        if let record { records.append(record, generation: recordGeneration) }
    }
    private func isSSE(_ headers: [HTTPField]) -> Bool {
        headers.contains { $0.name.lowercased() == "content-type" && $0.value.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream" }
    }
    private func appendSSE(_ buffer: ByteBuffer, to stream: CaptureStreamStore) {
        guard records.isCurrent(recordGeneration), let client else { return }
        let promise = client.eventLoop.makePromise(of: Void.self)
        stream.appendSSE(Data(buffer.readableBytesView)) { promise.succeed(()) }
        lastStreamWrite = promise.futureResult
    }
    private func receiveSSEHead(_ draft: HTTPMessageDraft) throws {
        record?.captureProtocol = .sse
        let stream = CaptureStreamStore(contentEncoding: draft.headers.first { $0.name.lowercased() == "content-encoding" }?.value)
        record?.receivedStream = stream
        record?.receivedBody = .unavailable("SSE 原始内容保存在事件流中")
        receivedBodyCollector = nil
        let steps = match?.workflow.responseSteps.filter(\.enabled) ?? []
        let replacement = steps.firstIndex { $0.kind == .replaceBody || $0.kind == .redirect }
        // Whole-body scripts cannot read an endless response. A preceding replacement supplies a finite input.
        if let script = steps.firstIndex(where: { $0.kind == .script }), replacement == nil || script < replacement! {
            throw WorkflowError.invalid("SSE 响应脚本需要在替换 Body 之后执行；暂不支持事件流脚本")
        }
        if replacement != nil {
            if let channel = upstream { upstream = nil; upstreamTarget = nil; closeProxyChannel(channel) }
            record?.closeReason = "已取消上游并替换响应 Body"
            if steps.contains(where: { $0.usesBodyFile || [.delay, .script].contains($0.kind) }) {
                executeScriptFlow(response: true, draft: draft) { [self] in sendStatic($0) }
            } else {
                var reply = draft
                try applyRecordedSteps(steps, response: true, to: &reply)
                sendStatic(reply)
            }
        } else if steps.contains(where: { $0.kind == .delay }) {
            sseWaiting = true
            executeScriptFlow(response: true, draft: draft) { [self] result in
                sseWaiting = false
                startStreamingResponse(result)
                if let client {
                    for buffer in ssePending { trackResponseWrite(client.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))) }
                }
                ssePending.removeAll()
                if let channel = upstream {
                    if responseEnded { endStreamingResponse(channel) } else { responseReadComplete(channel) }
                }
            }
        } else {
            var reply = draft
            try applyRecordedSteps(steps, response: true, to: &reply)
            startStreamingResponse(reply)
        }
        publishRecord()
    }
    private func isLoopChannel(_ channel: Channel) -> Bool {
        channel.remoteAddress?.port == configuration.port && ["127.0.0.1", "::1"].contains(channel.remoteAddress?.ipAddress ?? "")
    }
    private func isLoop(_ host: String, port: Int) -> Bool {
        port == configuration.port && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
    private func bootstrap(on eventLoop: EventLoop) -> ClientBootstrap {
        ClientBootstrap(group: eventLoop).connectTimeout(.seconds(5))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
            .channelInitializer { [shared] channel in
                guard shared.register(channel, downstream: false) else { return channel.close() }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
    }
    private func fields(_ headers: HTTPHeaders) -> [HTTPField] { headers.map { HTTPField($0.name, $0.value) } }
    private func cleanHeaders(_ fields: [HTTPField]) -> HTTPHeaders {
        let connectionTokens = fields.filter { $0.name.lowercased() == "connection" }.flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let removed = Set(connectionTokens + ["connection", "proxy-connection", "proxy-authorization", "proxy-authenticate", "keep-alive", "te", "trailer", "upgrade", "transfer-encoding"])
        return HTTPHeaders(fields.filter { !removed.contains($0.name.lowercased()) }.map { ($0.name, $0.value) })
    }

    private func headerTokens(_ headers: HTTPHeaders, name: String) -> [String] {
        headers[name].flatMap { $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }
    private func upgradeWebSocket(_ head: HTTPResponseHead) throws {
        guard webSocketRequest, let client, let peer = upstream, var record else { throw WorkflowError.invalid("非 WebSocket 请求收到协议升级") }
        let key = record.sentHeaders.first { $0.name.lowercased() == "sec-websocket-key" }?.value ?? ""
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let offered = record.sentHeaders.filter { $0.name.lowercased() == "sec-websocket-protocol" }
            .flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let protocols = head.headers["sec-websocket-protocol"]
        guard head.headers["sec-websocket-accept"] == [accept], headerTokens(head.headers, name: "connection").contains("upgrade"),
              headerTokens(head.headers, name: "upgrade") == ["websocket"], head.headers["sec-websocket-extensions"].isEmpty,
              protocols.isEmpty || protocols.count == 1 && offered.contains(protocols[0]) else {
            throw WorkflowError.invalid("上游 WebSocket 握手校验失败")
        }
        let steps = match?.workflow.responseSteps.filter(\.enabled) ?? []
        guard steps.allSatisfy({ [.setHeader, .removeHeader].contains($0.kind) }) else {
            throw WorkflowError.invalid("WebSocket 握手响应仅支持修改 Header；消息修改尚未实现")
        }
        record.receivedHeaders = fields(head.headers); record.originalStatus = 101
        var draft = HTTPMessageDraft(method: "GET", url: record.finalURL, status: 101, headers: record.receivedHeaders)
        try applyRecordedSteps(steps, response: true, to: &draft)
        var headers = cleanHeaders(draft.headers)
        headers.remove(name: "Content-Length"); headers.remove(name: "Transfer-Encoding")
        headers.remove(name: "Sec-WebSocket-Extensions"); headers.remove(name: "Sec-WebSocket-Protocol")
        if let selected = protocols.first { headers.replaceOrAdd(name: "Sec-WebSocket-Protocol", value: selected) }
        headers.replaceOrAdd(name: "Connection", value: "Upgrade"); headers.replaceOrAdd(name: "Upgrade", value: "websocket")
        headers.replaceOrAdd(name: "Sec-WebSocket-Accept", value: accept)
        record.responseHeaders = fields(headers); record.status = 101
        record.steps = self.record?.steps ?? []; record.matchedRules = self.record?.matchedRules ?? []
        if !record.steps.isEmpty { record.outcome = .modified }
        self.record = record
        responseStarted = true; webSocketUpgrading = true
        let session = WebSocketSession(client: client, server: peer, record: record, records: records, generation: recordGeneration, shared: shared)
        // Install frame handlers before releasing decoder leftovers on either hop.
        client.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: headers)))
            .flatMap { [self] in client.pipeline.removeHandler(self) }
            .flatMap { client.pipeline.removeHTTPHandler(HTTPResponseEncoder.self) }
            .flatMap { peer.pipeline.removeHTTPHandler(ProxyResponseHandler.self) }
            .flatMap { peer.pipeline.removeHTTPHandler(NIOHTTPRequestHeadersValidator.self) }
            .flatMap { peer.pipeline.removeHTTPHandler(HTTPRequestEncoder.self) }
            .flatMap {
                client.eventLoop.makeCompletedFuture {
                    try client.pipeline.syncOperations.addHandlers([
                        WebSocketFrameEncoder(), ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: Int(UInt32.max))),
                        WebSocketRelay(peer: peer, direction: .sent, session: session)
                    ])
                    try peer.pipeline.syncOperations.addHandlers([
                        WebSocketFrameEncoder(), ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: Int(UInt32.max))),
                        WebSocketRelay(peer: client, direction: .received, session: session)
                    ])
                }
            }.flatMap { client.pipeline.removeHTTPHandler(ByteToMessageHandler<HTTPRequestDecoder>.self) }
            .flatMap { peer.pipeline.removeHTTPHandler(ByteToMessageHandler<HTTPResponseDecoder>.self) }
            .whenComplete { [self] result in
                switch result {
                case .failure(let error): session.finish(error: error.localizedDescription); finish(error: error.localizedDescription)
                case .success:
                    finished = true; timer?.cancel(); recordTimer?.cancel(); recordTimer = nil
                    self.upstream = nil; self.client = nil
                    session.start(); client.read(); peer.read()
                }
            }
    }

    private func beginTunnel(_ head: HTTPRequestHead) {
        guard let client, let target = URLComponents(string: "https://" + head.uri), let host = target.host,
              let port = target.port, target.path.isEmpty, target.user == nil, target.query == nil,
              target.fragment == nil, (1...65535).contains(port), !isLoop(host, port: port) else {
            return fail("CONNECT 目标无效", status: 400)
        }
        guard head.headers["transfer-encoding"].isEmpty,
              head.headers["content-length"].allSatisfy({ $0 == "0" }) else { return fail("CONNECT 不接受 HTTP Body", status: 400) }
        responseStarted = true
        client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok)), promise: nil)
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).flatMap { [self] in client.pipeline.removeHandler(self) }
            .flatMap { client.pipeline.removeHTTPHandler(HTTPResponseEncoder.self) }
            .flatMap { [self] in
                client.pipeline.addHandler(ConnectProtocolDetector(configure: { [self] kind in
                    configureTunnel(kind, host: host, port: port, authority: head.uri)
                }, onClose: { [self] in
                    if !finished { finish(error: "CONNECT 客户端连接已关闭") }
                }))
            }.flatMap { client.pipeline.removeHTTPHandler(ByteToMessageHandler<HTTPRequestDecoder>.self) }
            .whenComplete { [self] result in
                switch result {
                case .failure(let error): finish(error: error.localizedDescription); closeProxyChannel(client)
                case .success: client.read()
                }
            }
    }
    private func configureTunnel(_ kind: ConnectProtocolDetector.Kind, host: String, port: Int, authority: String) -> EventLoopFuture<Void> {
        guard let client else { preconditionFailure("CONNECT has an active client") }
        let identity = client.eventLoop.makePromise(of: TLSCertificateIdentity?.self)
        let shouldDecrypt = shared.document.withLock { $0.httpsDecryption.shouldDecrypt(host: host) }
        if kind == .tls, shouldDecrypt, let provider = shared.certificateProvider {
            certificateTask = Task {
                do { identity.succeed(try await provider.serverIdentity(for: host)) }
                catch { identity.fail(error) }
            }
        } else { identity.succeed(nil) }
        return identity.futureResult.flatMap { [self] identity in
            certificateTask = nil
            guard isProcessing, client.isActive else { return client.eventLoop.makeFailedFuture(WorkflowError.invalid("CONNECT 已取消")) }
            if kind == .http || identity != nil {
                return client.eventLoop.makeCompletedFuture {
                    var encoder = HTTPResponseEncoder.Configuration(); encoder.automaticallySetFramingHeaders = false
                    if let identity { try client.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: self.shared.tlsContexts.server(identity))) }
                    try client.pipeline.syncOperations.addHandlers([
                        HTTPResponseEncoder(configuration: encoder),
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes, limitConfiguration: proxyDecoderLimits())),
                        ProxyConnection(configuration: self.configuration, shared: self.shared, records: self.records,
                                        tlsAuthority: identity == nil ? nil : authority, plainAuthority: identity == nil ? authority : nil)
                    ])
                    self.finished = true; self.timer?.cancel(); self.pending.removeAll()
                }
            }
            return connectOpaqueTunnel(host: host, port: port, authority: authority)
        }.flatMapError { [self] error in
            finish(error: "CONNECT 建立失败：" + error.localizedDescription)
            return client.eventLoop.makeFailedFuture(error)
        }
    }
    private func connectOpaqueTunnel(host: String, port: Int, authority: String) -> EventLoopFuture<Void> {
        guard let client else { preconditionFailure("CONNECT has an active client") }
        let endpoint: ProxyEndpoint
        if case .httpProxy(let proxy) = configuration.upstream { endpoint = proxy }
        else { endpoint = ProxyEndpoint(host: host, port: port) }
        return bootstrap(on: client.eventLoop).connect(host: endpoint.host, port: endpoint.port).flatMap { [self] peer in
            guard isProcessing, !isLoopChannel(peer) else { closeProxyChannel(peer); return client.eventLoop.makeFailedFuture(WorkflowError.invalid("CONNECT 已取消或指向代理自身")) }
            upstream = peer
            let ready: EventLoopFuture<Void>
            if case .httpProxy = configuration.upstream {
                let handshake = peer.eventLoop.makePromise(of: Void.self)
                ready = peer.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits())
                    .flatMap { peer.pipeline.addHandler(TunnelHandshake(ready: handshake)) }.flatMap {
                        peer.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: authority, headers: HTTPHeaders([("Host", authority)]))), promise: nil)
                        peer.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil); peer.read()
                        return handshake.futureResult
                    }
            } else { ready = peer.eventLoop.makeSucceededVoidFuture() }
            return ready.flatMap { [self] in
                peer.eventLoop.makeCompletedFuture {
                    try client.pipeline.syncOperations.addHandlers([
                        IdleStateHandler(readTimeout: .seconds(120)), TunnelRelay(peer: peer, onClose: { closeProxyChannel(peer) })
                    ])
                    try peer.pipeline.syncOperations.addHandlers([
                        IdleStateHandler(readTimeout: .seconds(120)), TunnelRelay(peer: client, onClose: { closeProxyChannel(client) })
                    ])
                    self.tunnel = true; self.connected = true; self.pending.removeAll(); self.timer?.cancel()
                    self.record?.status = 200; self.record?.outcome = .tunnel; self.record?.workflow = "CONNECT 透传（未解密）"
                    self.finish(); peer.read()
                }
            }
        }
    }

}

final class ProxyResponseHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let owner: ProxyConnection
    init(owner: ProxyConnection) { self.owner = owner }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { owner.receive(unwrapInboundIn(data), channel: context.channel) }
    func channelReadComplete(context: ChannelHandlerContext) { owner.responseReadComplete(context.channel) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { owner.upstreamError(error, channel: context.channel) }
    func channelInactive(context: ChannelHandlerContext) { owner.upstreamClosed(context.channel) }
}

final class TunnelRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let peer: Channel
    let onClose: @Sendable () -> Void
    init(peer: Channel, onClose: @escaping @Sendable () -> Void) { self.peer = peer; self.onClose = onClose }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { peer.writeAndFlush(unwrapInboundIn(data), promise: nil) }
    func channelReadComplete(context: ChannelHandlerContext) {
        let channel = context.channel
        peer.writeAndFlush(ByteBuffer()).whenComplete { result in
            if case .success = result { channel.read() } else { closeProxyChannel(channel) }
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    func channelInactive(context: ChannelHandlerContext) { onClose() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

final class TunnelHandshake: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let ready: EventLoopPromise<Void>
    var completed = false
    init(ready: EventLoopPromise<Void>) { self.ready = ready }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            if head.status != .ok { reject(WorkflowError.invalid("上游 CONNECT 返回 \(head.status.code)")) }
        case .end:
            guard !completed else { return }; completed = true
            let pipeline = context.pipeline
            pipeline.removeHandler(self).flatMap { pipeline.removeHTTPHandler(NIOHTTPRequestHeadersValidator.self) }
                .flatMap { pipeline.removeHTTPHandler(HTTPRequestEncoder.self) }
                .flatMap { pipeline.removeHTTPHandler(ByteToMessageHandler<HTTPResponseDecoder>.self) }
                .cascade(to: ready)
        case .body: reject(WorkflowError.invalid("CONNECT 响应含非预期 Body"))
        }
    }
    func channelReadComplete(context: ChannelHandlerContext) { if !completed { context.read() } }
    func errorCaught(context: ChannelHandlerContext, error: Error) { reject(error) }
    func channelInactive(context: ChannelHandlerContext) { reject(WorkflowError.invalid("上游 CONNECT 连接已关闭")) }
    private func reject(_ error: Error) { if !completed { completed = true; ready.fail(error) } }
}

private extension ChannelPipeline {
    func removeHTTPHandler<Handler: ChannelHandler>(_ type: Handler.Type) -> EventLoopFuture<Void> {
        do { return try syncOperations.removeHandler(context: syncOperations.context(handlerType: type)) }
        catch { return eventLoop.makeFailedFuture(error) }
    }
}

private func proxyDecoderLimits() -> NIOHTTPDecoderLimitConfiguration {
    var limits = NIOHTTPDecoderLimitConfiguration()
    limits.maxHeaderFieldSize = .max
    limits.maxHeaderListSize = .max
    limits.maxHeaderFieldCount = .max
    return limits
}

/// TLS close_notify needs reads even after the HTTP transaction has completed.
@discardableResult
func closeProxyChannel(_ channel: Channel) -> EventLoopFuture<Void> {
    channel.setOption(ChannelOptions.autoRead, value: true).flatMap { channel.close() }
}
