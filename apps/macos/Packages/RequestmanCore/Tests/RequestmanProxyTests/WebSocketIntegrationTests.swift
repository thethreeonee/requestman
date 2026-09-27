import Foundation
import CryptoKit
import X509
import NIOSSL
@testable import RequestmanCertificates
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing
import os
import RequestmanCore
@testable import RequestmanProxy

@Suite(.serialized)
struct WebSocketIntegrationTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func capturesUpgradeFramesAndCloseThroughDirectAndCONNECT(mode: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let secure = mode == 2 || mode == 3, tunnel = (1...4).contains(mode)
        let authority = try WSTestAuthority()
        let proxy = LocalProxyServer(certificateProvider: WSTestProvider(authority: authority), upstreamTrustRoots: [try authority.trustRoot()])
        let identity = try authority.identity(for: "127.0.0.1")
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificateDER), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM), format: .pem)
        let serverTLS = try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(key)))
        var clientConfiguration = TLSConfiguration.makeClientConfiguration()
        clientConfiguration.trustRoots = .certificates([try authority.trustRoot()])
        let clientTLS = try NIOSSLContext(configuration: clientConfiguration)
        var upstream: LocalProxyServer?
        let originChannels = OSAllocatedUnfairLock(initialState: [Channel]())
        let extensions = OSAllocatedUnfairLock(initialState: [String]())
        let origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            originChannels.withLock { $0.append(channel) }
            let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: Int(UInt32.max), shouldUpgrade: { _, request in
                extensions.withLock { $0 = request.headers["sec-websocket-extensions"] }
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders([("Sec-WebSocket-Protocol", "chat")]))
            }, upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(WSEcho()).map {
                    // Head and first frame may reach the proxy in one socket read.
                    channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: channel.allocator.buffer(string: "welcome")), promise: nil)
                }
            })
            return channel.eventLoop.makeCompletedFuture {
                if secure { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverTLS)) }
            }.flatMap {
                channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        var clients: [Channel] = []
        do {
            let targetPort = try #require(origin.localAddress?.port)
            let reservation = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
            var configuration = ExplicitProxyConfiguration(); configuration.port = try #require(reservation.localAddress?.port)
            try await reservation.close().get()
            if mode == 3 || mode == 4 {
                let next = LocalProxyServer(); upstream = next
                let socket = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
                var options = ExplicitProxyConfiguration(); options.port = try #require(socket.localAddress?.port)
                try await socket.close().get()
                let port = try await next.start(configuration: options, document: .init())
                configuration.upstream = .httpProxy(.init(host: "127.0.0.1", port: port))
            }
            let port = try await proxy.start(configuration: configuration, document: .init())
            let received = OSAllocatedUnfairLock(initialState: Data())
            let client = try await ClientBootstrap(group: group).channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if secure {
                        try channel.pipeline.syncOperations.addHandler(WSTLSGate(authority: "127.0.0.1:\(targetPort)"))
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: clientTLS, serverHostname: nil))
                    }
                    try channel.pipeline.syncOperations.addHandler(WSRawCollector(bytes: received))
                }
            }.connect(host: "127.0.0.1", port: port).get()
            clients.append(client)
            let authority = "127.0.0.1:\(targetPort)"
            let uri = tunnel ? "/socket" : "http://\(authority)/socket"
            let upgrade = "GET \(uri) HTTP/1.1\r\nHost: \(authority)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: chat\r\nSec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n\r\n"
            let prefix = tunnel && !secure ? "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n" : ""
            // CONNECT and plaintext Upgrade in the same write exercise prefix preservation.
            try await client.writeAndFlush(client.allocator.buffer(string: prefix + upgrade)).get()
            try await eventually("welcome") { received.withLock { String(decoding: $0, as: UTF8.self).contains("welcome") } }
            #expect(extensions.withLock { $0.isEmpty })
            #expect(received.withLock { String(decoding: $0, as: UTF8.self).contains("101 Switching Protocols") })
            if mode >= 5 {
                received.withLock { $0 = Data() }
                switch mode {
                case 5:
                    try await client.writeAndFlush(client.allocator.buffer(bytes: maskedFrame(opcode: 1, bytes: [255]))).get()
                case 6: try await client.close().get()
                default: await proxy.stop()
                }
                var terminal: CaptureRecord?
                try await eventually("terminal state") {
                    if let value = proxy.records.drain().records.last { terminal = value }
                    return terminal.map { !$0.connectionState.isActive } ?? false
                }
                if mode == 5 {
                    #expect(terminal?.connectionState == .failed && terminal?.closeReason?.hasPrefix("1007") == true)
                    #expect(received.withLock { $0.starts(with: [0x88, 2, 3, 239]) })
                } else if mode == 6 {
                    #expect(terminal?.connectionState == .failed && terminal?.error?.contains("1006") == true)
                } else {
                    #expect(terminal?.connectionState == .closed && terminal?.error == nil)
                    #expect(terminal?.closeReason == "捕获已停止")
                }
            } else {
            // Fragmented UTF-8 message, with an interleaved ping; forwarding must retain frame ordering.
            let chinese = Array("你好".utf8)
            try await client.writeAndFlush(client.allocator.buffer(bytes: maskedFrame(opcode: 1, fin: false, bytes: Array(chinese.prefix(2))))).get()
            try await client.writeAndFlush(client.allocator.buffer(bytes: maskedFrame(opcode: 9, bytes: [65]))).get()
            try await client.writeAndFlush(client.allocator.buffer(bytes: maskedFrame(opcode: 0, bytes: Array(chinese.dropFirst(2))))).get()
            try await client.writeAndFlush(client.allocator.buffer(bytes: maskedFrame(opcode: 2, bytes: [0, 255, 128]))).get()
            try await client.writeAndFlush(client.allocator.buffer(bytes: maskedFrame(opcode: 1, bytes: Array(repeating: 120, count: 20_000)))).get()
            var active: CaptureRecord?
            try await eventually("messages or close") {
                if let value = proxy.records.drain().records.last { active = value }
                return (active?.stream?.summary.count ?? 0) >= 9
            }
            let stream = try #require(active?.stream)
            let messages = try await stream.read(from: 0)
            #expect(messages.contains { $0.kind == "文本" && $0.direction == .sent && $0.text == "你好" })
            #expect(messages.contains { $0.kind == "文本" && $0.direction == .received && $0.text == "你好" })
            #expect(messages.contains { $0.kind == "二进制" && $0.data == Data([0, 255, 128]) })
            #expect(messages.contains { $0.kind == "Pong" })
            #expect(messages.contains { $0.data.count == 20_000 })
            try await client.writeAndFlush(client.allocator.buffer(bytes: maskedFrame(opcode: 8, bytes: [3, 232]))).get()
            try await eventually("messages or close") {
                if let value = proxy.records.drain().records.last { active = value }
                return active?.connectionState == .closed
            }
            #expect(active?.error == nil && active?.closeReason?.contains("1000") == true)
            }
        } catch {
            print("WS failure", mode, proxy.records.drain().records.map { ($0.url, $0.status, $0.error) })
            for client in clients { try? await client.close().get() }
            await proxy.stop(); await upstream?.stop()
            for channel in originChannels.withLock({ $0 }) { try? await channel.close().get() }
            try? await origin.close().get(); try? await group.shutdownGracefully()
            throw error
        }
        for client in clients { try? await client.close().get() }
        await proxy.stop(); await upstream?.stop()
        for channel in originChannels.withLock({ $0 }) { try? await channel.close().get() }
        try? await origin.close().get(); try? await group.shutdownGracefully()
    }
}

