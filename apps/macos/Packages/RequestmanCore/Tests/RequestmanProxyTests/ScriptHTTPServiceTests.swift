import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing
import os
import RequestmanCore
@testable import RequestmanProxy

/// Real TCP/TLS, private in-memory trust anchors, and no system proxy/certificate changes.
@Suite(.serialized)
struct ScriptHTTPServiceTests {
    @Test func clientFromPreviousCaptureSessionCannotResumeAfterRestart() async throws {
        try await withScriptHTTPFixture { fixture in
            let stale = fixture.service()
            #expect(fixture.shared.beginShutdown().isEmpty)
            fixture.shared.prepareForStart()
            await #expect(throws: CancellationError.self) {
                try await stale.send(.init(url: fixture.url("/echo")),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
            }
            #expect(fixture.requests.withLock { $0.isEmpty })
            let fresh = try await fixture.service().send(.init(url: fixture.url("/echo")),
                context: .init(executionID: UUID(), callID: UUID()), control: .init())
            #expect(fresh.status == 418)
            _ = try await fresh.readBody()
        }
    }

    @Test func headersPrecedeEOFAndBodyPreservesBinaryBytes() async throws {
        try await withScriptHTTPFixture { fixture in
            let context = ScriptHTTPContext(executionID: UUID(), callID: UUID(), parentTransactionID: UUID(), stepID: UUID())
            let response = try await fixture.service().send(.init(url: fixture.url("/pending")), context: context, control: .init())
            #expect(response.status == 200)
            #expect(fixture.pending.withLock { !$0.isEmpty })
            let completed = OSAllocatedUnfairLock(initialState: false)
            let reading = Task { let data = try await response.readBody(); completed.withLock { $0 = true }; return data }
            try await Task.sleep(for: .milliseconds(30))
            #expect(!completed.withLock { $0 })
            fixture.endPending()
            #expect(try await reading.value == Data([0, 255, 1, 254]))
            let record = try #require(await fixture.terminal(context.callID))
            #expect(record.auxiliaryParentID == context.parentTransactionID && record.auxiliaryStepID == context.stepID)
            #expect(record.auxiliaryCallID == context.callID && record.auxiliaryExecutionID == context.executionID)
            #expect(record.receivedBody.state == .complete && record.receivedBody.data == Data([0, 255, 1, 254]))
            #expect(record.matchedRules.isEmpty && record.executionTrace.isEmpty)
            #expect(fixture.shared.ruleHitNotifications.drain().isEmpty)
        }
    }

    @Test func httpFailuresRemainResponsesAndRequestBodiesAreRecorded() async throws {
        try await withScriptHTTPFixture { fixture in
            let context = ScriptHTTPContext(executionID: UUID(), callID: UUID())
            let response = try await fixture.service().send(.init(url: fixture.url("/echo"), method: "POST",
                headers: [.init("X-Duplicate", "one"), .init("X-Duplicate", "two")], body: Data("payload".utf8)),
                context: context, control: .init())
            #expect(response.status == 418)
            #expect(try await response.readBody() == Data("payload".utf8))
            let request = try #require(fixture.requests.withLock { $0.last })
            #expect(request.head.headers["x-duplicate"] == ["one", "two"])
            let record = try #require(await fixture.terminal(context.callID))
            #expect(record.requestBody.data == Data("payload".utf8) && record.sentBody.isComplete)
            #expect(record.outcome == .forwarded && record.error == nil)
        }
    }

