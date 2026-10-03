import Foundation
import NIOCore
import NIOHTTP1
import RequestmanCore

/// Auxiliary HTTP never passes through the listener or rule matching. Each service freezes its owner's route.
final class ScriptHTTPService: ScriptHTTPClient, Sendable {
    private let configuration: ExplicitProxyConfiguration
    private let shared: ProxySharedState
    private let records: CaptureRecordBuffer
    private let eventLoop: any EventLoop
    private let admission: ScriptHTTPAdmission
    private let sessionID: UUID
    init(configuration: ExplicitProxyConfiguration, shared: ProxySharedState, records: CaptureRecordBuffer,
         eventLoop: any EventLoop, admission: ScriptHTTPAdmission = .shared) {
        self.configuration = configuration; self.shared = shared; self.records = records
        self.eventLoop = eventLoop; self.admission = admission
        sessionID = shared.sessionID
    }
    func send(_ request: ScriptHTTPRequest, context: ScriptHTTPContext,
              control: ScriptExecutionControl) async throws -> ScriptHTTPResponse {
        try control.check()
        guard shared.acceptsSession(sessionID) else { throw CancellationError() }
        let generation = records.generation
        let target = try ProxyHTTPServiceTransport.Target(request.url, listenerPort: configuration.port)
        _ = try ProxyHTTPServiceTransport.requestHead(request, target: target, route: configuration.upstream)
        let permit = try await admission.acquire(control: control)
        do {
            try control.check(); try Task.checkCancellation()
            guard shared.acceptsSession(sessionID) else { throw CancellationError() }
        }
        catch { permit.release(); throw error }
        let operation = ScriptHTTPOperation(request: request, target: target, context: context,
            configuration: configuration, shared: shared, records: records, eventLoop: eventLoop,
            control: control, permit: permit, generation: generation)
        return try await withTaskCancellationHandler {
            eventLoop.execute { operation.start() }
            return try await operation.response.futureResult.get()
        } onCancel: { operation.cancel() }
    }
}

/// All mutable transport state belongs to one NIO event loop. File work and decoding use background queues.
private final class ScriptHTTPOperation: @unchecked Sendable {
    let response: EventLoopPromise<ScriptHTTPResponse>
    private let body: EventLoopPromise<Data>
    private let loop: any EventLoop
    private let configuration: ExplicitProxyConfiguration
    private let shared: ProxySharedState
    private let records: CaptureRecordBuffer
    private let generation: UInt64
    private let control: ScriptExecutionControl
    private let permit: ScriptHTTPPermit
    private let storage = ScriptHTTPBodyStorage()
    private var cancellationID: UUID?
    private var request: ScriptHTTPRequest
    private var target: ProxyHTTPServiceTransport.Target
    private var channel: Channel?
    private var hop = 0
    private var redirected = false
    private var receivedHead = false
    private var responseCompleted = false
    private var bodyCompleted = false
    private var finished = false
    private var requestWriteCompleted = false
    private var lastBodyWrite: EventLoopFuture<Void>?
    private var record: CaptureRecord
    private let started = ContinuousClock.now

    init(request: ScriptHTTPRequest, target: ProxyHTTPServiceTransport.Target, context: ScriptHTTPContext,
         configuration: ExplicitProxyConfiguration, shared: ProxySharedState, records: CaptureRecordBuffer,
         eventLoop: any EventLoop, control: ScriptExecutionControl, permit: ScriptHTTPPermit, generation: UInt64) {
        self.request = request; self.target = target; self.configuration = configuration
        self.shared = shared; self.records = records; loop = eventLoop
        self.control = control; self.permit = permit; self.generation = generation
        response = eventLoop.makePromise(); body = eventLoop.makePromise()
        record = CaptureRecord(id: context.callID, method: request.method.uppercased(), url: target.url.absoluteString)
        record.auxiliaryParentID = context.parentTransactionID; record.auxiliaryStepID = context.stepID
        record.auxiliaryCallID = context.callID; record.auxiliaryExecutionID = context.executionID
        record.workflow = "脚本辅助请求"; record.connectionState = .connecting
        record.requestHeaders = request.headers; record.clientHTTPVersion = "HTTP/1.1"
        record.requestBody = .collected(data: request.body ?? Data(), headers: request.headers, isComplete: true)
        record.sentBody = .notCollected; record.receivedBody = .notCollected; record.responseBody = .notCollected
    }
    func start() {
        guard !finished else { return }
        cancellationID = control.addCancellationHandler { [weak self] in self?.cancel() }
        if control.isCancelled || shared.isStopping { terminate(error: CancellationError(), cancelled: true); return }
        publish()
        connect()
    }
    func cancel() {
        loop.execute { [self] in
            // EOF may have closed the socket while the spool's final read is still running.
            if finished {
                if !bodyCompleted { bodyCompleted = true; body.fail(CancellationError()) }
                return
            }
            terminate(error: CancellationError(), cancelled: true)
        }
    }