private func eventually(_ stage: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WorkflowError.invalid("等待 WebSocket 测试条件超时：\(stage)") }
        try await Task.sleep(for: .milliseconds(20))
    }
}
private func maskedFrame(opcode: UInt8, fin: Bool = true, bytes: [UInt8]) -> [UInt8] {
    var frame: [UInt8] = [(fin ? 0x80 : 0) | opcode]
    if bytes.count < 126 { frame.append(0x80 | UInt8(bytes.count)) }
    else { frame += [0xfe, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] }
    let mask: [UInt8] = [1, 2, 3, 4]
    frame += mask
    frame += bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    return frame
}
private final class WSRawCollector: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let bytes: OSAllocatedUnfairLock<Data>
    init(bytes: OSAllocatedUnfairLock<Data>) { self.bytes = bytes }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { let buffer = unwrapInboundIn(data); bytes.withLock { $0.append(contentsOf: buffer.readableBytesView) } }
}
private final class WSEcho: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        let reply = WebSocketFrame(fin: frame.fin, opcode: frame.opcode == .ping ? .pong : frame.opcode, data: frame.unmaskedData)
        context.writeAndFlush(NIOAny(reply), promise: nil)
    }
}

private struct WSTestAuthority: Sendable {
    let privateKey: Certificate.PrivateKey
    let root: Certificate

    init() throws {
        privateKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        root = try CertificateMaterial.root(privateKey: privateKey, now: Date())
    }

    func trustRoot() throws -> NIOSSLCertificate {
        try NIOSSLCertificate(bytes: Array(CertificateMaterial.data(root)), format: .der)
    }

    func identity(for host: String) throws -> TLSCertificateIdentity {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        let names: SubjectAlternativeNames = octets.count == 4
            ? SubjectAlternativeNames([.ipAddress(.init(contentBytes: ArraySlice(octets)))])
            : SubjectAlternativeNames([.dnsName(host)])
        let leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: Certificate.PrivateKey(key).publicKey,
            notValidBefore: now.addingTimeInterval(-60), notValidAfter: now.addingTimeInterval(3600),
            issuer: root.subject, subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                names
                AuthorityKeyIdentifier(keyIdentifier: SubjectKeyIdentifier(hash: root.publicKey).keyIdentifier)
            }, issuerPrivateKey: privateKey
        )
        return TLSCertificateIdentity(certificateDER: try CertificateMaterial.data(leaf),
                                      privateKeyPEM: Data(key.pemRepresentation.utf8))
    }
}

private struct WSTestProvider: TLSCertificateProviding {
    let authority: WSTestAuthority
    func serverIdentity(for host: String) async throws -> TLSCertificateIdentity? { try authority.identity(for: host) }
}

private final class WSTLSGate: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    private let authority: String
    private var sent = false
    private var ready = false
    private var response = Data()
    init(authority: String) { self.authority = authority }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if sent { context.write(data, promise: promise); return }
        sent = true
        var bytes = context.channel.allocator.buffer(string: "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n")
        var hello = unwrapOutboundIn(data); bytes.writeBuffer(&hello)
        context.write(NIOAny(bytes), promise: promise)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if ready { context.fireChannelRead(data); return }
        response.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        guard let end = response.range(of: Data("\r\n\r\n".utf8)) else { return }
        guard String(decoding: response.prefix(end.upperBound), as: UTF8.self).hasPrefix("HTTP/1.1 200") else { context.close(promise: nil); return }
        ready = true
        let leftover = response.suffix(from: end.upperBound)
        if !leftover.isEmpty { context.fireChannelRead(NIOAny(context.channel.allocator.buffer(bytes: leftover))) }
        response = Data()
    }
}
