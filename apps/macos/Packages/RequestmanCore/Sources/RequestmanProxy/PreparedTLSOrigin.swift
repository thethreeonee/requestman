import NIOCore
import NIOHTTP1
import RequestmanCore

/// One authenticated origin connection selected while a dual-protocol browser is
/// still in ClientHello. The first matching request adopts it without a second TLS handshake.
final class PreparedTLSOrigin: @unchecked Sendable {
    let channel: Channel
    let protocolName: String
    let host: String
    let port: Int
    let endpoint: ProxyEndpoint
    let buffer: TLSHandshakeBuffer
    private var claimed = false
    private var idleTimer: Scheduled<Void>?
    init(channel: Channel, protocolName: String, host: String, port: Int, endpoint: ProxyEndpoint, buffer: TLSHandshakeBuffer) {
        self.channel = channel; self.protocolName = protocolName; self.host = host; self.port = port
        self.endpoint = endpoint; self.buffer = buffer
        idleTimer = channel.eventLoop.scheduleTask(in: .seconds(30)) { closeProxyChannel(channel) }
        channel.closeFuture.whenComplete { [weak self] _ in self?.idleTimer?.cancel(); self?.idleTimer = nil }
    }
    func take(host: String, port: Int, endpoint: ProxyEndpoint) -> PreparedTLSOrigin? {
        guard !claimed else { return nil }; claimed = true
        idleTimer?.cancel(); idleTimer = nil
        guard channel.isActive, self.host.lowercased() == host.lowercased(), self.port == port,
              self.endpoint == endpoint else { closeProxyChannel(channel); return nil }
        return self
    }
    func activate<Value: Sendable>(_ configure: () -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        configure().flatMap { value in self.channel.pipeline.removeHandler(self.buffer).map { value } }
    }
}

/// Preserve any TLS application bytes (e.g. HTTP/2 SETTINGS) arriving before the
/// browser handshake finishes and the request owner installs its HTTP handlers.
final class TLSHandshakeBuffer: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var buffered: [ByteBuffer] = []
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { buffered.append(unwrapInboundIn(data)) }
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        for bytes in buffered { context.fireChannelRead(NIOAny(bytes)) }
        buffered.removeAll(); context.fireChannelReadComplete()
        context.leavePipeline(removalToken: removalToken)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

extension ProxyConnection {
    func prepareTLSOrigin(host: String, port: Int, authority: String) -> EventLoopFuture<PreparedTLSOrigin> {
        guard let client else { preconditionFailure("CONNECT has a client") }
        let loop = client.eventLoop
        let endpoint: ProxyEndpoint
        if case .httpProxy(let proxy) = configuration.upstream { endpoint = proxy }
        else { endpoint = ProxyEndpoint(host: host, port: port) }
        return bootstrap(on: loop).connect(host: endpoint.host, port: endpoint.port).flatMap { [self] channel in
            client.closeFuture.whenComplete { _ in closeProxyChannel(channel) }
            guard client.isActive, isProcessing, !isLoopChannel(channel) else {
                closeProxyChannel(channel); return loop.makeFailedFuture(WorkflowError.invalid("CONNECT 已取消或指向代理自身"))
            }
            let deadline = loop.scheduleTask(in: .seconds(30)) { closeProxyChannel(channel) }
            let tunnel: EventLoopFuture<Void>
            if case .httpProxy = configuration.upstream {
                let handshake = loop.makePromise(of: Void.self)
                tunnel = channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, decoderLimitConfiguration: proxyDecoderLimits()).flatMap {
                    channel.pipeline.addHandler(TunnelHandshake(ready: handshake))
                }.flatMap {
                    channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: authority, headers: HTTPHeaders([("Host", authority)]))), promise: nil)
                    channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil); channel.read()
                    return handshake.futureResult
                }
            } else { tunnel = loop.makeSucceededVoidFuture() }
            let result = tunnel.flatMap {
                ProxyTLS.negotiateClient(channel: channel, host: host, browserOffer: true, shared: self.shared) { selected in
                    let buffer = TLSHandshakeBuffer()
                    return channel.pipeline.addHandler(buffer).map {
                        PreparedTLSOrigin(channel: channel, protocolName: selected, host: host, port: port, endpoint: endpoint, buffer: buffer)
                    }
                }
            }
            result.whenComplete { result in
                deadline.cancel()
                if case .failure = result { closeProxyChannel(channel) }
            }
            return result
        }
    }
}