    @Test func configuredHTTPUpstreamUsesAbsoluteURIAndFrozenRoute() async throws {
        try await withScriptHTTPFixture { fixture in
            var configuration = ExplicitProxyConfiguration()
            configuration.upstream = .httpProxy(.init(host: "127.0.0.1", port: fixture.port))
            let service = fixture.service(configuration: configuration)
            fixture.shared.configuration.withLock { $0.upstream = .httpProxy(.init(host: "127.0.0.1", port: 1)) }
            let response = try await service.send(.init(url: "http://unresolvable.example.invalid/echo", method: "POST", body: Data("through-proxy".utf8)),
                context: .init(executionID: UUID(), callID: UUID()), control: .init())
            #expect(try await response.readBody() == Data("through-proxy".utf8))
            #expect(fixture.requests.withLock { $0.last?.head.uri } == "http://unresolvable.example.invalid/echo")
        }
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func redirectsApplyMethodBodyAndOriginRules(status: Int) async throws {
        try await withScriptHTTPFixture { fixture in
            let response = try await fixture.service().send(.init(url: fixture.url("/redirect/\(status)"), method: "POST",
                headers: [.init("Authorization", "Bearer token"), .init("Cookie", "session=value"), .init("Content-Type", "text/plain")], body: Data("keep-body".utf8)),
                context: .init(executionID: UUID(), callID: UUID()), control: .init())
            let keep = status == 307 || status == 308
            #expect(response.redirected && response.url == "http://localhost:\(fixture.port)/echo")
            #expect(try await response.readBody() == (keep ? Data("keep-body".utf8) : Data()))
            let request = try #require(fixture.requests.withLock { $0.last })
            #expect(request.head.method == (keep ? .POST : .GET))
            #expect(request.head.headers["authorization"].isEmpty && request.head.headers["cookie"].isEmpty)
            #expect(keep || request.head.headers["content-type"].isEmpty)
        }
    }

    @Test func manualAndErrorRedirectModesAndRedirectLoop() async throws {
        try await withScriptHTTPFixture { fixture in
            let service = fixture.service()
            let manual = try await service.send(.init(url: fixture.url("/redirect/302"), redirect: .manual),
                context: .init(executionID: UUID(), callID: UUID()), control: .init())
            #expect(manual.status == 302 && !manual.redirected)
            #expect(try await manual.readBody().isEmpty)
            await #expect(throws: (any Error).self) {
                _ = try await service.send(.init(url: fixture.url("/redirect/302"), redirect: .error),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
            }
            await #expect(throws: (any Error).self) {
                _ = try await service.send(.init(url: fixture.url("/redirect-without-location"), redirect: .error),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
            }
            await #expect(throws: (any Error).self) {
                _ = try await service.send(.init(url: fixture.url("/loop")),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
            }
            #expect(fixture.requests.withLock { $0.filter { $0.head.uri == "/loop" }.count } == 21)
        }
    }

    @Test(arguments: ["gzip", "deflate"])
    func decodeBodyKeepsRawCapture(encoding: String) async throws {
        try await withScriptHTTPFixture { fixture in
            let id = UUID()
            let response = try await fixture.service().send(.init(url: fixture.url("/encoded/\(encoding)")),
                context: .init(executionID: UUID(), callID: id), control: .init())
            #expect(try await response.readBody() == Data("decoded-body".utf8))
            let record = try #require(await fixture.terminal(id))
            #expect(record.receivedBody.contentEncoding == encoding)
            #expect(record.receivedBody.data == (encoding == "gzip" ? ScriptHTTPFixture.gzip : ScriptHTTPFixture.deflate))
        }
    }

    @Test func unknownOrDamagedEncodingRejectsBodyRead() async throws {
        try await withScriptHTTPFixture { fixture in
            for path in ["/encoded/unknown", "/encoded/damaged"] {
                let response = try await fixture.service().send(.init(url: fixture.url(path)),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
                #expect(response.status == 200)
                await #expect(throws: (any Error).self) { _ = try await response.readBody() }
            }
        }
    }

    @Test func headAndNullBodyStatusesIgnoreContentEncodingAndGzipMembersDecode() async throws {
        try await withScriptHTTPFixture { fixture in
            for request in [ScriptHTTPRequest(url: fixture.url("/encoded/gzip"), method: "HEAD")]
                + [204, 205, 304].map({ ScriptHTTPRequest(url: fixture.url("/null/\($0)")) }) {
                let response = try await fixture.service().send(request,
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
                #expect(try await response.readBody().isEmpty)
            }
            let response = try await fixture.service().send(.init(url: fixture.url("/encoded/multiple")),
                context: .init(executionID: UUID(), callID: UUID()), control: .init())
            #expect(try await response.readBody() == Data("decoded-bodydecoded-body".utf8))
        }
    }

    @Test(arguments: [false, true])
    func cancellationClosesTransportAndRecordsPartialBody(clear: Bool) async throws {
        try await withScriptHTTPFixture { fixture in
            let id = UUID(), control = ScriptExecutionControl()
            let response = try await fixture.service().send(.init(url: fixture.url("/pending")),
                context: .init(executionID: UUID(), callID: id), control: control)
            try await Task.sleep(for: .milliseconds(30))
            if clear { fixture.records.clear() }
            control.cancel()
            await #expect(throws: (any Error).self) { _ = try await response.readBody() }
            if clear {
                try await Task.sleep(for: .milliseconds(30))
                #expect(fixture.records.drain().records.isEmpty)
            } else {
                let record = try #require(await fixture.terminal(id))
                #expect(record.connectionState == .closed && record.error == nil)
                #expect(record.receivedBody.state == .incomplete && record.receivedBody.data == Data([0, 255]))
            }
        }
    }

    @Test func perCallAbortStillRejectsBodyAfterEOF() async throws {
        try await withScriptHTTPFixture { fixture in
            let id = UUID(), control = ScriptExecutionControl()
            let response = try await fixture.service().send(.init(url: fixture.url("/encoded/gzip")),
                context: .init(executionID: UUID(), callID: id), control: control)
            let record = try #require(await fixture.terminal(id))
            #expect(record.receivedBody.isComplete)
            response.cancel()
            await #expect(throws: (any Error).self) { _ = try await response.readBody() }
            #expect(!control.isCancelled)
        }
    }

    @Test func captureShutdownCancelsPendingHead() async throws {
        try await withScriptHTTPFixture { fixture in
            let id = UUID()
            let sending = Task { try await fixture.service().send(.init(url: fixture.url("/no-head")),
                context: .init(executionID: UUID(), callID: id), control: .init()) }
            try await fixture.waitForRequests(1)
            for channel in fixture.shared.beginShutdown() { try? await channel.close().get() }
            await #expect(throws: (any Error).self) { _ = try await sending.value }
            let record = try #require(await fixture.terminal(id))
            #expect(record.connectionState == .closed && record.receivedBody.state == .incomplete)
        }
    }

    @Test func admissionWaitCanCancelAndQueueOverflowIsExplicit() async throws {
        try await withScriptHTTPFixture { fixture in
            let admission = ScriptHTTPAdmission(maximumActive: 1, maximumWaiting: 1)
            let service = fixture.service(admission: admission)
            let first = try await service.send(.init(url: fixture.url("/pending")),
                context: .init(executionID: UUID(), callID: UUID()), control: .init())
            let control = ScriptExecutionControl()
            let second = Task { try await service.send(.init(url: fixture.url("/echo")),
                context: .init(executionID: UUID(), callID: UUID()), control: control) }
            for _ in 0..<100 {
                if await admission.queuedCount == 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            await #expect(throws: (any Error).self) {
                _ = try await service.send(.init(url: fixture.url("/echo")),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
            }
            control.cancel()
            await #expect(throws: (any Error).self) { _ = try await second.value }
            first.cancel()
            let next = try await service.send(.init(url: fixture.url("/echo")),
                context: .init(executionID: UUID(), callID: UUID()), control: .init())
            #expect(next.status == 418)
            #expect(try await next.readBody().isEmpty)
        }
    }

    @Test func proxyLoopRejectedBeforeSendingAndAfterDNSResolution() async throws {
        try await withScriptHTTPFixture { fixture in
            var configuration = ExplicitProxyConfiguration(); configuration.port = fixture.port
            let service = fixture.service(configuration: configuration)
            await #expect(throws: (any Error).self) {
                _ = try await service.send(.init(url: fixture.url("/echo")),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
            }
            // A non-local hostname reaches the fake HTTP proxy; its resolved loopback socket is checked as well.
            configuration.upstream = .httpProxy(.init(host: "localhost.", port: fixture.port))
            await #expect(throws: (any Error).self) {
                _ = try await fixture.service(configuration: configuration).send(.init(url: "http://example.invalid/echo"),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
            }
            #expect(fixture.requests.withLock { $0.isEmpty })
        }
    }

    @Test(arguments: [false, true])
    func httpsUsesTargetTrustAndWorksThroughCONNECT(upstream: Bool) async throws {
        try await withScriptHTTPFixture(secure: true) { fixture in
            var configuration = ExplicitProxyConfiguration()
            if upstream { configuration.upstream = .httpProxy(.init(host: "127.0.0.1", port: try await fixture.startUpstream())) }
            let response = try await fixture.service(configuration: configuration).send(.init(url: fixture.url("/echo"), method: "POST", body: Data("secure".utf8)),
                context: .init(executionID: UUID(), callID: UUID()), control: .init())
            #expect(try await response.readBody() == Data("secure".utf8))
        }
    }

    @Test(arguments: ["wrong-host", "untrusted"])
    func httpsRejectsHostnameAndTrustFailures(kind: String) async throws {
        try await withScriptHTTPFixture(secure: true, certificateHost: kind == "wrong-host" ? "other.invalid" : "localhost", trust: kind != "untrusted") { fixture in
            await #expect(throws: (any Error).self) {
                _ = try await fixture.service().send(.init(url: fixture.url("/echo")),
                    context: .init(executionID: UUID(), callID: UUID()), control: .init())
            }
            #expect(fixture.requests.withLock { $0.isEmpty })
        }
    }
}

private struct ScriptHTTPObservedRequest: Sendable { let head: HTTPRequestHead; let body: Data }

private final class ScriptHTTPFixture: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let records = CaptureRecordBuffer()
    let shared: ProxySharedState
    let secure: Bool
    let authority: EphemeralTLSAuthority
    let certificateHost: String
    let requests = OSAllocatedUnfairLock(initialState: [ScriptHTTPObservedRequest]())
    let pending = OSAllocatedUnfairLock(initialState: [Channel]())
    private let children = OSAllocatedUnfairLock(initialState: [Channel]())
    private var origin: Channel?
    private var upstream: LocalProxyServer?
    var port = 0
    static let gzip = Data(base64Encoded: "H4sIAAAAAAAAE0tJTc5PSU3RTcpPqQQAMOX/FQwAAAA=")!
    static let deflate = Data(base64Encoded: "eJxLSU3OT0lN0U3KT6kEAB4KBKQ=")!
    init(secure: Bool, certificateHost: String, trust: Bool) throws {
        self.secure = secure; self.certificateHost = certificateHost
        authority = try EphemeralTLSAuthority()
        shared = ProxySharedState(upstreamTrustRoots: secure ? [try (trust ? authority : EphemeralTLSAuthority()).trustRoot()] : nil)
    }
    func prepare() async throws {
        let context: NIOSSLContext?
        if secure { context = try ProxyTLS.serverContext(authority.identity(for: certificateHost), protocols: ["http/1.1"]) }
        else { context = nil }
        let children = children
        origin = try await ServerBootstrap(group: group).childChannelInitializer { [self] channel in
            children.withLock { $0.append(channel) }
            return channel.eventLoop.makeCompletedFuture {
                if let context { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context)) }
                try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                try channel.pipeline.syncOperations.addHandler(ScriptHTTPOrigin(fixture: self))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        port = try #require(origin?.localAddress?.port)
    }
    func url(_ path: String) -> String { "\(secure ? "https://localhost" : "http://127.0.0.1"):\(port)\(path)" }
    func service(configuration: ExplicitProxyConfiguration = .init(), admission: ScriptHTTPAdmission = .shared) -> ScriptHTTPService {
        ScriptHTTPService(configuration: configuration, shared: shared, records: records, eventLoop: group.next(), admission: admission)
    }
    func startUpstream() async throws -> Int {
        let proxy = LocalProxyServer(); upstream = proxy
        var configuration = ExplicitProxyConfiguration()
        for attempt in 0..<5 {
            let reservation = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
            configuration.port = try #require(reservation.localAddress?.port)
            try await reservation.close().get()
            do { return try await proxy.start(configuration: configuration, document: .init()) }
            catch { if attempt == 4 { throw error } }
        }
        throw WorkflowError.invalid("无法启动测试上游")
    }
    func endPending() {
        let channels = pending.withLock { value in let channels = value; value.removeAll(); return channels }
        for channel in channels {
            channel.eventLoop.execute {
                channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: [1, 254]))), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if requests.withLock({ $0.count >= count }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WorkflowError.invalid("测试服务器没有收到请求")
    }
    func terminal(_ id: UUID) async throws -> CaptureRecord? {
        for _ in 0..<200 {
            if let record = records.drain().records.last(where: { $0.id == id && !$0.connectionState.isActive }) { return record }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
    func shutdown() async {
        for channel in shared.beginShutdown() + children.withLock({ $0 }) { try? await channel.close().get() }
        await upstream?.stop()
        try? await origin?.close().get()
        try? await group.shutdownGracefully()
    }
}

private func withScriptHTTPFixture(secure: Bool = false, certificateHost: String = "localhost", trust: Bool = true,
                                  _ body: (ScriptHTTPFixture) async throws -> Void) async throws {
    let fixture = try ScriptHTTPFixture(secure: secure, certificateHost: certificateHost, trust: trust)
    do { try await fixture.prepare(); try await body(fixture); await fixture.shutdown() }
    catch { await fixture.shutdown(); throw error }
}

private final class ScriptHTTPOrigin: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    let fixture: ScriptHTTPFixture
    private var head: HTTPRequestHead?
    private var bytes = Data()
    init(fixture: ScriptHTTPFixture) { self.fixture = fixture }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body(let body): bytes.append(contentsOf: body.readableBytesView)
        case .end:
            guard let head else { return }
            fixture.requests.withLock { $0.append(.init(head: head, body: bytes)) }
            let path = head.uri.hasPrefix("http") ? URLComponents(string: head.uri)?.path ?? "" : head.uri
            let channel = context.channel
            if path == "/no-head" { return }
            if path == "/pending" {
                fixture.pending.withLock { $0.append(channel) }
                channel.write(HTTPServerResponsePart.head(HTTPRequestHead.fixtureResponse(status: .ok, headers: [("Transfer-Encoding", "chunked")])), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: [0, 255]))), promise: nil)
                return
            }
            var status: HTTPResponseStatus = .imATeapot
            var headers: [(String, String)] = []
            var body = bytes
            if path.hasPrefix("/redirect/"), let code = Int(path.split(separator: "/").last ?? "") {
                status = .init(statusCode: code); body = Data()
                headers.append(("Location", "http://localhost:\(fixture.port)/echo"))
            } else if path == "/redirect-without-location" {
                status = .found; body = Data()
            } else if path == "/loop" {
                status = .found; body = Data(); headers.append(("Location", "/loop"))
            } else if path.hasPrefix("/null/"), let code = Int(path.split(separator: "/").last ?? "") {
                status = .init(statusCode: code); body = Data(); headers.append(("Content-Encoding", "gzip"))
            } else if path.hasPrefix("/encoded/") {
                status = .ok
                let encoding = String(path.split(separator: "/").last ?? "")
                headers.append(("Content-Encoding", ["damaged", "multiple"].contains(encoding) ? "gzip" : encoding == "unknown" ? "br" : encoding))
                body = encoding == "gzip" ? ScriptHTTPFixture.gzip : encoding == "deflate" ? ScriptHTTPFixture.deflate
                    : encoding == "multiple" ? ScriptHTTPFixture.gzip + ScriptHTTPFixture.gzip : Data("invalid".utf8)
            }
            headers.append(("Content-Length", String(body.count)))
            channel.write(HTTPServerResponsePart.head(HTTPRequestHead.fixtureResponse(status: status, headers: headers)), promise: nil)
            if head.method != .HEAD { channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: body))), promise: nil) }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

private extension HTTPRequestHead {
    static func fixtureResponse(status: HTTPResponseStatus, headers: [(String, String)]) -> HTTPResponseHead {
        HTTPResponseHead(version: .http1_1, status: status, headers: HTTPHeaders(headers))
    }
}
