import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOHTTP1
import Testing
import os
import RequestmanCore
@testable import RequestmanProxy

@Suite(.serialized)
struct ProxyIntegrationTests {
    @Test func upstreamChangesApplyWithoutRestartingListener() async throws {
        try await withHarness { h in
            try await h.start()
            var configuration = ExplicitProxyConfiguration()
            configuration.port = h.proxyPort
            configuration.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: h.originPort))
            try await h.proxy.updateConfiguration(configuration)
            let proxied = try await h.exchange("GET http://unresolved.test/live HTTP/1.1\r\nHost: unresolved.test\r\n\r\n")
            #expect(proxied.contains("origin-body"))
            #expect(h.observation.withLock { $0.uri } == "http://unresolved.test/live")

            configuration.upstream = .system
            try await h.proxy.updateConfiguration(configuration)
            let direct = try await h.exchange("GET \(h.originURL)direct HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(direct.contains("origin-body"))
            #expect(h.observation.withLock { $0.uri } == "/direct")

            configuration.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: h.proxyPort))
            await #expect(throws: WorkflowError.self) { try await h.proxy.updateConfiguration(configuration) }
            let afterFailure = try await h.exchange("GET \(h.originURL)still-direct HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(afterFailure.contains("origin-body"))
            #expect(h.observation.withLock { $0.uri } == "/still-direct")
        }
    }
    @Test func modifiesRealRequestAndResponseWithoutBufferingBody() async throws {
        try await withHarness { h in
            var env = WorkspaceEnvironment(name: "dev"); env.variables = [NamedValue(name: "key", value: "test-key")]
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var reqHeader = ModificationStep(kind: .setHeader); reqHeader.name = "X-Key"; reqHeader.value = "{{env.key}}"
            var respHeader = ModificationStep(kind: .setHeader); respHeader.name = "X-Debug"; respHeader.value = "true"
            var status = ModificationStep(kind: .setStatus); status.status = 202
            workflow.requestSteps = [reqHeader]; workflow.responseSteps = [respHeader, status]
            try await h.start(workflow: workflow, environment: env)
            let body = String(repeating: "stream-data-", count: 12_000)
            let reply = try await h.exchange("POST \(h.originURL)echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
            #expect(reply.contains("202 Accepted")); #expect(reply.lowercased().contains("x-debug: true"))
            #expect(h.observation.withLock { $0.header } == "test-key")
            #expect(h.observation.withLock { $0.bodyBytes } == body.utf8.count)
            #expect(reply.contains("origin-body"))
            let records = h.proxy.records.drain().records
            #expect(records.count == 1); #expect(records.first?.outcome == .modified)
            #expect(records.first?.requestBytes == body.utf8.count)
            let record = try #require(records.first)
            #expect(record.requestBody.state == .complete && record.requestBody.isTruncated)
            #expect(record.requestBody.data.count == CaptureBodySnapshot.maximumBytes)
            #expect(record.requestBody.observedByteCount == body.utf8.count)
            #expect(record.sentBody.data == record.requestBody.data)
            #expect(record.sentBody.state == .complete && record.sentBody.isTruncated)
            #expect(record.receivedBody.data == Data("origin-body".utf8))
            #expect(record.responseBody.data == record.receivedBody.data)
            #expect(record.originalStatus == 200 && record.status == 202)
            #expect(record.matchedWorkflowID == workflow.id)
        }
    }
    @Test func mockSkipsOriginAndResponseLaneStillRuns() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var mock = ModificationStep(kind: .mock); mock.value = "local-static"; mock.status = 201
            var header = ModificationStep(kind: .setHeader); header.name = "X-Response-Flow"; header.value = "yes"
            workflow.requestSteps = [mock]; workflow.responseSteps = [header]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)mock HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("201 Created")); #expect(reply.contains("local-static")); #expect(reply.contains("X-Response-Flow: yes"))
            #expect(h.observation.withLock { $0.requests } == 0)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.outcome == .mocked)
            #expect(record.sentBody.state == .unavailable && record.receivedBody.state == .unavailable)
            #expect(record.responseBody.isComplete && record.responseBody.data == Data("local-static".utf8))
        }
    }
    @Test func responseReplacementRepairsEncodingAndHeadHasNoBody() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var body = ModificationStep(kind: .replaceBody); body.value = "replacement"
            workflow.responseSteps = [body]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("Content-Length: 11")); #expect(reply.hasSuffix("replacement"))
            #expect(!reply.lowercased().contains("content-encoding"))
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.requestBody.isComplete && record.requestBody.data.isEmpty)
            #expect(record.sentBody.isComplete && record.sentBody.data.isEmpty)
            #expect(record.receivedBody.data == Data("origin-body".utf8))
            #expect(record.responseBody.data == Data("replacement".utf8))
            #expect(record.responseBody.isComplete)
            let head = try await h.exchange("HEAD \(h.originURL) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(head.hasSuffix("\r\n\r\n")); #expect(!head.hasSuffix("replacement"))
            let headRecord = try #require(h.proxy.records.drain().records.first)
            #expect(headRecord.receivedBody.isComplete && headRecord.receivedBody.data.isEmpty)
            #expect(headRecord.responseBody.isComplete && headRecord.responseBody.data.isEmpty)
        }
    }
    @Test func invalidDynamicValueFailsBeforeOriginAndStopReleasesPort() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var step = ModificationStep(kind: .setHeader); step.name = "X-Key"; step.value = "{{env.missing}}"
            workflow.requestSteps = [step]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("400 Bad Request")); #expect(h.observation.withLock { $0.requests } == 0)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.outcome == .failed)
            #expect(record.responseBody.isComplete)
            #expect(String(data: record.responseBody.data, encoding: .utf8)?.contains("未找到变量") == true)
            #expect(record.responseHeaders.contains { $0.name.lowercased() == "content-type" && $0.value == "text/plain; charset=utf-8" })
            #expect(record.sentBody.state == .unavailable)
            await h.proxy.stop()
            let rebound = try await ServerBootstrap(group: h.group).serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1).bind(host: "127.0.0.1", port: h.proxyPort).get()
            try await rebound.close().get()
        }
    }
    @Test func connectRelaysOpaqueBytesAndRecordsTunnel() async throws {
        try await withHarness { h in
            let echo = try await ServerBootstrap(group: h.group).childChannelInitializer { channel in
                channel.pipeline.addHandler(EchoHandler())
            }.bind(host: "127.0.0.1", port: 0).get()
            do {
                try await h.start()
                let port = try #require(echo.localAddress?.port)
                let reply = try await h.exchange("CONNECT 127.0.0.1:\(port) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\nopaque-tunnel-bytes", until: "opaque-tunnel-bytes")
                #expect(reply.contains("200 OK")); #expect(!reply.lowercased().contains("transfer-encoding"))
                #expect(reply.hasSuffix("opaque-tunnel-bytes"))
                #expect(h.proxy.records.drain().records.first?.outcome == .tunnel)
                try await echo.close().get()
            } catch { try? await echo.close().get(); throw error }
        }
    }
    @Test func chunkedRequestAndReplacementUseValidFraming() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var replacement = ModificationStep(kind: .replaceBody); replacement.value = "changed"
            workflow.requestSteps = [replacement]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("POST \(h.originURL) HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n")
            #expect(reply.contains("200 OK")); #expect(h.observation.withLock { $0.bodyBytes } == 7)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.requestBody.isComplete && record.requestBody.data == Data("abcdef".utf8))
            #expect(record.sentBody.isComplete && record.sentBody.data == Data("changed".utf8))
            let doc = WorkspaceDocument()
            await h.proxy.update(doc)
            let unchanged = try await h.exchange("POST \(h.originURL) HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
            #expect(unchanged.contains("200 OK")); #expect(h.observation.withLock { $0.bodyBytes } == 10)
        }
    }
    @Test func connectViaExplicitUpstreamRemovesHTTPHandlers() async throws {
        try await withHarness { upstream in
            try await upstream.start()
            try await withHarness { h in
                let echo = try await ServerBootstrap(group: h.group).childChannelInitializer { $0.pipeline.addHandler(EchoHandler()) }
                    .bind(host: "127.0.0.1", port: 0).get()
                do {
                    var configuration = ExplicitProxyConfiguration()
                    configuration.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: upstream.proxyPort))
                    try await h.start(configuration: configuration)
                    let port = try #require(echo.localAddress?.port)
                    let reply = try await h.exchange("CONNECT 127.0.0.1:\(port) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\nthrough-two-proxies", until: "through-two-proxies")
                    #expect(reply.hasSuffix("through-two-proxies"))
                    #expect(h.proxy.records.drain().records.first?.outcome == .tunnel)
                    try await echo.close().get()
                } catch { try? await echo.close().get(); throw error }
            }
        }
    }
    @Test func generatedBodyBudgetIsGlobalAndReleasedWithOwner() throws {
        let state = ProxySharedState()
        var reservations: [GeneratedBodyReservation] = []
        let body = String(repeating: "x", count: 1_048_576)
        for _ in 0..<16 { reservations.append(try state.reserveBody(body)) }
        #expect(throws: WorkflowError.self) { try state.reserveBody("x") }
        reservations.removeAll()
        #expect(state.generatedBodyBytes.withLock { $0 } == 0)
        let lease = try state.reserveBody(body)
        #expect(lease.bytes == 1_048_576)
    }
    @Test func largeResponseStreamsAllBytesAndRedirectDoesNotReflectCredentials() async throws {
        try await withHarness { h in
            try await h.start()
            let reply = try await h.exchange("GET \(h.originURL)large HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.filter { $0 == "z" }.count == 1_048_576)
            #expect(h.proxy.records.drain().records.first?.responseBytes == 1_048_576)
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var redirect = ModificationStep(kind: .redirect); redirect.value = "https://example.test/new"
            workflow.requestSteps = [redirect]
            var project = WorkflowProject(); project.workflows = [workflow]
            var doc = WorkspaceDocument(); doc.projects = [project]
            await h.proxy.update(doc)
            let redirected = try await h.exchange("GET \(h.originURL) HTTP/1.1\r\nHost: localhost\r\nCookie: secret\r\nAuthorization: token\r\n\r\n")
            #expect(redirected.contains("302 Found")); #expect(redirected.contains("Location: https://example.test/new"))
            #expect(!redirected.contains("secret")); #expect(!redirected.contains("token"))
            #expect(h.observation.withLock { $0.requests } == 1)
        }
    }
    @Test func encodedAndInterruptedBodiesAreNeverReportedAsCompleteJSON() async throws {
        try await withHarness { h in
            try await h.start()
            let encoded = try await h.exchange("GET \(h.originURL)encoded HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(encoded.lowercased().contains("content-encoding: gzip"))
            let compressed = try #require(h.proxy.records.drain().records.first)
            #expect(compressed.receivedBody.isComplete && compressed.receivedBody.isEncoded)
            #expect(compressed.receivedBody.contentType == "application/json")
            #expect(compressed.receivedBody.contentEncoding == "gzip")
            #expect(compressed.receivedBody.data == Data(gzipJSONFixture))
            #expect(compressed.responseBody.data == compressed.receivedBody.data)
            #expect(compressed.responseBody.isEncoded)

            _ = try await h.exchange("GET \(h.originURL)interrupted HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let partial = try #require(h.proxy.records.drain().records.first)
            #expect(partial.outcome == .failed && partial.error != nil)
            #expect(partial.originalStatus == 200 && partial.status == 200)
            #expect(partial.responseHeaders.contains { $0.name.lowercased() == "transfer-encoding" && $0.value == "chunked" })
            #expect(partial.responseBody.data == Data("origin-body".utf8))
            #expect(partial.receivedBody.state == .incomplete && !partial.receivedBody.isComplete)
            #expect(partial.receivedBody.data == Data("origin-body".utf8))
            #expect(partial.responseBody.state == .incomplete && !partial.responseBody.isComplete)
        }
    }
    @Test func bodyWriteFailureCannotBecomeACompleteSnapshotWhenEndSucceeds() throws {
        let records = CaptureRecordBuffer()
        let shared = ProxySharedState()
        var workflow = RequestWorkflow(); workflow.urlPrefix = "http://example.test/"
        var mock = ModificationStep(kind: .mock); mock.status = 201; mock.value = "not-written"
        workflow.requestSteps = [mock]
        var project = WorkflowProject(); project.workflows = [workflow]
        var document = WorkspaceDocument(); document.projects = [project]
        let documentSnapshot = document
        shared.document.withLock { $0 = documentSnapshot }
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandlers([RejectResponseBodyWrite(), ProxyConnection(configuration: .init(), shared: shared, records: records)]).wait()
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        try channel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.test/", headers: HTTPHeaders([("Host", "example.test")]))))
        let record = try #require(records.drain().records.first)
        #expect(record.outcome == .failed && record.status == 201)
        #expect(record.responseBody.state == .incomplete && !record.responseBody.isComplete)
        #expect(record.responseBody.data == Data("not-written".utf8))
    }

    @Test func explicitUpstreamReceivesAbsoluteURL() async throws {
        try await withHarness { h in
            var upstream = ExplicitProxyConfiguration(); upstream.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: h.originPort))
            try await h.start(configuration: upstream)
            let reply = try await h.exchange("GET http://unresolved.test/path?q=1 HTTP/1.1\r\nHost: unresolved.test\r\n\r\n")
            #expect(reply.contains("origin-body"))
            #expect(h.observation.withLock { $0.uri } == "http://unresolved.test/path?q=1")
        }
    }
}