    private func connect() {
        guard !finished, !control.isCancelled else { terminate(error: CancellationError(), cancelled: true); return }
        let currentHop = hop
        ProxyHTTPServiceTransport.connect(target: target, configuration: configuration, shared: shared,
            eventLoop: loop, attach: { [self] connection in
                if finished || control.isCancelled || currentHop != hop { closeProxyChannel(connection) }
                else { channel = connection }
            }, cancelled: { [self] in finished || control.isCancelled || currentHop != hop }).flatMap { [self] channel -> EventLoopFuture<Channel> in
                guard !finished, currentHop == hop else { closeProxyChannel(channel); return loop.makeFailedFuture(CancellationError()) }
                return channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .dropBytes,
                    decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                    channel.pipeline.addHandler(ScriptHTTPResponseHandler(owner: self, hop: currentHop))
                }.map { channel }
            }.whenComplete { [self] result in
                guard !finished, currentHop == hop else { return }
                switch result {
                case .failure(let error): terminate(error: error, cancelled: control.isCancelled || shared.isStopping)
                case .success(let channel):
                    do {
                        try control.check()
                        let head = try ProxyHTTPServiceTransport.requestHead(request, target: target, route: configuration.upstream)
                        record.finalURL = target.url.absoluteString; record.sentMethod = head.method.rawValue
                        record.sentHeaders = head.headers.map { HTTPField($0.name, $0.value) }
                        record.hasSentRequestHeaders = true; record.upstreamHTTPVersion = "HTTP/1.1"
                        record.sentBody = .collected(data: request.body ?? Data(), headers: record.sentHeaders, isComplete: false)
                        channel.write(HTTPClientRequestPart.head(head), promise: nil)
                        if let bytes = request.body {
                            channel.write(HTTPClientRequestPart.body(.byteBuffer(channel.allocator.buffer(bytes: bytes))), promise: nil)
                        }
                        let sent = channel.writeAndFlush(HTTPClientRequestPart.end(nil))
                        sent.whenComplete { [self] result in
                            guard !finished, currentHop == hop else { return }
                            switch result {
                            case .failure(let error): terminate(error: error, cancelled: control.isCancelled || shared.isStopping)
                            case .success:
                                requestWriteCompleted = true
                                record.requestBytes += request.body?.count ?? 0
                                record.sentBody = .collected(data: request.body ?? Data(), headers: record.sentHeaders, isComplete: true)
                            }
                        }
                        publish(); channel.read()
                    } catch { terminate(error: error, cancelled: control.isCancelled) }
                }
            }
    }

    func receive(_ part: HTTPClientResponsePart, hop receivedHop: Int) {
        guard !finished, receivedHop == hop else { return }
        do {
            try control.check()
            switch part {
            case .head(let head):
                if (100..<200).contains(head.status.code) {
                    if head.status.code == 101 { throw WorkflowError.invalid("fetch 不支持协议升级") }
                    return
                }
                let headers = head.headers.map { HTTPField($0.name, $0.value) }
                record.receivedHeaders = headers; record.responseHeaders = headers
                record.originalStatus = Int(head.status.code); record.status = Int(head.status.code)
                if try followRedirect(head) { return }
                receivedHead = true
                record.connectionState = .open
                let bodyFuture = body.futureResult, bodyControl = ScriptHTTPBodyControl(parent: control)
                let cancelBody: @Sendable () -> Void = { [weak self] in
                    bodyControl.control.cancel(); self?.cancel()
                }
                let hasNullBody = request.method.uppercased() == "HEAD" || [204, 205, 304].contains(Int(head.status.code))
                let reply = ScriptHTTPResponse(status: Int(head.status.code), statusText: head.status.reasonPhrase,
                    headers: headers, url: target.url.absoluteString, redirected: redirected,
                    readBody: {
                        try await withTaskCancellationHandler {
                            let raw = try await bodyFuture.get()
                            try bodyControl.control.check()
                            if hasNullBody { return Data() }
                            return try await Task.detached(priority: .userInitiated) {
                                try ScriptBodyText.decodeData(raw, headers: headers, control: bodyControl.control)
                            }.value
                        } onCancel: { cancelBody() }
                    }, cancel: cancelBody)
                responseCompleted = true; response.succeed(reply); publish()
            case .body(let buffer):
                guard receivedHead else { throw WorkflowError.invalid("fetch 缺少响应头") }
                record.responseBytes += buffer.readableBytes
                lastBodyWrite = storage.append(Data(buffer.readableBytesView), on: loop)
            case .end(let trailers):
                guard receivedHead else { throw WorkflowError.invalid("fetch 缺少最终响应") }
                record.receivedTrailers = trailers.map { $0.map { HTTPField($0.name, $0.value) } }
                record.responseTrailers = record.receivedTrailers
                terminate(error: nil, cancelled: false)
            }
        } catch { terminate(error: error, cancelled: control.isCancelled) }
    }
    func readComplete(hop receivedHop: Int) {
        guard !finished, receivedHop == hop, let channel else { return }
        let write = lastBodyWrite ?? loop.makeSucceededVoidFuture()
        lastBodyWrite = nil
        write.whenComplete { [self] result in
            guard !finished, receivedHop == hop else { return }
            switch result {
            case .failure(let error): terminate(error: error, cancelled: control.isCancelled)
            case .success: channel.read()
            }
        }
    }
    func disconnected(hop receivedHop: Int) {
        guard !finished, receivedHop == hop else { return }
        terminate(error: WorkflowError.invalid("fetch 响应完成前连接已关闭"),
                  cancelled: control.isCancelled || shared.isStopping)
    }
    func failed(_ error: any Error, hop receivedHop: Int) {
        guard !finished, receivedHop == hop else { return }
        terminate(error: error, cancelled: control.isCancelled || shared.isStopping)
    }

    private func followRedirect(_ head: HTTPResponseHead) throws -> Bool {
        guard [301, 302, 303, 307, 308].contains(Int(head.status.code)) else { return false }
        switch request.redirect {
        case .manual: return false
        case .error: throw WorkflowError.invalid("fetch 收到了重定向")
        case .follow: break
        }
        guard let location = head.headers.first(name: "location") else { return false }
        guard hop < 20, let nextURL = URL(string: location, relativeTo: target.url)?.absoluteURL else {
            throw WorkflowError.invalid("fetch 重定向次数过多或地址无效")
        }
        let next = try ProxyHTTPServiceTransport.Target(nextURL.absoluteString, listenerPort: configuration.port)
        if next.origin != target.origin {
            request.headers.removeAll { ["authorization", "proxy-authorization", "cookie"].contains($0.name.lowercased()) }
        }
        let method = request.method.uppercased()
        if ([301, 302].contains(Int(head.status.code)) && method == "POST")
            || (head.status.code == 303 && !["GET", "HEAD"].contains(method)) {
            request.method = "GET"; request.body = nil
            request.headers.removeAll { ["content-encoding", "content-language", "content-location", "content-type"].contains($0.name.lowercased()) }
        }
        target = next; request.url = next.url.absoluteString; hop += 1; redirected = true
        receivedHead = false; requestWriteCompleted = false
        if let previous = channel { channel = nil; closeProxyChannel(previous) }
        loop.execute { [self] in connect() }
        return true
    }

    private func terminate(error: (any Error)?, cancelled: Bool) {
        guard !finished else { return }; finished = true
        if let cancellationID { control.removeCancellationHandler(cancellationID); self.cancellationID = nil }
        if let channel { self.channel = nil; closeProxyChannel(channel) }
        if !responseCompleted {
            responseCompleted = true
            response.fail(error ?? WorkflowError.invalid("fetch 未收到响应"))
        }
        if let error { bodyCompleted = true; body.fail(error) }
        let complete = error == nil
        if !requestWriteCompleted {
            record.sentBody = .collected(data: request.body ?? Data(), headers: record.sentHeaders, isComplete: false)
        }
        record.connectionState = complete || cancelled ? .closed : .failed
        record.outcome = complete || cancelled ? .forwarded : .failed
        record.error = cancelled ? nil : error.map(ProxyTLS.errorDescription)
        record.closeReason = cancelled ? "脚本辅助请求已取消" : nil
        let elapsed = started.duration(to: .now).components
        record.duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        storage.finish(on: loop).whenComplete { [self] stored in
            switch stored {
            case .success(let stored):
                record.receivedBody = .collected(data: stored.bytes, headers: record.receivedHeaders,
                    isComplete: complete && stored.error == nil)
                record.responseBody = record.receivedBody
                if let storageError = stored.error {
                    record.error = storageError.localizedDescription; record.outcome = .failed
                }
                if !bodyCompleted {
                    bodyCompleted = true
                    if let storageError = stored.error { body.fail(storageError) } else { body.succeed(stored.bytes) }
                }
            case .failure(let storageError):
                record.receivedBody = .unavailable("辅助请求正文读取失败：" + storageError.localizedDescription)
                record.responseBody = record.receivedBody
                record.error = storageError.localizedDescription; record.outcome = .failed
                if !bodyCompleted { bodyCompleted = true; body.fail(storageError) }
            }
            publish(); permit.release()
        }
    }
    private func publish() { records.append(record, generation: generation) }
}

private final class ScriptHTTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let owner: ScriptHTTPOperation
    let hop: Int
    init(owner: ScriptHTTPOperation, hop: Int) { self.owner = owner; self.hop = hop }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { owner.receive(unwrapInboundIn(data), hop: hop) }
    func channelReadComplete(context: ChannelHandlerContext) { owner.readComplete(hop: hop) }
    func channelInactive(context: ChannelHandlerContext) { owner.disconnected(hop: hop) }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { owner.failed(error, hop: hop) }
}
