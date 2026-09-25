import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import RequestmanCore
import os

/// Explicit loopback proxy. Every connection handler is confined to the group's single event loop.
public actor LocalProxyServer {
    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private let shared = ProxySharedState()
    public nonisolated let records = CaptureRecordBuffer()
    public init() {}
    public func update(_ document: WorkspaceDocument) { shared.document.withLock { $0 = document } }
    public func start(configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        guard listener == nil, group == nil else { throw WorkflowError.invalid("代理已启动") }
        try configuration.validate()
        update(document)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let shared = shared, records = records
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
                .childChannelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 16_384, high: 65_536))
                .childChannelInitializer { channel in
                    guard shared.register(channel) else {
                        var record = CaptureRecord(method: "—", url: "连接未受理")
                        record.outcome = .failed; record.workflow = "连接容量上限"
                        record.error = "当前已有 64 个连接"
                        records.append(record)
                        return channel.close()
                    }
                    channel.closeFuture.whenComplete { _ in shared.unregister(channel) }
                    return channel.eventLoop.makeCompletedFuture { () throws -> Void in
                        var encoder = HTTPResponseEncoder.Configuration()
                        encoder.automaticallySetFramingHeaders = false
                        try channel.pipeline.syncOperations.addHandlers([
                            HTTPResponseEncoder(configuration: encoder),
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes, limitConfiguration: proxyDecoderLimits())),
                            ProxyConnection(configuration: configuration, shared: shared, records: records)
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
        // Close downstream channels first; their handlers cancel pending connects and close upstream peers.
        for channel in shared.channels.withLock({ Array($0.values) }) { try? await channel.close().get() }
        try? await group?.shutdownGracefully()
        group = nil
    }
}

final class ProxySharedState: Sendable {
    let document = OSAllocatedUnfairLock(initialState: WorkspaceDocument())
    let generatedBodyBytes = OSAllocatedUnfairLock(initialState: 0)
    func reserveBody(_ body: String) throws -> GeneratedBodyReservation {
        let bytes = body.utf8.count
        guard generatedBodyBytes.withLock({ used in
            guard bytes <= 16 * 1_048_576 - used else { return false }
            used += bytes; return true
        }) else { throw WorkflowError.invalid("替换内容的全局内存预算已满（16 MiB）") }
        return GeneratedBodyReservation(bytes: bytes, budget: generatedBodyBytes)
    }
    let channels = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Channel]())
    func register(_ channel: Channel) -> Bool {
        channels.withLock { channels in
            guard channels.count < 64 else { return false }
            channels[ObjectIdentifier(channel)] = channel
            return true
        }
    }
    func unregister(_ channel: Channel) { _ = channels.withLock { $0.removeValue(forKey: ObjectIdentifier(channel)) } }
}

