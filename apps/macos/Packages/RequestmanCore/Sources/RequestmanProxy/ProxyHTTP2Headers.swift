import NIOCore
import NIOHTTP2
import RequestmanCore

struct HTTP2RequestMetadata {
    let scheme: String?
    let authority: String?
    let headers: [HTTPField]
}

/// The NIO HTTP/1 message adapter synthesizes Host and framing fields. Keep the
/// real HTTP/2 fields for recording/execution and validate pseudo-header routing.
final class ProxyHTTP2Headers: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    let owner: ProxyConnection
    let response: Bool
    init(owner: ProxyConnection, response: Bool) { self.owner = owner; self.response = response }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .headers(let block) = unwrapInboundIn(data) {
            let headers = block.headers.filter { !$0.name.hasPrefix(":") }.map { HTTPField($0.name, $0.value) }
            if response, block.headers.contains(name: ":status") {
                owner.http2ResponseHeaders = headers
            } else if !response, block.headers.contains(name: ":method") {
                owner.http2RequestMetadata = HTTP2RequestMetadata(scheme: block.headers.first(name: ":scheme"),
                    authority: block.headers.first(name: ":authority"), headers: headers)
            }
        }
        context.fireChannelRead(data)
    }
}
