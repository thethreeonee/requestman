import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import RequestmanCore

extension ProxyConnection {
    func connectHTTP(endpoint: ProxyEndpoint, targetHost: String, targetPort: Int, secure: Bool, on loop: EventLoop) -> EventLoopFuture<Channel> {
        if let http2Session {
            guard secure else { return loop.makeFailedFuture(WorkflowError.invalid("HTTP/2 请求目标必须使用 HTTPS；不转换为 HTTP/1.1")) }
            return http2Session.stream(host: targetHost, port: targetPort, endpoint: endpoint, owner: self)
        }
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
        if secure, let prepared = preparedOrigin?.take(host: targetHost, port: targetPort, endpoint: endpoint) {
            upstream = prepared.channel
            return prepared.activate {
                prepared.channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits())
                    .flatMap { prepared.channel.pipeline.addHandler(ProxyResponseHandler(owner: self)) }.map { prepared.channel }
            }
        }
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
                guard self.isProcessing else { return loop.makeFailedFuture(WorkflowError.invalid("连接已取消")) }
                let configure: @Sendable () -> EventLoopFuture<Channel> = {
                    channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits())
                        .flatMap { channel.pipeline.addHandler(ProxyResponseHandler(owner: self)) }.map { channel }
                }
                if secure { return ProxyTLS.negotiateClient(channel: channel, host: targetHost, http2: false, shared: self.shared, configure: configure) }
                return configure()
            }
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
        var headers = HTTPHeaders(fields.filter { !removed.contains($0.name.lowercased()) }.map { (isHTTP2 ? $0.name.lowercased() : $0.name, $0.value) })
        if isHTTP2, fields.contains(where: { $0.name.lowercased() == "te" && $0.value.lowercased() == "trailers" }) { headers.add(name: "te", value: "trailers") }
        return headers
    }

    func headerTokens(_ headers: HTTPHeaders, name: String) -> [String] {
        headers[name].flatMap { $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }
}
