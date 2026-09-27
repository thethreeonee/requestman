import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import RequestmanCore

extension ProxyConnection {
    func connectHTTP(endpoint: ProxyEndpoint, targetHost: String, targetPort: Int, secure: Bool, on loop: EventLoop) -> EventLoopFuture<Channel> {
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

    func isLoopChannel(_ channel: Channel) -> Bool {
        channel.remoteAddress?.port == configuration.port && LocalNetwork.isLocalHost(channel.remoteAddress?.ipAddress ?? "")
    }
    func isLoop(_ host: String, port: Int) -> Bool {
        port == configuration.port && LocalNetwork.isLocalHost(host)
    }
    func bootstrap(on eventLoop: EventLoop) -> ClientBootstrap {
        ClientBootstrap(group: eventLoop).connectTimeout(.seconds(5))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
            .channelInitializer { [shared] channel in
                guard shared.register(channel, downstream: false) else { return channel.close() }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
    }
    func fields(_ headers: HTTPHeaders) -> [HTTPField] { headers.map { HTTPField($0.name, $0.value) } }
    func cleanHeaders(_ fields: [HTTPField]) -> HTTPHeaders {
        let connectionTokens = fields.filter { $0.name.lowercased() == "connection" }.flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let removed = Set(connectionTokens + ["connection", "proxy-connection", "proxy-authorization", "proxy-authenticate", "keep-alive", "te", "trailer", "upgrade", "transfer-encoding"])
        return HTTPHeaders(fields.filter { !removed.contains($0.name.lowercased()) }.map { ($0.name, $0.value) })
    }

    func headerTokens(_ headers: HTTPHeaders, name: String) -> [String] {
        headers[name].flatMap { $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }
}