/// All access stays on one NIO EventLoop, including peer callbacks. No Task per packet or UI call here.
final class ProxyConnection: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    private let configuration: ExplicitProxyConfiguration
    private let shared: ProxySharedState
    private let records: CaptureRecordBuffer
    private var client: Channel?
    private var upstream: Channel?
    private var timer: Scheduled<Void>?
    private var record: CaptureRecord?
    private var started = ContinuousClock.now
    private var match: WorkflowMatch?
    private var request: HTTPMessageDraft?
    private var response: HTTPMessageDraft?
    private var pending: [HTTPServerRequestPart] = []
    private var pendingBytes = 0
    private var lastRequestWrite: EventLoopFuture<Void>?
    private var lastResponseWrite: EventLoopFuture<Void>?
    private var responseEnded = false
    private var informationalResponse = false
    private var bodyReservations: [GeneratedBodyReservation] = []
    private var connected = false
    private var requestEnded = false
    private var responseStarted = false
    private var finished = false
    private var tunnel = false
    private var originalMethod = "GET"

    init(configuration: ExplicitProxyConfiguration, shared: ProxySharedState, records: CaptureRecordBuffer) {
        self.configuration = configuration; self.shared = shared; self.records = records
    }
    func channelActive(context: ChannelHandlerContext) {
        client = context.channel
        timer = context.eventLoop.scheduleTask(in: .seconds(30)) { [self] in fail("请求超时", status: 504) }
        context.read()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            guard record == nil else { return fail("不支持同一连接上的流水线请求", status: 400) }
            begin(head)
        case .body(let buffer):
            record?.requestBytes += buffer.readableBytes
            if !connected { enqueue(part, bytes: buffer.readableBytes) } else { forward(part) }
        case .end:
            requestEnded = true
            if !connected { enqueue(part, bytes: 0) } else { forward(part) }
        }
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        guard connected, !finished, !tunnel else { return }
        flushRequest()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error.localizedDescription, status: 400) }
    func channelInactive(context: ChannelHandlerContext) {
        timer?.cancel()
        if !finished { finish(error: "客户端连接已关闭") }
        upstream?.close(promise: nil)
    }
    private func enqueue(_ part: HTTPServerRequestPart, bytes: Int) {
        pendingBytes += bytes
        guard pendingBytes <= 65_536, pending.count < 128 else { return fail("连接预读缓冲已满", status: 503) }
        pending.append(part)
    }
    private func begin(_ head: HTTPRequestHead) {
        guard let client else { return }
        originalMethod = head.method.rawValue
        record = CaptureRecord(method: originalMethod, url: head.uri)
        record?.requestHeaders = fields(head.headers)
        record?.environment = shared.document.withLock { $0.environment?.name ?? "无环境" }
        started = .now
        if head.method == .CONNECT { return beginTunnel(head) }
        guard head.method != .TRACE, head.headers["upgrade"].isEmpty else { return fail("当前不支持协议升级或 TRACE", status: 501) }
        guard let url = URL(string: head.uri), url.scheme == "http", url.host != nil,
              url.user == nil, url.fragment == nil else { return fail("需要 http:// 绝对请求地址", status: 400) }
        do {
            let document = shared.document.withLock { $0 }
            match = WorkflowEngine.match(document, method: originalMethod, url: head.uri)
            record?.environment = document.environment?.name ?? "无环境"
            var draft = HTTPMessageDraft(method: originalMethod, url: head.uri, headers: fields(head.headers))
            if let match, let record {
                self.record?.project = match.project; self.record?.workflow = match.workflow.name
                self.record?.steps = try WorkflowEngine.apply(match.workflow.requestSteps, response: false, to: &draft,
                    environment: match.environment?.values ?? [:], id: record.id, date: record.startedAt)
            }
            record?.finalURL = draft.url; record?.sentMethod = draft.method
            try reserveBody(draft.replacementBody)
            request = draft
            if draft.isMock {
                record?.outcome = .mocked
                var reply = draft
                if let match, let record {
                    self.record?.steps += try WorkflowEngine.apply(match.workflow.responseSteps, response: true, to: &reply,
                        environment: match.environment?.values ?? [:], id: record.id, date: record.startedAt)
                }
                if reply.replacementBody != draft.replacementBody { try reserveBody(reply.replacementBody) }
                return sendStatic(reply)
            }
            guard let target = URLComponents(string: draft.url), let host = target.host else { throw WorkflowError.invalid("目标地址无效") }
            let port = target.port ?? 80
            guard !isLoop(host, port: port) else { throw WorkflowError.invalid("请求目标会形成代理循环") }
            var headers = cleanHeaders(draft.headers)
            headers.replaceOrAdd(name: "Host", value: target.percentEncodedHost.map { $0 + (target.port.map { ":\($0)" } ?? "") } ?? host)
            headers.replaceOrAdd(name: "Connection", value: "close")
            headers.remove(name: "Expect")
            if let body = draft.replacementBody {
                headers.remove(name: "Transfer-Encoding"); headers.replaceOrAdd(name: "Content-Length", value: String(body.utf8.count))
            } else if head.headers.contains(name: "transfer-encoding") {
                headers.remove(name: "Content-Length"); headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            }
            let uri: String
            let endpoint: ProxyEndpoint
            if case .httpProxy(let proxy) = configuration.upstream { endpoint = proxy; uri = draft.url }
            else { endpoint = ProxyEndpoint(host: host, port: port); uri = (target.percentEncodedPath.isEmpty ? "/" : target.percentEncodedPath) + (target.percentEncodedQuery.map { "?\($0)" } ?? "") }
            record?.sentHeaders = fields(headers)
            let forwarded = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: draft.method), uri: uri, headers: headers)
            if head.headers["expect"].contains(where: { $0.lowercased() == "100-continue" }) {
                client.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .continue)), promise: nil)
            }
            bootstrap(on: client.eventLoop).channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers(decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                    channel.pipeline.addHandler(ProxyResponseHandler(owner: self))
                }
            }.connect(host: endpoint.host, port: endpoint.port).whenComplete { [self] result in
                switch result {
                case .failure(let error): fail(error.localizedDescription, status: 502)
                case .success(let channel):
                    guard !finished else { channel.close(promise: nil); return }
                    guard !isLoopChannel(channel) else { channel.close(promise: nil); fail("目标解析后指向代理自身", status: 502); return }
                    upstream = channel; connected = true
                    lastRequestWrite = channel.write(HTTPClientRequestPart.head(forwarded))
                    if let body = request?.replacementBody { lastRequestWrite = channel.write(HTTPClientRequestPart.body(.byteBuffer(channel.allocator.buffer(string: body)))) }
                    for part in pending { forward(part) }
                    pending.removeAll(); pendingBytes = 0
                    flushRequest()
                    channel.read()
                }
            }
        } catch { fail(error.localizedDescription, status: 400) }
    }
    private func forward(_ part: HTTPServerRequestPart) {
        guard let upstream, !tunnel else { return }
        switch part {
        case .body(let bytes):
            if request?.replacementBody == nil { lastRequestWrite = upstream.write(HTTPClientRequestPart.body(.byteBuffer(bytes))) }
        case .end: lastRequestWrite = upstream.write(HTTPClientRequestPart.end(nil))
        case .head: break
        }
    }
    private func flushRequest() {
        guard let upstream else { return }
        upstream.flush()
        let flushed = lastRequestWrite ?? upstream.eventLoop.makeSucceededFuture(())
        flushed.whenComplete { [self] result in
            if case .failure(let error) = result { fail(error.localizedDescription, status: 502) }
            else if !requestEnded && !finished { client?.read() }
        }
    }
    func receive(_ part: HTTPClientResponsePart, channel: Channel) {
        guard !finished else { return }
        do {
            switch part {
            case .head(let head):
                if head.status.code < 200 {
                    informationalResponse = true
                    if head.status == .switchingProtocols { fail("当前不支持协议升级", status: 501) }
                    return
                }
                informationalResponse = false
                guard !responseStarted else { return fail("重复响应头", status: 502) }
                var draft = HTTPMessageDraft(method: originalMethod, url: request?.url ?? "", status: Int(head.status.code), headers: fields(head.headers))
                record?.receivedHeaders = draft.headers
                if let match, let record {
                    self.record?.steps += try WorkflowEngine.apply(match.workflow.responseSteps, response: true, to: &draft,
                        environment: match.environment?.values ?? [:], id: record.id, date: record.startedAt)
                }
                try reserveBody(draft.replacementBody)
                response = draft
                var headers = responseHeaders(draft)
                headers.replaceOrAdd(name: "Connection", value: "close")
                record?.responseHeaders = fields(headers); record?.status = draft.status
                responseStarted = true
                lastResponseWrite = client?.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: draft.status), headers: headers)))
                if let body = draft.replacementBody, allowsBody(draft.status), let client {
                    lastResponseWrite = client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(string: body))))
                }
            case .body(let buffer):
                record?.responseBytes += buffer.readableBytes
                if let response, response.replacementBody == nil, allowsBody(response.status) {
                    lastResponseWrite = client?.write(HTTPServerResponsePart.body(.byteBuffer(buffer)))
                }
            case .end:
                if informationalResponse { informationalResponse = false; return }
                guard responseStarted, let client else { return fail("上游未返回完整响应", status: 502) }
                responseEnded = true
                client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [self] result in
                    if case .failure(let error) = result { finish(error: error.localizedDescription) }
                    else { finish() }
                    client.close(promise: nil); channel.close(promise: nil)
                }
            }
        } catch { fail(error.localizedDescription, status: 502) }
    }
    func responseReadComplete(_ channel: Channel) {
        guard let client, !finished else { return }
        client.flush()
        guard !responseEnded else { return }
        let flushed = lastResponseWrite ?? channel.eventLoop.makeSucceededFuture(())
        flushed.whenComplete { [self] result in
            if case .failure(let error) = result { fail(error.localizedDescription, status: 502) }
            else if !finished { channel.read() }
        }
    }
    func upstreamClosed() { if !finished && !responseEnded { fail("上游连接提前关闭", status: 502) } }
    func upstreamError(_ error: Error) { fail(error.localizedDescription, status: 502) }

    private func reserveBody(_ body: String?) throws {
        if let body { bodyReservations.append(try shared.reserveBody(body)) }
    }
    private func sendStatic(_ draft: HTTPMessageDraft) {
        guard let client else { return }
        responseStarted = true
        let headers = responseHeaders(draft)
        record?.status = draft.status; record?.responseHeaders = fields(headers)
        client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: draft.status), headers: headers)), promise: nil)
        if allowsBody(draft.status), let body = draft.replacementBody {
            record?.responseBytes = body.utf8.count
            lastResponseWrite = client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(string: body))))
        }
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [self] result in
            if case .failure(let error) = result { finish(error: error.localizedDescription) } else { finish() }
            client.close(promise: nil)
        }
    }
    private func responseHeaders(_ draft: HTTPMessageDraft) -> HTTPHeaders {
        var headers = cleanHeaders(draft.headers)
        headers.remove(name: "Content-Length"); headers.remove(name: "Transfer-Encoding")
        headers.replaceOrAdd(name: "Connection", value: "close")
        if let body = draft.replacementBody, draft.status != 204, draft.status != 205, draft.status != 304 {
            headers.replaceOrAdd(name: "Content-Length", value: String(body.utf8.count))
        } else if allowsBody(draft.status) { headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked") }
        return headers
    }
    private func allowsBody(_ status: Int) -> Bool { originalMethod != "HEAD" && status != 204 && status != 205 && status != 304 }
    private func fail(_ message: String, status: Int) {
        guard !finished else { return }
        let alreadyResponding = responseStarted
        if !alreadyResponding { record?.status = status }
        finish(error: message)
        upstream?.close(promise: nil)
        guard let client else { return }
        if alreadyResponding || tunnel { client.close(promise: nil); return }
        let body = "Requestman: \(message)"
        let headers = HTTPHeaders([("Connection", "close"), ("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(body.utf8.count))])
        client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: status), headers: headers)), promise: nil)
        lastResponseWrite = client.write(HTTPServerResponsePart.body(.byteBuffer(client.allocator.buffer(string: body))))
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in client.close(promise: nil) }
    }
    private func finish(error: String? = nil) {
        guard !finished else { return }
        finished = true; timer?.cancel()
        pending.removeAll()
        guard var record else { return }
        let elapsed = started.duration(to: .now).components
        record.duration = Double(elapsed.attoseconds) / 1e18 + Double(elapsed.seconds)
        record.error = error
        if error != nil { record.outcome = .failed }
        else if record.outcome == .forwarded && !record.steps.isEmpty { record.outcome = .modified }
        records.append(record)
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
    }
    private func fields(_ headers: HTTPHeaders) -> [HTTPField] { headers.map { HTTPField($0.name, $0.value) } }
    private func cleanHeaders(_ fields: [HTTPField]) -> HTTPHeaders {
        let connectionTokens = fields.filter { $0.name.lowercased() == "connection" }.flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let removed = Set(connectionTokens + ["connection", "proxy-connection", "proxy-authorization", "proxy-authenticate", "keep-alive", "te", "trailer", "upgrade", "transfer-encoding"])
        return HTTPHeaders(fields.filter { !removed.contains($0.name.lowercased()) }.map { ($0.name, $0.value) })
    }

    private func beginTunnel(_ head: HTTPRequestHead) {
        guard let client, let target = URLComponents(string: "https://" + head.uri), let host = target.host,
              let port = target.port, target.path.isEmpty, target.user == nil, target.query == nil,
              target.fragment == nil, (1...65535).contains(port), !isLoop(host, port: port) else {
            return fail("CONNECT 目标无效", status: 400)
        }
        guard head.headers["transfer-encoding"].isEmpty,
              head.headers["content-length"].allSatisfy({ $0 == "0" }) else { return fail("CONNECT 不接受 HTTP Body", status: 400) }
        record?.outcome = .tunnel; record?.workflow = "HTTPS 透传（未解密）"
        let endpoint: ProxyEndpoint
        if case .httpProxy(let proxy) = configuration.upstream { endpoint = proxy }
        else { endpoint = ProxyEndpoint(host: host, port: port) }
        let bootstrap = bootstrap(on: client.eventLoop)
        bootstrap.connect(host: endpoint.host, port: endpoint.port).flatMap { [self] peer -> EventLoopFuture<Channel> in
            guard !finished, !isLoopChannel(peer) else {
                peer.close(promise: nil)
                return peer.eventLoop.makeFailedFuture(WorkflowError.invalid("连接已取消或指向代理自身"))
            }
            upstream = peer
            if case .httpProxy = configuration.upstream {
                let ready = peer.eventLoop.makePromise(of: Void.self)
                return peer.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                    peer.pipeline.addHandler(TunnelHandshake(ready: ready))
                }.flatMap {
                    peer.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: head.uri, headers: HTTPHeaders([("Host", head.uri)]))), promise: nil)
                    peer.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil); peer.read()
                    return ready.futureResult
                }.map { peer }
            }
            return peer.eventLoop.makeSucceededFuture(peer)
        }.whenComplete { [self] result in
            switch result {
            case .failure(let error): fail(error.localizedDescription, status: 502)
            case .success(let peer):
                guard !finished else { peer.close(promise: nil); return }
                client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok)), promise: nil)
                client.writeAndFlush(HTTPServerResponsePart.end(nil)).flatMap { [self] in
                    // Install raw relay before releasing bytes held by the CONNECT decoder.
                    client.pipeline.removeHandler(self)
                }.flatMap { [self] in
                    client.eventLoop.makeCompletedFuture { () throws -> Void in
                        try client.pipeline.syncOperations.addHandlers([
                            IdleStateHandler(readTimeout: .seconds(120)),
                            TunnelRelay(peer: peer, onClose: { [self] in finish(); peer.close(promise: nil) })
                        ])
                    }
                }.flatMap {
                    client.pipeline.removeHTTPHandler(HTTPResponseEncoder.self)
                }.flatMap {
                    client.pipeline.removeHTTPHandler(ByteToMessageHandler<HTTPRequestDecoder>.self)
                }.flatMap { [self] in
                    peer.eventLoop.makeCompletedFuture { () throws -> Void in
                        try peer.pipeline.syncOperations.addHandlers([
                            IdleStateHandler(readTimeout: .seconds(120)),
                            TunnelRelay(peer: client, onClose: { [self] in finish(); client.close(promise: nil) })
                        ])
                    }
                }.whenComplete { [self] upgrade in
                    if case .failure(let error) = upgrade { fail(error.localizedDescription, status: 502); return }
                    tunnel = true; connected = true; pending.removeAll(); timer?.cancel()
                    record?.status = 200
                    // Record establishment immediately; opaque TLS bytes are intentionally not inspected.
                    finish()
                    client.read(); peer.read()
                }
            }
        }
    }
}

final class ProxyResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let owner: ProxyConnection
    init(owner: ProxyConnection) { self.owner = owner }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { owner.receive(unwrapInboundIn(data), channel: context.channel) }
    func channelReadComplete(context: ChannelHandlerContext) { owner.responseReadComplete(context.channel) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { owner.upstreamError(error) }
    func channelInactive(context: ChannelHandlerContext) { owner.upstreamClosed() }
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
            if case .success = result { channel.read() } else { channel.close(promise: nil) }
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

// Reservations outlive writes and are released with the closed connection's handlers.
final class GeneratedBodyReservation: Sendable {
    let bytes: Int
    let budget: OSAllocatedUnfairLock<Int>
    init(bytes: Int, budget: OSAllocatedUnfairLock<Int>) { self.bytes = bytes; self.budget = budget }
    deinit { budget.withLock { $0 -= bytes } }
}

private func proxyDecoderLimits() -> NIOHTTPDecoderLimitConfiguration {
    var limits = NIOHTTPDecoderLimitConfiguration()
    limits.maxHeaderFieldSize = 32_768
    limits.maxHeaderListSize = 32_768
    limits.maxHeaderFieldCount = 128
    return limits
}
