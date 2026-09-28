import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS
import RequestmanCertificates
import RequestmanCore

extension ProxyConnection {
    func beginTunnel(_ head: HTTPRequestHead) {
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
    func configureTunnel(_ kind: ConnectProtocolDetector.Kind, host: String, port: Int, authority: String) -> EventLoopFuture<Void> {
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
            if let identity {
                return client.pipeline.addHandler(ClientHelloALPN(configure: { [self] offered in
                    let origin: EventLoopFuture<PreparedTLSOrigin?>
                    if offered.contains("h2"), offered.contains("http/1.1") {
                        origin = prepareTLSOrigin(host: host, port: port, authority: authority).map { Optional($0) }
                    } else { origin = client.eventLoop.makeSucceededFuture(nil) }
                    return origin.flatMap { prepared in
                        guard client.isActive, self.isProcessing else {
                            return client.eventLoop.makeFailedFuture(WorkflowError.invalid("CONNECT 已取消"))
                        }
                        return self.installDecryptedTunnel(client, identity: identity, authority: authority, prepared: prepared)
                    }
                }, failure: { [self] error in finish(error: "CONNECT 建立失败：" + error.localizedDescription) }))
            }
            if kind == .http {
                return installTunnelHTTP1(client, tlsAuthority: nil, plainAuthority: authority)
                    .map { self.finished = true; self.timer?.cancel(); self.pending.removeAll() }
            }
            return connectOpaqueTunnel(host: host, port: port, authority: authority)
        }.flatMapError { [self] error in
            finish(error: "CONNECT 建立失败：" + error.localizedDescription)
            return client.eventLoop.makeFailedFuture(error)
        }
    }
    private func installDecryptedTunnel(_ client: Channel, identity: TLSCertificateIdentity, authority: String,
                                        prepared: PreparedTLSOrigin?) -> EventLoopFuture<Void> {
        let protocols = prepared.map { [$0.protocolName] } ?? ["h2", "http/1.1"]
        return client.eventLoop.makeCompletedFuture {
            try client.pipeline.syncOperations.addHandlers(NIOSSLServerHandler(context: self.shared.tlsContexts.server(identity, protocols: protocols)),
                DownstreamTLSHandshake(authority: authority, records: self.records))
        }.flatMap {
            client.configureHTTP2SecureUpgrade(h2ChannelConfigurator: { channel in
                let session = ProxyHTTP2Session(downstream: channel, configuration: self.configuration, shared: self.shared, preparedOrigin: prepared)
                return channel.setOption(ChannelOptions.autoRead, value: true).flatMap {
                    channel.configureHTTP2Pipeline(mode: .server,
                        connectionConfiguration: proxyHTTP2Configuration(server: true), streamConfiguration: .init(),
                        inboundStreamInitializer: { stream in
                            session.accept(stream)
                            return stream.setOption(ChannelOptions.autoRead, value: false).flatMap {
                                stream.eventLoop.makeCompletedFuture {
                                    let owner = ProxyConnection(configuration: self.configuration, shared: self.shared, records: self.records,
                                                                tlsAuthority: authority, http2Session: session)
                                    try stream.pipeline.syncOperations.addHandlers(ProxyHTTP2Headers(owner: owner, response: false),
                                        HTTP2FramePayloadToHTTP1ServerCodec(), owner)
                                }
                            }
                        }).flatMap { _ in channel.pipeline.addHandler(HTTP2ServerLifecycle()) }
                }
            }, http1ChannelConfigurator: { channel in
                self.installTunnelHTTP1(channel, tlsAuthority: authority, plainAuthority: nil, preparedOrigin: prepared)
            })
        }.map { self.finished = true; self.timer?.cancel(); self.pending.removeAll() }
    }
    private func installTunnelHTTP1(_ channel: Channel, tlsAuthority: String?, plainAuthority: String?, preparedOrigin: PreparedTLSOrigin? = nil) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            var encoder = HTTPResponseEncoder.Configuration(); encoder.automaticallySetFramingHeaders = false
            try channel.pipeline.syncOperations.addHandlers([
                HTTPResponseEncoder(configuration: encoder),
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes, limitConfiguration: proxyDecoderLimits())),
                ProxyConnection(configuration: self.configuration, shared: self.shared, records: self.records,
                                tlsAuthority: tlsAuthority, plainAuthority: plainAuthority, preparedOrigin: preparedOrigin)
            ])
        }
    }
    func connectOpaqueTunnel(host: String, port: Int, authority: String) -> EventLoopFuture<Void> {
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

private final class HTTP2ServerLifecycle: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !(error is NIOHTTP2Errors.StreamError) { context.close(promise: nil) }
    }
}

/// Bounds the TLS handshake before ALPN installs an HTTP/1 connection or HTTP/2 streams.
private final class DownstreamTLSHandshake: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let authority: String
    let records: CaptureRecordBuffer
    let generation: UInt64
    var timer: Scheduled<Void>?
    var complete = false
    init(authority: String, records: CaptureRecordBuffer) {
        self.authority = authority; self.records = records; self.generation = records.generation
    }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        timer = channel.eventLoop.scheduleTask(in: .seconds(30)) { [self] in
            recordFailure("客户端 TLS 握手超时", channel: channel); channel.close(promise: nil)
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted = event as? TLSUserEvent {
            complete = true; timer?.cancel(); timer = nil
            context.fireUserInboundEventTriggered(event)
            context.pipeline.removeHandler(self, promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        if !complete { context.read() }
        context.fireChannelReadComplete()
    }
    func channelInactive(context: ChannelHandlerContext) { timer?.cancel(); timer = nil; context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        recordFailure("客户端 TLS 连接失败：" + ProxyTLS.errorDescription(error), channel: context.channel)
        context.close(promise: nil)
    }
    private func recordFailure(_ message: String, channel: Channel) {
        guard !complete else { return }; complete = true; timer?.cancel(); timer = nil
        var record = CaptureRecord(method: "CONNECT", url: "https://" + authority)
        record.outcome = .failed; record.connectionState = .failed; record.error = message
        record.deviceSource = channel.remoteAddress?.ipAddress.map(DeviceSource.identifier(for:))
        records.append(record, generation: generation)
    }
}
