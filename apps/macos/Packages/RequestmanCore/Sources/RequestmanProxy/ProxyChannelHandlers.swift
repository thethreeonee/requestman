import NIOCore
import NIOHTTP1
import RequestmanCore

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

extension ChannelPipeline {
    func removeHTTPHandler<Handler: ChannelHandler>(_ type: Handler.Type) -> EventLoopFuture<Void> {
        do { return try syncOperations.removeHandler(context: syncOperations.context(handlerType: type)) }
        catch { return eventLoop.makeFailedFuture(error) }
    }
}

func proxyDecoderLimits() -> NIOHTTPDecoderLimitConfiguration {
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
