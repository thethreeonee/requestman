import NIOCore
import RequestmanCore

/// NIOSSL's public ClientHello callback exposes SNI but not ALPN. Inspect the
/// unencrypted offer before installing TLS; NIOSSL still validates the handshake.
struct ClientHelloALPNParser {
    private var records = ByteBuffer()
    private var handshake = ByteBuffer()
    static let maximumBytes = 256 * 1024

    mutating func append(_ bytes: ByteBuffer) throws -> [String]? {
        records.writeImmutableBuffer(bytes)
        guard records.readableBytes + handshake.readableBytes <= Self.maximumBytes else { throw invalid() }
        while records.readableBytes >= 5 {
            let offset = records.readerIndex
            guard records.getInteger(at: offset, as: UInt8.self) == 22,
                  let length = records.getInteger(at: offset + 3, as: UInt16.self), length > 0, length <= 16_384 else { throw invalid() }
            guard records.readableBytes >= 5 + Int(length) else { return nil }
            records.moveReaderIndex(forwardBy: 5)
            handshake.writeImmutableBuffer(records.readSlice(length: Int(length))!)
            records.discardReadBytes()
            guard handshake.readableBytes >= 4 else { continue }
            let start = handshake.readerIndex
            guard handshake.getInteger(at: start, as: UInt8.self) == 1 else { throw invalid() }
            let helloLength = Int(handshake.getInteger(at: start + 1, as: UInt8.self)!) << 16
                | Int(handshake.getInteger(at: start + 2, as: UInt16.self)!)
            guard helloLength + 4 <= Self.maximumBytes else { throw invalid() }
            guard let body = handshake.getSlice(at: start + 4, length: helloLength) else { continue }
            return try protocols(in: body)
        }
        return nil
    }

    private func protocols(in body: ByteBuffer) throws -> [String] {
        var hello = body
        guard hello.readSlice(length: 34) != nil else { throw invalid() } // legacy version + random
        _ = try vector(&hello, wide: false) // session id
        _ = try vector(&hello, wide: true) // cipher suites
        _ = try vector(&hello, wide: false) // compression methods
        if hello.readableBytes == 0 { return [] }
        var extensions = try vector(&hello, wide: true)
        guard hello.readableBytes == 0 else { throw invalid() }
        var offered: [String]?
        while extensions.readableBytes > 0 {
            guard let kind = extensions.readInteger(as: UInt16.self) else { throw invalid() }
            var value = try vector(&extensions, wide: true)
            if kind == 16 {
                guard offered == nil else { throw invalid() }
                var names = try vector(&value, wide: true)
                guard value.readableBytes == 0, names.readableBytes > 0 else { throw invalid() }
                offered = []
                while names.readableBytes > 0 {
                    let name = try vector(&names, wide: false)
                    guard name.readableBytes > 0 else { throw invalid() }
                    // ALPN names are opaque bytes. Only recognize our exact ASCII protocols.
                    if name.readableBytesView.elementsEqual("h2".utf8) { offered?.append("h2") }
                    if name.readableBytesView.elementsEqual("http/1.1".utf8) { offered?.append("http/1.1") }
                }
            }
        }
        return offered ?? []
    }
    private func vector(_ buffer: inout ByteBuffer, wide: Bool) throws -> ByteBuffer {
        let count = wide ? buffer.readInteger(as: UInt16.self).map(Int.init) : buffer.readInteger(as: UInt8.self).map(Int.init)
        guard let count, let bytes = buffer.readSlice(length: count) else { throw invalid() }
        return bytes
    }
    private func invalid() -> WorkflowError { .invalid("客户端 TLS ClientHello 无效或过大") }
}

final class ClientHelloALPN: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var parser = ClientHelloALPNParser()
    private var buffered = ByteBuffer()
    private var configuring = false
    private let configure: @Sendable ([String]) -> EventLoopFuture<Void>
    private let failure: @Sendable (Error) -> Void
    init(configure: @escaping @Sendable ([String]) -> EventLoopFuture<Void>, failure: @escaping @Sendable (Error) -> Void) {
        self.configure = configure; self.failure = failure
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        buffered.writeImmutableBuffer(bytes)
        do {
            guard buffered.readableBytes <= ClientHelloALPNParser.maximumBytes else { throw WorkflowError.invalid("客户端 TLS ClientHello 过大") }
            guard !configuring, let protocols = try parser.append(bytes) else { return }
            configuring = true
            let channel = context.channel
            configure(protocols).flatMap { channel.pipeline.removeHandler(self) }.whenComplete { [self] result in
                switch result {
                case .success:
                    channel.pipeline.fireChannelRead(buffered); buffered = ByteBuffer()
                    channel.pipeline.fireChannelReadComplete()
                case .failure(let error): failure(error); closeProxyChannel(channel)
                }
            }
        } catch { failure(error); context.close(promise: nil) }
    }
    func channelReadComplete(context: ChannelHandlerContext) { if !configuring { context.read() } }
    func channelInactive(context: ChannelHandlerContext) {
        failure(WorkflowError.invalid("客户端在 TLS 协商前关闭连接")); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { failure(error); context.close(promise: nil) }
}
