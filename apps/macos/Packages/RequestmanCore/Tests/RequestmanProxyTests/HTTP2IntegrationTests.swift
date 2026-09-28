import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import NIOTLS
import Testing
import os
import RequestmanCore
@testable import RequestmanCertificates
@testable import RequestmanProxy

/// TCP/TLS loopback only. Certificates are ephemeral and never installed in a keychain.
@Suite(.serialized)
struct HTTP2IntegrationTests {
    @Test(arguments: ["h2", "http/1.1", "none", "both", "prefer-http1"], [false, true])
    func browserNegotiatesOriginProtocol(originProtocol: String, upstream: Bool) async throws {
        try await withHTTP2Harness(originProtocol: originProtocol, upstream: upstream) { h in
            let (selected, reply) = try await h.browserRequest()
            let expected = ["h2", "both"].contains(originProtocol) ? "h2" : "http/1.1"
            #expect(selected == expected)
            #expect(reply.status == 200 && reply.body == "browser")
            #expect(h.observation.withLock { $0.connections } == 1)
            #expect(h.observation.withLock { $0.requests } == 1)
            let record = try #require(try await h.records(count: 1).first)
            let version = expected == "h2" ? "HTTP/2" : "HTTP/1.1"
            #expect(record.clientHTTPVersion == version && record.upstreamHTTPVersion == version)
            #expect(record.error == nil)
        }
    }

    @Test func browserNegotiationRejectsUntrustedOriginWithoutHTTP() async throws {
        try await withHTTP2Harness(trustOrigin: false) { h in
            await #expect(throws: (any Error).self) { try await h.browserRequest() }
            #expect(h.observation.withLock { $0.connections } == 1)
            #expect(h.observation.withLock { $0.requests } == 0)
            let record = try #require(try await h.records(count: 1).first)
            #expect(record.method == "CONNECT" && record.outcome == .failed)
            #expect(record.error?.contains("TLS") == true)
        }
    }