private struct OriginObservation { var requests = 0; var header = ""; var bodyBytes = 0; var uri = "" }
private final class Harness: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let proxy = LocalProxyServer()
    let observation = OSAllocatedUnfairLock(initialState: OriginObservation())
    var origin: Channel?
    var originPort = 0
    var proxyPort = 0
    var originURL: String { "http://127.0.0.1:\(originPort)/" }
    func prepare() async throws {
        let observation = observation
        origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                try channel.pipeline.syncOperations.addHandler(OriginHandler(observation: observation))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        originPort = try #require(origin?.localAddress?.port)
    }
    func start(workflow: RequestWorkflow? = nil, environment: WorkspaceEnvironment? = nil, configuration: ExplicitProxyConfiguration = .init()) async throws {
        var document = WorkspaceDocument()
        if let workflow { var p = WorkflowProject(name: "test"); p.workflows = [workflow]; document.projects = [p] }
        if let environment { document.environments = [environment]; document.selectedEnvironmentID = environment.id }
        var configuration = configuration
        // OS-selected port from a temporary listener, retry if another process claims it before bind.
        for attempt in 0..<5 {
            let reservation = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
            configuration.port = try #require(reservation.localAddress?.port)
            try await reservation.close().get()
            do { proxyPort = try await proxy.start(configuration: configuration, document: document); return }
            catch { if attempt == 4 { throw error } }
        }
    }
    func exchange(_ request: String, until: String? = nil) async throws -> String {
        // This raw fixture collects until EOF; explicitly opt out of persistence.
        let request = request.hasPrefix("CONNECT ") ? request : request.replacingOccurrences(
            of: "HTTP/1.1\r\n", with: "HTTP/1.1\r\nConnection: close\r\n")
        let promise = group.next().makePromise(of: String.self)
        let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
            channel.pipeline.addHandler(RawCollector(result: promise, until: until))
        }.connect(host: "127.0.0.1", port: proxyPort).get()
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(4)) { channel.close(promise: nil) }
        channel.writeAndFlush(channel.allocator.buffer(string: request), promise: nil)
        do { let reply = try await promise.futureResult.get(); timeout.cancel(); try? await channel.close().get(); return reply }
        catch { timeout.cancel(); try? await channel.close().get(); throw error }
    }
    func shutdown() async { await proxy.stop(); try? await origin?.close().get(); try? await group.shutdownGracefully() }
}
private func withHarness(_ body: (Harness) async throws -> Void) async throws {
    let h = Harness()
    do { try await h.prepare(); try await body(h); await h.shutdown() }
    catch { await h.shutdown(); throw error }
}
private final class OriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    let observation: OSAllocatedUnfairLock<OriginObservation>
    var method = HTTPMethod.GET
    var uri = ""
    init(observation: OSAllocatedUnfairLock<OriginObservation>) { self.observation = observation }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            method = head.method; uri = head.uri
            observation.withLock { $0.requests += 1; $0.header = head.headers.first(name: "X-Key") ?? ""; $0.uri = head.uri }
        case .body(let bytes): observation.withLock { $0.bodyBytes += bytes.readableBytes }
        case .end:
            let channel = context.channel
            let body = uri.hasSuffix("/large") ? String(repeating: "z", count: 1_048_576) : "origin-body"
            let bytes = uri.hasSuffix("/encoded") ? gzipJSONFixture : Array(body.utf8)
            let interrupted = uri.hasSuffix("/interrupted")
            var headers = HTTPHeaders([("Content-Length", String(bytes.count + (interrupted ? 32 : 0))), ("Connection", "close")])
            if uri.hasSuffix("/encoded") {
                headers.add(name: "Content-Encoding", value: "gzip")
                headers.add(name: "Content-Type", value: "application/json")
            }
            channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)), promise: nil)
            if method != .HEAD { channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(bytes: bytes))), promise: nil) }
            if interrupted { channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer()))).whenComplete { _ in channel.close(promise: nil) } }
            else { channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) } }
        }
    }
}
private final class RawCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let result: EventLoopPromise<String>
    let until: String?
    var bytes: [UInt8] = []
    var completed = false
    init(result: EventLoopPromise<String>, until: String?) { self.result = result; self.until = until }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bytes += unwrapInboundIn(data).readableBytesView
        if let until, String(decoding: bytes, as: UTF8.self).contains(until) { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !completed { completed = true; result.succeed(String(decoding: bytes, as: UTF8.self)) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { if !completed { completed = true; result.fail(error) }; context.close(promise: nil) }
}
private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.channel.writeAndFlush(unwrapInboundIn(data), promise: nil) }
}

private let gzipJSONFixture: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 171, 86, 202, 207, 86, 178, 42, 41, 42, 77, 173, 5, 0, 144, 95, 212, 167, 11, 0, 0, 0]

private enum InjectedBodyWriteError: Error { case rejected }
private final class RejectResponseBodyWrite: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = HTTPServerResponsePart
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .body = unwrapOutboundIn(data) { promise?.fail(InjectedBodyWriteError.rejected) }
        else { context.write(data, promise: promise) }
    }
}
