import NIOCore
import Testing
@testable import RequestmanProxy

struct ClientHelloALPNTests {
    @Test(arguments: [["h2", "http/1.1"], ["http/1.1"], ["h2"], [], ["unknown", "h2"]])
    func readsFragmentedHello(protocols: [String]) throws {
        let hello = clientHello(protocols: protocols)
        // Split the handshake itself across TLS records, then feed one TCP byte at a time.
        for split in 1..<hello.count {
            let wire = record(Array(hello[..<split])) + record(Array(hello[split...]))
            var parser = ClientHelloALPNParser()
            for (index, byte) in wire.enumerated() {
                let parsed = try parser.append(ByteBuffer(bytes: [byte]))
                if index < wire.count - 1 { #expect(parsed == nil) }
                else { #expect(parsed == protocols.filter { ["h2", "http/1.1"].contains($0) }) }
            }
        }
    }

    @Test func rejectsMalformedALPNAndRecordLengths() {
        var parser = ClientHelloALPNParser()
        #expect(throws: (any Error).self) { try parser.append(ByteBuffer(bytes: record(clientHello(protocols: [""])))) }
        parser = ClientHelloALPNParser()
        #expect(throws: (any Error).self) { try parser.append(ByteBuffer(bytes: [22, 3, 3, 0xff, 0xff])) }
        parser = ClientHelloALPNParser()
        #expect(throws: (any Error).self) { try parser.append(ByteBuffer(bytes: record([1, 0xff, 0xff, 0xff]))) }
        var broken = clientHello(protocols: ["h2", "http/1.1"])
        broken.removeLast() // The handshake length is adjusted but nested ALPN lengths are now invalid.
        broken[3] -= 1
        parser = ClientHelloALPNParser()
        #expect(throws: (any Error).self) { try parser.append(ByteBuffer(bytes: record(broken))) }
    }

    @Test func serverContextCacheIncludesSelectedProtocol() throws {
        let identity = try EphemeralTLSAuthority().identity(for: "localhost")
        let contexts = ProxyTLSContexts()
        let h2 = try contexts.server(identity, protocols: ["h2"])
        let h1 = try contexts.server(identity, protocols: ["http/1.1"])
        #expect(h2.configuration.applicationProtocols == ["h2"])
        #expect(h1.configuration.applicationProtocols == ["http/1.1"])
        #expect(h2 !== h1)
        #expect(try contexts.server(identity, protocols: ["h2"]) === h2)
    }

    private func vector(_ value: [UInt8], wide: Bool = true) -> [UInt8] {
        (wide ? [UInt8(value.count >> 8), UInt8(value.count & 255)] : [UInt8(value.count)]) + value
    }
    private func clientHello(protocols: [String]) -> [UInt8] {
        let alpn = protocols.isEmpty ? [] : [UInt8(0), 16] + vector(vector(protocols.flatMap { vector(Array($0.utf8), wide: false) }))
        let body = [UInt8(3), 3] + Array(repeating: UInt8(0), count: 32) + [0, 0, 2, 0x13, 1, 1, 0] + vector(alpn)
        return [1, 0] + vector(body)
    }
    private func record(_ bytes: [UInt8]) -> [UInt8] { [22, 3, 3] + vector(bytes) }
}