    @Test(arguments: ["h2", "http/1.1"])
    func browserMockNegotiatesTLSWithoutSendingOriginRequest(originProtocol: String) async throws {
        try await withHTTP2Harness(originProtocol: originProtocol) { h in
            var document = WorkspaceDocument()
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .contains, value: "/echo")
            var mock = ModificationStep(kind: .mock); mock.value = "local"
            workflow.requestSteps = [mock]
            var project = WorkflowProject(); project.workflows = [workflow]; document.projects = [project]
            await h.proxy.update(document)
            let (_, reply) = try await h.browserRequest()
            #expect(reply.status == 200 && reply.body == "local")
            #expect(h.observation.withLock { $0.connections } == 1)
            #expect(h.observation.withLock { $0.requests } == 0)
            let record = try #require(try await h.records(count: 1).first)
            #expect(record.upstreamHTTPVersion == nil && record.error == nil)
        }
    }

    @Test func http1OnlyBrowserStaysHTTP1WithDualProtocolOrigin() async throws {
        try await withHTTP2Harness(originProtocol: "both") { h in
            let (selected, reply) = try await h.browserRequest(offered: ["http/1.1"])
            #expect(selected == "http/1.1" && reply.status == 200)
            #expect(h.observation.withLock { $0.connections } == 1)
            let record = try #require(try await h.records(count: 1).first)
            #expect(record.clientHTTPVersion == "HTTP/1.1" && record.upstreamHTTPVersion == "HTTP/1.1")
        }
    }

    @Test(arguments: [false, true])
    func multiplexingTrailersLargeBodyAndCancellation(upstream: Bool) async throws {
        try await withHTTP2Harness(upstream: upstream) { h in
            let client = try await h.client(offered: ["h2", "http/1.1"])
            let held = try await client.send(path: "/hold", authority: h.authority)
            let fast = try await client.send(path: "/echo", authority: h.authority, body: "hello", omitLength: true, trailers: [("x-request-trailer", "tail")])
            let reply = try await fast.reply()
            #expect(reply.status == 200 && reply.body == "hello")
            #expect(reply.trailers?["x-response-trailer"] == ["tail"])
            #expect(h.observation.withLock { $0.connections } == 1)
            #expect(h.observation.withLock { $0.trailers?["x-request-trailer"] } == ["tail"])
            try? await held.channel.close().get()
            let big = try await client.send(path: "/large", authority: h.authority)
            #expect(try await big.reply().body.count == 256 * 1024)
            #expect(h.observation.withLock { $0.connections } == 1)
            let records = try await h.records(count: 3)
            #expect(records.allSatisfy { $0.clientHTTPVersion == "HTTP/2" && $0.upstreamHTTPVersion == "HTTP/2" })
            let echo = try #require(records.first { $0.url.hasSuffix("/echo") })
            #expect(!echo.requestHeaders.contains { ["transfer-encoding", "content-length"].contains($0.name.lowercased()) })
            #expect(!echo.receivedHeaders.contains { $0.name.lowercased() == "transfer-encoding" })
            #expect(echo.requestTrailers?.first?.value == "tail")
            #expect(echo.sentTrailers?.first?.value == "tail")
            #expect(echo.receivedTrailers?.first?.value == "tail")
            #expect(echo.responseTrailers?.first?.value == "tail")
            #expect(echo.requestBody.state == .complete && echo.responseBody.state == .complete)
            let archived = try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(echo))
            #expect(archived.clientHTTPVersion == "HTTP/2" && archived.responseTrailers?.first?.value == "tail")
            try await client.channel.close().get()
        }
    }

    @Test func modificationsMockAndSiblingIsolation() async throws {
        try await withHTTP2Harness { h in
            var document = WorkspaceDocument()
            var edit = RequestWorkflow(); edit.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .contains, value: "/edit")
            var requestBody = ModificationStep(kind: .replaceBody); requestBody.value = "changed-request"
            var requestHeader = ModificationStep(kind: .setHeader); requestHeader.name = "x-test"; requestHeader.value = "changed-header"
            var responseBody = ModificationStep(kind: .script); responseBody.value = "response.body = response.body + '-response'; return response;"
            edit.requestSteps = [requestHeader, requestBody]; edit.responseSteps = [responseBody]
            var mock = RequestWorkflow(); mock.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .contains, value: "/mock")
            var mocked = ModificationStep(kind: .mock); mocked.value = "local"; mock.requestSteps = [mocked]
            var project = WorkflowProject(); project.workflows = [edit, mock]; document.projects = [project]
            await h.proxy.update(document)
            let client = try await h.client()
            let edited = try await client.send(path: "/edit", authority: h.authority, body: "original")
            let local = try await client.send(path: "/mock", authority: h.authority)
            #expect(try await edited.reply().body == "changed-request-response")
            #expect(try await local.reply().body == "local")
            #expect(h.observation.withLock { $0.requests } == 1)
            #expect(h.observation.withLock { $0.header } == "changed-header")
            let records = try await h.records(count: 2)
            #expect(records.first { $0.url.hasSuffix("/mock") }?.upstreamHTTPVersion == nil)
            #expect(records.first { $0.url.hasSuffix("/edit") }?.responseBody.state == .complete)
            let sibling = try await client.send(path: "/echo", authority: h.authority, body: "still-open")
            #expect(try await sibling.reply().body == "still-open")
            try await client.channel.close().get()
        }
    }

    @Test(arguments: [false, true]) func replayPreservesHTTP2AndSourceIdentity(upstream: Bool) async throws {
        try await withHTTP2Harness(upstream: upstream) { h in
            var original = CaptureRecord(method: "POST", url: "https://\(h.authority)/echo")
            original.clientHTTPVersion = "HTTP/2"
            let collector = CaptureBodyCollector(headers: [])
            collector.append(Data("replayed".utf8)); original.requestBody = collector.snapshot(isComplete: true)
            let draft = try RequestReplayDraft(record: original)
            #expect(draft.httpVersion == "HTTP/2")
            try await h.proxy.replay(draft)
            let record = try #require(try await h.records(count: 1).first)
            #expect(record.id == draft.id && record.replaySourceID == original.id)
            #expect(record.clientHTTPVersion == "HTTP/2" && record.upstreamHTTPVersion == "HTTP/2")
            #expect(record.error == nil && record.responseBody.data == Data("replayed".utf8))
            #expect(h.observation.withLock { $0.requests } == 1)
        }
    }

    @Test func goAwayCreatesNewConnectionOnlyForNewRequests() async throws {
        try await withHTTP2Harness { h in
            let client = try await h.client(offered: ["h2", "http/1.1"])
            let first = try await client.send(path: "/goaway", authority: h.authority, body: "first")
            #expect(try await first.reply().body == "first")
            let second = try await client.send(path: "/echo", authority: h.authority, body: "second")
            #expect(try await second.reply().body == "second")
            #expect(h.observation.withLock { $0.connections } == 2)
            #expect(h.observation.withLock { $0.requests } == 2)
            try await client.channel.close().get()
        }
    }

    @Test func jsonEditsAndRuleFailureAreStreamLocal() async throws {
        try await withHTTP2Harness { h in
            var document = WorkspaceDocument()
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .contains, value: "/json")
            var requestEdit = ModificationStep(kind: .modifyJSON); requestEdit.jsonEntries = [.init(path: "value", value: "2")]
            var responseEdit = ModificationStep(kind: .modifyJSON); responseEdit.jsonEntries = [.init(path: "result", value: "true")]
            workflow.requestSteps = [requestEdit]; workflow.responseSteps = [responseEdit]
            var project = WorkflowProject(); project.workflows = [workflow]; document.projects = [project]
            await h.proxy.update(document)
            let client = try await h.client()
            let valid = try await client.send(path: "/json", authority: h.authority, body: #"{"value":1}"#)
            let invalid = try await client.send(path: "/json", authority: h.authority, body: "not JSON")
            #expect(try await valid.reply().body == #"{"value":2,"result":true}"#)
            #expect(try await invalid.reply().status == 400)
            #expect(h.observation.withLock { $0.requests } == 1)
            let sibling = try await client.send(path: "/echo", authority: h.authority, body: "alive")
            #expect(try await sibling.reply().body == "alive")
            try await client.channel.close().get()
        }
    }

    @Test func sseReplacementCancelsOnlyItsUpstreamStream() async throws {
        try await withHTTP2Harness { h in
            var document = WorkspaceDocument()
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .contains, value: "/sse")
            var replacement = ModificationStep(kind: .replaceBody); replacement.value = "data: replaced\n\n"
            workflow.responseSteps = [replacement]
            var project = WorkflowProject(); project.workflows = [workflow]; document.projects = [project]
            await h.proxy.update(document)
            let client = try await h.client()
            let held = try await client.send(path: "/hold", authority: h.authority)
            let stream = try await client.send(path: "/sse", authority: h.authority)
            #expect(try await stream.reply().body == "data: replaced\n\n")
            #expect(held.channel.isActive)
            let sibling = try await client.send(path: "/echo", authority: h.authority, body: "alive")
            #expect(try await sibling.reply().body == "alive")
            #expect(h.observation.withLock { $0.connections } == 1)
            try? await held.channel.close().get()
            _ = try await h.records(count: 3)
            try await client.channel.close().get()
        }
    }

    @Test(arguments: ["http/1.1", "none"])
    func http2NeverFallsBackToHTTP1(originProtocol: String) async throws {
        try await withHTTP2Harness(originProtocol: originProtocol) { h in
            let client = try await h.client()
            let request = try await client.send(path: "/mismatch", authority: h.authority)
            let reply = try await request.reply()
            #expect(reply.status == 502)
            #expect(h.observation.withLock { $0.requests } == 0)
            #expect(h.observation.withLock { $0.connections } == 1)
            let record = try #require(try await h.records(count: 1).first)
            #expect(record.outcome == .failed && record.error?.contains("协议") == true)
            #expect(record.clientHTTPVersion == "HTTP/2" && record.upstreamHTTPVersion == nil)
            try await client.channel.close().get()
        }
    }

    @Test func http1NeverUpgradesToHTTP2() async throws {
        try await withHTTP2Harness { h in
            try await h.proxy.replay(RequestReplayDraft(method: "GET", url: "https://\(h.authority)/mismatch", headers: [], body: Data()))
            let record = try #require(try await h.records(count: 1).first)
            #expect(record.outcome == .failed && record.status == 502)
            #expect(h.observation.withLock { $0.requests } == 0)
            #expect(h.observation.withLock { $0.connections } == 1)
            #expect(record.clientHTTPVersion == "HTTP/1.1" && record.upstreamHTTPVersion != "HTTP/2")
        }
    }

    @Test func sseDoesNotBlockSiblingAndStopClosesAllStreams() async throws {
        try await withHTTP2Harness { h in
            let client = try await h.client()
            let sse = try await client.send(path: "/sse", authority: h.authority)
            let sibling = try await client.send(path: "/echo", authority: h.authority, body: "parallel")
            #expect(try await sibling.reply().body == "parallel")
            let held = try await client.send(path: "/hold", authority: h.authority)
            for _ in 0..<200 {
                if h.observation.withLock({ $0.requests }) >= 3 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await h.proxy.stop()
            try await client.channel.closeFuture.get()
            #expect(!sse.channel.isActive && !held.channel.isActive)
            let records = try await h.records(count: 2)
            #expect(records.contains { $0.captureProtocol == .sse })
        }
    }
}

