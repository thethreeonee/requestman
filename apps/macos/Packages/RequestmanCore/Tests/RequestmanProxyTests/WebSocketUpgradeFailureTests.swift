import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
import RequestmanCore
@testable import RequestmanProxy

struct WebSocketUpgradeFailureTests {
    @Test func pipelineFailureHasOneTerminalRecordOwner() async throws {
        let shared = ProxySharedState()
        let records = CaptureRecordBuffer()
        let connection = ProxyConnection(configuration: .init(), shared: shared, records: records)
        let loop = EmbeddedEventLoop()
        let client = EmbeddedChannel(loop: loop)
        let upstream = EmbeddedChannel(loop: loop)
        defer {
            _ = try? client.finish(acceptAlreadyClosed: true)
            _ = try? upstream.finish(acceptAlreadyClosed: true)
        }
        try client.pipeline.syncOperations.addHandlers([HTTPResponseEncoder(), connection])
        try await client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).get()
        try await upstream.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12346)).get()
        connection.upstream = upstream
        connection.webSocketRequest = true
        var record = CaptureRecord(method: "GET", url: "http://example.test/socket")
        record.sentHeaders = [HTTPField("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")]
        connection.record = record
        // No ProxyResponseHandler on the upstream: deterministic failure while replacing HTTP handlers.
        let head = HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: HTTPHeaders([
            ("Connection", "Upgrade"), ("Upgrade", "websocket"),
            ("Sec-WebSocket-Accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        ]))
        try connection.upgradeWebSocket(head)
        loop.run()
        let events = shared.events.drain().events
        #expect(events.map(\.kind) == [.failed])
        #expect(events.first?.transactionID == record.id)
        var captured = records.drain().records.first
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while captured == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            captured = records.drain().records.first
        }
        let final = try #require(captured)
        #expect(final.connectionState == .failed)
        #expect(final.captureProtocol == .webSocket)
        #expect(connection.finished)
    }
}
