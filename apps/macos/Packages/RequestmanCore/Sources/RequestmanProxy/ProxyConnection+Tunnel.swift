import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
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
