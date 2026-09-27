import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import RequestmanCertificates
import RequestmanCore

/// Explicit HTTP proxy with opt-in IPv4 LAN access. Every connection handler is confined to the group's single event loop.
public actor LocalProxyServer {
    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private let shared: ProxySharedState
    public nonisolated let records = CaptureRecordBuffer()
    public nonisolated var events: CaptureEventBuffer { shared.events }
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
        guard listener?.localAddress?.port == configuration.port,
              shared.configuration.withLock({ $0.allowLAN }) == configuration.allowLAN else {
            throw WorkflowError.invalid("监听端口或局域网范围变更需要切换监听")
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
                        record.deviceSource = channel.remoteAddress?.ipAddress.map { DeviceSource.identifier(for: $0) }
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
                            MobileSetupHandler(configuration: configuration, certificateProvider: shared.certificateProvider),
                            ProxyConnection(configuration: shared.configuration.withLock { $0 }, shared: shared, records: records)
                        ])
                    }
                }.bind(host: configuration.allowLAN ? "0.0.0.0" : "127.0.0.1", port: configuration.port).get()
            listener = channel
            return channel.localAddress?.port ?? configuration.port
        } catch {
            try? await group.shutdownGracefully()
            self.group = nil
            throw error
        }
    }
    public func cancelReplay(_ id: UUID) async { shared.replays.withLock { $0[id] }?.cancel() }

    public func replay(_ request: RequestReplayDraft) async throws {
        try Task.checkCancellation()
        try request.validate()
        guard let group, let port = listener?.localAddress?.port else {
            throw WorkflowError.invalid("请先启动捕获，再重放请求")
        }
        let shared = shared
        let session = ProxyReplaySession(request: request, records: records)
        guard shared.replays.withLock({ sessions in
            guard sessions[request.id] == nil else { return false }
            sessions[request.id] = session; return true
        }) else { throw WorkflowError.invalid("此重放正在进行") }
        try await withTaskCancellationHandler {
            let channel: Channel
            do {
                channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(5))
                .channelInitializer { channel in
                    guard shared.register(channel, downstream: false) else { return channel.close() }
                    if request.httpVersion == "HTTP/2" { return channel.eventLoop.makeSucceededVoidFuture() }
                    return channel.pipeline.addHTTPClientHandlers(decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                        channel.pipeline.addHandler(ReplayResponseDrain())
                    }
                }.connect(host: "127.0.0.1", port: port).get()
            } catch {
                session.publishFallback(error: error.localizedDescription)
                _ = shared.replays.withLock { $0.removeValue(forKey: request.id) }
                throw error
            }
            session.attach(channel)
            channel.closeFuture.whenComplete { _ in
                session.clientClosed()
                _ = shared.replays.withLock { $0.removeValue(forKey: request.id) }
            }
            do {
                if Task.isCancelled { session.cancel() }
                if session.isCancelled { throw CancellationError() }
                let target = URLComponents(string: request.url)!
                let transport: Channel
                if request.httpVersion == "HTTP/2" {
                    let host = target.host!
                    guard shared.document.withLock({ $0.httpsDecryption.shouldDecrypt(host: host) }),
                          let provider = shared.certificateProvider,
                          try await provider.serverIdentity(for: host) != nil else {
                        throw WorkflowError.invalid("HTTP/2 重放需要为目标域名启用 HTTPS 解密并配置证书")
                    }
                    transport = try await prepareHTTP2Replay(channel: channel, target: target, shared: shared)
                } else { transport = channel }
                var headers = HTTPHeaders(RequestReplayDraft.editableHeaders(request.headers).map { ($0.name, $0.value) })
                headers.add(name: "Host", value: (target.percentEncodedHost ?? "") + (target.port.map { ":\($0)" } ?? ""))
                headers.add(name: "Content-Length", value: String(request.body.count))
                if request.httpVersion != "HTTP/2" { headers.add(name: "Connection", value: "close") }
                let path = (target.percentEncodedPath.isEmpty ? "/" : target.percentEncodedPath) + (target.percentEncodedQuery.map { "?" + $0 } ?? "")
                let head = HTTPRequestHead(version: request.httpVersion == "HTTP/2" ? .http2 : .http1_1,
                                           method: HTTPMethod(rawValue: request.method), uri: request.httpVersion == "HTTP/2" ? path : request.url, headers: headers)
                transport.write(HTTPClientRequestPart.head(head), promise: nil)
                if !request.body.isEmpty {
                    transport.write(HTTPClientRequestPart.body(.byteBuffer(transport.allocator.buffer(bytes: request.body))), promise: nil)
                }
                try await transport.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
            } catch {
                try? await channel.close().get()
                throw error
            }
        } onCancel: { session.cancel() }
    }

    private func prepareHTTP2Replay(channel: Channel, target: URLComponents, shared: ProxySharedState) async throws -> Channel {
        try await channel.eventLoop.flatSubmit {
            let handshake = channel.eventLoop.makePromise(of: Void.self)
            let authority = (target.percentEncodedHost ?? "") + ":" + String(target.port ?? 443)
            let deadline = channel.eventLoop.scheduleTask(in: .seconds(30)) { channel.close(promise: nil) }
            let ready = channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                channel.pipeline.addHandler(TunnelHandshake(ready: handshake))
            }.flatMap {
                channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: authority, headers: HTTPHeaders([("Host", authority)]))), promise: nil)
                channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                return handshake.futureResult
            }.flatMap {
                ProxyTLS.negotiateClient(channel: channel, host: target.host!, http2: true, shared: shared) {
                    channel.configureHTTP2Pipeline(mode: .client, connectionConfiguration: proxyHTTP2Configuration(server: false), streamConfiguration: .init(), inboundStreamInitializer: { $0.close() })
                }
            }.flatMap { multiplexer in
                multiplexer.createStreamChannel { stream in
                    stream.closeFuture.whenComplete { _ in closeProxyChannel(channel) }
                    return stream.eventLoop.makeCompletedFuture {
                        try stream.pipeline.syncOperations.addHandlers(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https), ReplayResponseDrain())
                    }
                }
            }
            ready.whenComplete { _ in deadline.cancel() }
            return ready
        }.get()
    }

    public func stop() async {
        for replay in shared.replays.withLock({ Array($0.values) }) { replay.cancel(reason: "捕获已停止") }
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

/// The proxy owns response recording. Consume bytes without buffering an SSE stream in the client.
private final class ReplayResponseDrain: ChannelInboundHandler, @unchecked Sendable {
    private var informational = false
    typealias InboundIn = HTTPClientResponsePart
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): informational = head.status.code < 200
        case .end: if !informational { context.close(promise: nil) }
        case .body: break
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