private struct HTTP2Observation {
    var connections = 0
    var requests = 0
    var header = ""
    var trailers: HTTPHeaders?
}
private struct HTTP2Reply: Sendable {
    var status: UInt = 0
    var body = ""
    var trailers: HTTPHeaders?
}
private struct HTTP2Request: Sendable {
    let channel: Channel
    let result: EventLoopFuture<HTTP2Reply>
    func reply() async throws -> HTTP2Reply { try await result.get() }
}
private struct HTTP2Client: Sendable {
    let channel: Channel
    let multiplexer: NIOHTTP2Handler.StreamMultiplexer
    func send(path: String, authority: String, body: String = "", omitLength: Bool = false, trailers: [(String, String)] = []) async throws -> HTTP2Request {
        let promise = channel.eventLoop.makePromise(of: HTTP2Reply.self)
        let stream = try await multiplexer.createStreamChannel { stream in
            stream.eventLoop.makeCompletedFuture { try stream.pipeline.syncOperations.addHandlers(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https), HTTP2Collector(promise: promise)) }
        }.get()
        var headers = HTTPHeaders([("host", authority)])
        if !body.isEmpty && !omitLength { headers.add(name: "content-length", value: String(body.utf8.count)) }
        stream.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http2, method: body.isEmpty ? .GET : .POST, uri: path, headers: headers)), promise: nil)
        if !body.isEmpty { stream.write(HTTPClientRequestPart.body(.byteBuffer(stream.allocator.buffer(string: body))), promise: nil) }
        try await stream.writeAndFlush(HTTPClientRequestPart.end(trailers.isEmpty ? nil : HTTPHeaders(trailers))).get()
        return HTTP2Request(channel: stream, result: promise.futureResult)
    }
}
private final class HTTP2Collector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let promise: EventLoopPromise<HTTP2Reply>
    var reply = HTTP2Reply()
    var done = false
    var timeout: Scheduled<Void>?
    init(promise: EventLoopPromise<HTTP2Reply>) { self.promise = promise }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        timeout = channel.eventLoop.scheduleTask(in: .seconds(8)) { channel.close(promise: nil) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): reply.status = head.status.code
        case .body(let body): reply.body += String(decoding: body.readableBytesView, as: UTF8.self)
        case .end(let trailers):
            guard !done else { return }; done = true; timeout?.cancel()
            reply.trailers = trailers; promise.succeed(reply)
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel()
        if !done { done = true; promise.fail(WorkflowError.invalid("测试流提前关闭")) }
    }
    func fail(_ error: Error) {
        if !done { done = true; timeout?.cancel(); promise.fail(error) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
}
private final class BrowserTLSFailure: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let collector: HTTP2Collector
    init(collector: HTTP2Collector) { self.collector = collector }
    func channelInactive(context: ChannelHandlerContext) {
        collector.fail(WorkflowError.invalid("测试浏览器连接提前关闭")); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        collector.fail(error); context.close(promise: nil)
    }
}
private struct HTTP2CertificateProvider: TLSCertificateProviding {
    let authority: EphemeralTLSAuthority
    func serverIdentity(for host: String) async throws -> TLSCertificateIdentity? { try authority.identity(for: host) }
}
private final class HTTP2Harness: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let observation = OSAllocatedUnfairLock(initialState: HTTP2Observation())
    let channels = OSAllocatedUnfairLock(initialState: [Channel]())
    let ca: EphemeralTLSAuthority
    let proxy: LocalProxyServer
    var upstream: LocalProxyServer?
    var origin: Channel?
    var proxyPort = 0
    var authority = ""
    init(trustOrigin: Bool = true) throws {
        ca = try EphemeralTLSAuthority()
        proxy = LocalProxyServer(certificateProvider: HTTP2CertificateProvider(authority: ca), upstreamTrustRoots: trustOrigin ? [try ca.trustRoot()] : [try EphemeralTLSAuthority().trustRoot()])
    }
    func start(originProtocol: String, upstream: Bool) async throws {
        let identity = try ca.identity(for: "localhost")
        let cert = try NIOSSLCertificate(bytes: Array(identity.certificateDER), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM), format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key))
        config.applicationProtocols = originProtocol == "none" ? [] : originProtocol == "both" ? ["h2", "http/1.1"] : originProtocol == "prefer-http1" ? ["http/1.1", "h2"] : [originProtocol]
        let tls = try NIOSSLContext(configuration: config)
        origin = try await ServerBootstrap(group: group).childChannelInitializer { [self] channel in
            channels.withLock { $0.append(channel) }; observation.withLock { $0.connections += 1 }
            return channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }.flatMap {
                if originProtocol == "both" || originProtocol == "prefer-http1" {
                    return channel.configureHTTP2SecureUpgrade(h2ChannelConfigurator: { channel in
                        channel.configureHTTP2Pipeline(mode: .server, connectionConfiguration: .init(), streamConfiguration: .init(), inboundStreamInitializer: { stream in
                            stream.pipeline.addHandlers(HTTP2FramePayloadToHTTP1ServerCodec(), HTTP2OriginHandler(observation: self.observation))
                        }).map { _ in () }
                    }, http1ChannelConfigurator: { channel in
                        channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(HTTP2OriginHandler(observation: self.observation)) }
                    })
                }
                if originProtocol == "h2" {
                    return channel.configureHTTP2Pipeline(mode: .server, connectionConfiguration: .init(), streamConfiguration: .init(), inboundStreamInitializer: { stream in
                        stream.eventLoop.makeCompletedFuture { try stream.pipeline.syncOperations.addHandlers(HTTP2FramePayloadToHTTP1ServerCodec(), HTTP2OriginHandler(observation: self.observation)) }
                    }).map { _ in () }
                }
                return channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(HTTP2OriginHandler(observation: self.observation)) }
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        authority = "localhost:\(try #require(origin?.localAddress?.port))"
        var proxyConfig = ExplicitProxyConfiguration()
        if upstream {
            let upstream = LocalProxyServer(); self.upstream = upstream
            proxyConfig.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: try await startProxy(upstream, configuration: .init())))
        }
        proxyPort = try await startProxy(proxy, configuration: proxyConfig)
    }
    private func startProxy(_ proxy: LocalProxyServer, configuration: ExplicitProxyConfiguration) async throws -> Int {
        let reservation = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        var config = configuration; config.port = try #require(reservation.localAddress?.port)
        try await reservation.close().get()
        return try await proxy.start(configuration: config, document: .init())
    }
    func client(offered: [String] = ["h2"]) async throws -> HTTP2Client {
        var config = TLSConfiguration.makeClientConfiguration()
        config.trustRoots = .certificates([try ca.trustRoot()]); config.applicationProtocols = offered
        let tls = try NIOSSLContext(configuration: config)
        let promise = group.next().makePromise(of: NIOHTTP2Handler.StreamMultiplexer.self)
        let authority = authority
        let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers(HTTPSCONNECTGate(authority: authority, coalesce: true, coalesced: OSAllocatedUnfairLock(initialState: false)),
                    NIOSSLClientHandler(context: tls, serverHostname: "localhost"))
            }.flatMap {
                    let future = channel.configureHTTP2Pipeline(mode: .client, connectionConfiguration: proxyHTTP2Configuration(server: false), streamConfiguration: .init(), inboundStreamInitializer: { $0.close() })
                    future.cascade(to: promise)
                    return future.map { _ in () }
                }
        }.connect(host: "127.0.0.1", port: proxyPort).get()
        channels.withLock { $0.append(channel) }
        return HTTP2Client(channel: channel, multiplexer: try await promise.futureResult.get())
    }
    func browserRequest(offered: [String] = ["h2", "http/1.1"]) async throws -> (String, HTTP2Reply) {
        var config = TLSConfiguration.makeClientConfiguration()
        config.trustRoots = .certificates([try ca.trustRoot()]); config.applicationProtocols = offered
        let tls = try NIOSSLContext(configuration: config)
        let loop = group.next()
        let result = loop.makePromise(of: HTTP2Reply.self)
        let collector = HTTP2Collector(promise: result)
        let selected = OSAllocatedUnfairLock(initialState: "")
        let authority = authority
        let channel = try await ClientBootstrap(group: loop).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers(HTTPSCONNECTGate(authority: authority, coalesce: true, coalesced: OSAllocatedUnfairLock(initialState: false)),
                    NIOSSLClientHandler(context: tls, serverHostname: "localhost"),
                    ApplicationProtocolNegotiationHandler { negotiated in
                        let stream: EventLoopFuture<Channel>
                        let protocolName: String
                        if negotiated == .negotiated("h2") {
                            protocolName = "h2"
                            stream = channel.configureHTTP2Pipeline(mode: .client, connectionConfiguration: proxyHTTP2Configuration(server: false), streamConfiguration: .init(), inboundStreamInitializer: { $0.close() }).flatMap { mux in
                                mux.createStreamChannel { stream in
                                    stream.pipeline.addHandlers(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https), collector)
                                }
                            }
                        } else {
                            protocolName = "http/1.1"
                            stream = channel.pipeline.addHTTPClientHandlers().flatMap {
                                channel.pipeline.addHandler(collector)
                            }.map { channel }
                        }
                        selected.withLock { $0 = protocolName }
                        return stream.flatMap { stream in
                            let head = HTTPRequestHead(version: protocolName == "h2" ? .http2 : .http1_1, method: .POST, uri: "/echo", headers: HTTPHeaders([("host", authority), ("content-length", "7")]))
                            stream.write(HTTPClientRequestPart.head(head), promise: nil)
                            stream.write(HTTPClientRequestPart.body(.byteBuffer(stream.allocator.buffer(string: "browser"))), promise: nil)
                            return stream.writeAndFlush(HTTPClientRequestPart.end(nil))
                        }
                    }, BrowserTLSFailure(collector: collector))
            }
        }.connect(host: "127.0.0.1", port: proxyPort).get()
        channels.withLock { $0.append(channel) }
        let timeout = loop.scheduleTask(in: .seconds(10)) { channel.close(promise: nil) }
        defer { timeout.cancel() }
        let reply = try await result.futureResult.get()
        try await channel.close().get()
        return (selected.withLock { $0 }, reply)
    }

    func records(count: Int) async throws -> [CaptureRecord] {
        var records: [UUID: CaptureRecord] = [:]
        for _ in 0..<400 {
            for record in proxy.records.drain().records where !record.connectionState.isActive { records[record.id] = record }
            if records.count >= count { return Array(records.values) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkflowError.invalid("等待测试日志超时，已收到 \(records.count)/\(count)")
    }
    func close() async {
        await proxy.stop(); await upstream?.stop()
        for channel in channels.withLock({ $0 }) { try? await channel.close().get() }
        try? await origin?.close().get()
        try? await group.shutdownGracefully()
    }
}
private final class HTTP2OriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    let observation: OSAllocatedUnfairLock<HTTP2Observation>
    var head: HTTPRequestHead?
    var body = ""
    init(observation: OSAllocatedUnfairLock<HTTP2Observation>) { self.observation = observation }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            observation.withLock { $0.requests += 1; $0.header = head.headers["x-test"].first ?? "" }
        case .body(let data): body += String(decoding: data.readableBytesView, as: UTF8.self)
        case .end(let trailers):
            observation.withLock { if trailers != nil { $0.trailers = trailers } }
            guard let head else { return }
            if head.uri == "/hold" { return }
            if head.uri == "/goaway", let parent = context.channel.parent {
                parent.writeAndFlush(HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)), promise: nil)
            }
            var headers = HTTPHeaders()
            if head.uri == "/sse" { headers.add(name: "content-type", value: "text/event-stream") }
            context.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: head.version, status: .ok, headers: headers))), promise: nil)
            let body = head.uri == "/large" ? String(repeating: "x", count: 256 * 1024) : head.uri == "/sse" ? "data: hello\n\n" : self.body
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(context.channel.allocator.buffer(string: body)))), promise: nil)
            if head.uri != "/sse" { context.write(NIOAny(HTTPServerResponsePart.end(HTTPHeaders([("x-response-trailer", "tail")]))), promise: nil) }
            context.flush()
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
private func withHTTP2Harness(originProtocol: String = "h2", upstream: Bool = false, trustOrigin: Bool = true, _ body: (HTTP2Harness) async throws -> Void) async throws {
    let h = try HTTP2Harness(trustOrigin: trustOrigin)
    do { try await h.start(originProtocol: originProtocol, upstream: upstream); try await body(h); await h.close() }
    catch { await h.close(); throw error }
}
