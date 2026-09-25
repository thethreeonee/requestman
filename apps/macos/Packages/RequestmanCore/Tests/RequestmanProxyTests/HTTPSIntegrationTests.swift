import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing
import X509
import os
import RequestmanCore
@testable import RequestmanCertificates
@testable import RequestmanProxy

/// Real TCP/TLS tests. All certificates and trust anchors live only in memory.
@Suite(.serialized)
struct HTTPSIntegrationTests {
    @Test(arguments: [false, true])
    func sequentialHTTPSRequestsReuseBothTLSConnections(useHTTPUpstream: Bool) async throws {
        try await withHTTPSHarness { h in
            try await h.start(useHTTPUpstream: useHTTPUpstream)
            let replies = try await h.exchangeSequence(paths: ["/one", "/two", "/three"])
            #expect(replies.map(\.status) == [200, 200, 200])
            #expect(replies.allSatisfy { $0.body == "secure-origin-body" })
            #expect(replies.allSatisfy { $0.headers.first(name: "connection") == "keep-alive" })
            #expect(h.observation.withLock { $0.connections } == 1)
            #expect(h.observation.withLock { $0.requests } == 3)
            let records = h.proxy.records.drain().records
            #expect(records.count == 3)
            #expect(Set(records.map(\.id)).count == 3)
            #expect(records.map(\.url) == ["one", "two", "three"].map { h.originURL + $0 })
            #expect(records.allSatisfy { $0.requestBody.isComplete && $0.responseBody.isComplete && $0.error == nil })
            #expect(records.allSatisfy { $0.responseBytes == "secure-origin-body".utf8.count })
        }
    }

    @Test func originCloseStillAllowsNextRequestOnClientTLSConnection() async throws {
        try await withHTTPSHarness { h in
            try await h.start()
            let replies = try await h.exchangeSequence(paths: ["/origin-close", "/two"])
            #expect(replies.map(\.status) == [200, 200])
            #expect(h.observation.withLock { $0.connections } == 2)
        }
    }

    @Test func reusedConnectionResetsWorkflowAndBodyState() async throws {
        try await withHTTPSHarness { h in
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL + "modify"
            var header = ModificationStep(kind: .setHeader)
            header.name = "X-Modified"; header.value = "yes"
            var body = ModificationStep(kind: .replaceBody); body.value = "replacement"
            workflow.responseSteps = [header, body]
            try await h.start(workflow: workflow)
            let replies = try await h.exchangeSequence(paths: ["/modify", "/plain"])
            #expect(replies.map(\.body) == ["replacement", "secure-origin-body"])
            #expect(replies[0].headers.first(name: "X-Modified") == "yes")
            #expect(replies[1].headers.first(name: "X-Modified") == nil)
            #expect(h.observation.withLock { $0.connections } == 1)
            let records = h.proxy.records.drain().records
            #expect(records.map(\.outcome) == [.modified, .forwarded])
            #expect(records.map { $0.responseBody.data } == [Data("replacement".utf8), Data("secure-origin-body".utf8)])
        }
    }

    @Test func stopClosesIdlePersistentConnectionWithoutExtraRecord() async throws {
        try await withHTTPSHarness { h in
            try await h.start()
            let replies = try await h.exchangeSequence(paths: ["/one"], stopWhenIdle: true)
            #expect(replies.count == 1)
            let records = h.proxy.records.drain().records
            #expect(records.count == 1 && records.first?.error == nil)
        }
    }
    @Test func decryptsHTTPSAndRecordsOriginalMethodURLAndHeaders() async throws {
        try await withHTTPSHarness { h in
            try await h.start()
            let reply = try await h.exchange(path: "/api/items?q=a%2Bb", method: .POST,
                                             headers: [("X-Original", "visible")], body: "request-body")
            #expect(reply.status == 200)
            #expect(reply.body == "secure-origin-body")
            #expect(h.observation.withLock { $0.uri } == "/api/items?q=a%2Bb")
            #expect(h.observation.withLock { $0.body } == "request-body")
            let record = try #require(await h.firstRecord())
            #expect(record.method == "POST")
            #expect(record.url == h.originURL + "api/items?q=a%2Bb")
            #expect(record.requestHeaders.contains { $0.name.lowercased() == "x-original" && $0.value == "visible" })
            #expect(record.outcome == .forwarded)
            #expect(record.status == 200)
            #expect(record.requestBytes == "request-body".utf8.count)
            #expect(record.responseBytes == "secure-origin-body".utf8.count)
        }
    }

    @Test func requestAndResponseWorkflowsModifyDecryptedHTTPS() async throws {
        try await withHTTPSHarness { h in
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var requestHeader = ModificationStep(kind: .setHeader)
            requestHeader.name = "X-Key"; requestHeader.value = "https-workflow"
            var requestBody = ModificationStep(kind: .replaceBody); requestBody.value = "changed-request"
            var responseHeader = ModificationStep(kind: .setHeader)
            responseHeader.name = "X-HTTPS-Modified"; responseHeader.value = "yes"
            var responseBody = ModificationStep(kind: .replaceBody); responseBody.value = "changed-response"
            var responseStatus = ModificationStep(kind: .setStatus); responseStatus.status = 202
            workflow.requestSteps = [requestHeader, requestBody]
            workflow.responseSteps = [responseHeader, responseBody, responseStatus]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange(path: "/modify", method: .POST, body: "original-request")
            #expect(reply.status == 202)
            #expect(reply.headers.first(name: "X-HTTPS-Modified") == "yes")
            #expect(reply.body == "changed-response")
            #expect(h.observation.withLock { $0.header } == "https-workflow")
            #expect(h.observation.withLock { $0.body } == "changed-request")
            let record = try #require(await h.firstRecord())
            #expect(record.outcome == .modified)
            #expect(record.requestBody.isComplete && record.requestBody.data == Data("original-request".utf8))
            #expect(record.sentBody.isComplete && record.sentBody.data == Data("changed-request".utf8))
            #expect(record.receivedBody.isComplete && record.receivedBody.data == Data("secure-origin-body".utf8))
            #expect(record.responseBody.isComplete && record.responseBody.data == Data("changed-response".utf8))
        }
    }

    @Test func HTTPSMockSkipsOriginAndStillAppliesResponseWorkflow() async throws {
        try await withHTTPSHarness { h in
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var mock = ModificationStep(kind: .mock); mock.status = 201; mock.value = "secure-local-mock"
            var header = ModificationStep(kind: .setHeader); header.name = "X-Mock-Flow"; header.value = "yes"
            workflow.requestSteps = [mock]; workflow.responseSteps = [header]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange(path: "/mock")
            #expect(reply.status == 201)
            #expect(reply.body == "secure-local-mock")
            #expect(reply.headers.first(name: "X-Mock-Flow") == "yes")
            #expect(h.observation.withLock { $0.requests } == 0)
            #expect(h.observation.withLock { $0.connections } == 0)
            let record = try #require(await h.firstRecord())
            #expect(record.outcome == .mocked && record.responseBody.isComplete)
            #expect(record.responseBody.data == Data("secure-local-mock".utf8))
            #expect(record.sentBody.state == .unavailable && record.receivedBody.state == .unavailable)
            let headReply = try await h.exchange(path: "/mock-head", method: .HEAD)
            #expect(headReply.status == 201 && headReply.body.isEmpty)
            let head = try #require(await h.firstRecord())
            #expect(head.responseBody.isComplete && head.responseBody.data.isEmpty)
        }
    }

    @Test func HTTPSRedirectCapturesAnEmptyFinalBodyWithoutOriginResponse() async throws {
        try await withHTTPSHarness { h in
            var workflow = RequestWorkflow(); workflow.urlPrefix = h.originURL
            var redirect = ModificationStep(kind: .redirect); redirect.status = 302; redirect.value = "https://example.test/next"
            workflow.requestSteps = [redirect]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange(path: "/redirect")
            #expect(reply.status == 302 && reply.body.isEmpty)
            #expect(reply.headers.first(name: "Location") == "https://example.test/next")
            let record = try #require(await h.firstRecord())
            #expect(record.responseBody.isComplete && record.responseBody.data.isEmpty)
            #expect(record.receivedBody.state == .unavailable && record.originalStatus == nil)
            #expect(h.observation.withLock { $0.connections } == 0)
        }
    }

    @Test func HTTPSUsesCONNECTAndTLSOverExplicitHTTPUpstream() async throws {
        try await withHTTPSHarness { h in
            try await h.start(useHTTPUpstream: true)
            let reply = try await h.exchange(path: "/through-upstream?q=1")
            #expect(reply.status == 200)
            #expect(reply.body == "secure-origin-body")
            #expect(h.observation.withLock { $0.uri } == "/through-upstream?q=1")
            #expect(await h.firstRecord()?.url == h.originURL + "through-upstream?q=1")
            let upstream = try #require(h.upstream)
            #expect(upstream.records.drain().records.contains { $0.method == "CONNECT" && $0.outcome == .tunnel })
        }
    }

    @Test func rejectsUntrustedOriginCertificateWithoutForwardingHTTP() async throws {
        try await withHTTPSHarness(trustOrigin: false) { h in
            try await h.start()
            let reply = try await h.exchange(path: "/must-not-reach-origin")
            #expect(reply.status == 502)
            #expect(h.observation.withLock { $0.requests } == 0)
            let record = try #require(await h.firstRecord())
            #expect(record.outcome == .failed)
            #expect(record.error != nil)
        }
    }

    @Test func rejectsOriginCertificateWithWrongHostname() async throws {
        try await withHTTPSHarness(originCertificateHost: "wrong.invalid") { h in
            try await h.start()
            let reply = try await h.exchange(path: "/must-not-reach-origin")
            #expect(reply.status == 502)
            #expect(h.observation.withLock { $0.requests } == 0)
            #expect(await h.firstRecord()?.outcome == .failed)
        }
    }

    @Test func upstreamTLSValidatesTargetIPInsteadOfProxySocketIP() async throws {
        try await withHTTPSHarness(originCertificateHost: "127.0.0.2") { h in
            let reply = try await h.exchangeDirectTLS(validatedHost: "127.0.0.2")
            #expect(reply.status == 200)
            #expect(reply.body == "secure-origin-body")
            #expect(h.observation.withLock { $0.requests } == 1)
        }
    }

    @Test func upstreamTLSRejectsCertificateForWrongTargetIP() async throws {
        try await withHTTPSHarness(originCertificateHost: "127.0.0.2") { h in
            await #expect(throws: NIOSSLError.self) {
                try await h.exchangeDirectTLS(validatedHost: "127.0.0.3")
            }
            #expect(h.observation.withLock { $0.requests } == 0)
        }
    }

    @Test func preservesTLSClientHelloCoalescedWithCONNECTHeaders() async throws {
        try await withHTTPSHarness { h in
            try await h.start()
            let reply = try await h.exchange(path: "/early-tls", coalesceClientHello: true)
            #expect(h.coalescedClientHello.withLock { $0 })
            #expect(reply.status == 200)
            #expect(reply.body == "secure-origin-body")
            #expect(await h.firstRecord()?.url == h.originURL + "early-tls")
        }
    }
}

private struct EphemeralTLSAuthority: Sendable {
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

private struct EphemeralTLSProvider: TLSCertificateProviding {
    let authority: EphemeralTLSAuthority
    func serverIdentity(for host: String) async throws -> TLSCertificateIdentity? {
        try authority.identity(for: host)
    }
}

private struct HTTPSOriginObservation {
    var connections = 0
    var requests = 0
    var uri = ""
    var header = ""
    var body = ""
}

private struct HTTPSReply: Sendable {
    var status: UInt = 0
    var headers = HTTPHeaders()
    var body = ""
}

private enum HTTPSFixtureError: Error {
    case unexpectedCONNECTResponse(String)
    case connectionClosed
    case timeout
}

private final class HTTPSHarness: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let proxy: LocalProxyServer
    let observation = OSAllocatedUnfairLock(initialState: HTTPSOriginObservation())
    let coalescedClientHello = OSAllocatedUnfairLock(initialState: false)
    let proxyAuthority: EphemeralTLSAuthority
    let originAuthority: EphemeralTLSAuthority
    let originCertificateHost: String
    var origin: Channel?
    var upstream: LocalProxyServer?
    var originPort = 0
    var proxyPort = 0
    var authority: String { "localhost:\(originPort)" }
    var originURL: String { "https://\(authority)/" }

    init(trustOrigin: Bool, originCertificateHost: String) throws {
        proxyAuthority = try EphemeralTLSAuthority()
        originAuthority = try EphemeralTLSAuthority()
        self.originCertificateHost = originCertificateHost
        proxy = LocalProxyServer(
            certificateProvider: EphemeralTLSProvider(authority: proxyAuthority),
            upstreamTrustRoots: [try (trustOrigin ? originAuthority : proxyAuthority).trustRoot()]
        )
    }

    func prepare() async throws {
        let identity = try originAuthority.identity(for: originCertificateHost)
        let certificate = try NIOSSLCertificate(bytes: Array(identity.certificateDER), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(key))
        configuration.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: configuration)
        let observation = observation
        origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            observation.withLock { $0.connections += 1 }
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                try channel.pipeline.syncOperations.addHandler(HTTPSOriginHandler(observation: observation))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        originPort = try #require(origin?.localAddress?.port)
    }

    func start(workflow: RequestWorkflow? = nil, useHTTPUpstream: Bool = false) async throws {
        var document = WorkspaceDocument()
        if let workflow {
            var project = WorkflowProject(name: "https-test"); project.workflows = [workflow]
            document.projects = [project]
        }
        var configuration = ExplicitProxyConfiguration()
        if useHTTPUpstream {
            let upstream = LocalProxyServer()
            self.upstream = upstream
            let port = try await start(upstream, configuration: .init(), document: .init())
            configuration.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: port))
        }
        proxyPort = try await start(proxy, configuration: configuration, document: document)
    }

    private func start(_ server: LocalProxyServer, configuration: ExplicitProxyConfiguration, document: WorkspaceDocument) async throws -> Int {
        var configuration = configuration
        for attempt in 0..<5 {
            let reservation = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
            configuration.port = try #require(reservation.localAddress?.port)
            try await reservation.close().get()
            do { return try await server.start(configuration: configuration, document: document) }
            catch { if attempt == 4 { throw error } }
        }
        throw HTTPSFixtureError.connectionClosed
    }

    func exchange(path: String, method: HTTPMethod = .GET, headers: [(String, String)] = [], body: String = "", coalesceClientHello: Bool = false) async throws -> HTTPSReply {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        configuration.trustRoots = .certificates([try proxyAuthority.trustRoot()])
        configuration.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: configuration)
        let promise = group.next().makePromise(of: HTTPSReply.self)
        let authority = authority
        let coalesced = coalescedClientHello
        let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(HTTPSCONNECTGate(authority: authority, coalesce: coalesceClientHello, coalesced: coalesced))
                try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: "localhost"))
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                try channel.pipeline.syncOperations.addHandler(HTTPSResponseCollector(result: promise))
            }
        }.connect(host: "127.0.0.1", port: proxyPort).get()
        return try await request(on: channel, result: promise, authority: authority, path: path,
                                 method: method, headers: headers, body: body)
    }

    func exchangeSequence(paths: [String], stopWhenIdle: Bool = false) async throws -> [HTTPSReply] {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = .certificates([try proxyAuthority.trustRoot()])
        configuration.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: configuration)
        let loop = group.next()
        let promises = paths.map { _ in loop.makePromise(of: HTTPSReply.self) }
        let authority = authority, coalesced = coalescedClientHello
        let channel = try await ClientBootstrap(group: loop).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(HTTPSCONNECTGate(authority: authority, coalesce: false, coalesced: coalesced))
                try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: "localhost"))
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                try channel.pipeline.syncOperations.addHandler(HTTPSSequenceCollector(results: promises))
            }
        }.connect(host: "127.0.0.1", port: proxyPort).get()
        let timeout = loop.scheduleTask(in: .seconds(8)) { channel.close(promise: nil) }
        do {
            var replies: [HTTPSReply] = []
            for (path, promise) in zip(paths, promises) {
                let headers = HTTPHeaders([("Host", authority), ("Content-Length", "0"), ("Connection", "keep-alive")])
                channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)), promise: nil)
                try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
                replies.append(try await promise.futureResult.get())
            }
            if stopWhenIdle {
                await proxy.stop()
                try await channel.closeFuture.get()
                #expect(!channel.isActive)
            } else { try await channel.close().get() }
            timeout.cancel()
            return replies
        } catch {
            timeout.cancel(); try? await channel.close().get(); throw error
        }
    }

    /// CONNECT preserves the proxy socket's remote address. Connecting to .1 while
    /// validating .2 reproduces that transport/target distinction without binding an alias.
    func exchangeDirectTLS(validatedHost: String) async throws -> HTTPSReply {
        let roots = [try originAuthority.trustRoot()]
        let promise = group.next().makePromise(of: HTTPSReply.self)
        let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ProxyTLS.client(host: validatedHost, testTrustRoots: roots))
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                try channel.pipeline.syncOperations.addHandler(HTTPSResponseCollector(result: promise))
            }
        }.connect(host: "127.0.0.1", port: originPort).get()
        #expect(channel.remoteAddress?.ipAddress == "127.0.0.1")
        return try await request(on: channel, result: promise, authority: validatedHost, path: "/target-ip")
    }

    private func request(on channel: Channel, result promise: EventLoopPromise<HTTPSReply>,
                         authority: String, path: String, method: HTTPMethod = .GET,
                         headers: [(String, String)] = [], body: String = "") async throws -> HTTPSReply {
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(8)) {
            channel.pipeline.fireErrorCaught(HTTPSFixtureError.timeout)
            channel.close(promise: nil)
        }
        var requestHeaders = HTTPHeaders(headers)
        requestHeaders.replaceOrAdd(name: "Host", value: authority)
        requestHeaders.replaceOrAdd(name: "Connection", value: "close")
        requestHeaders.replaceOrAdd(name: "Content-Length", value: String(body.utf8.count))
        channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: method, uri: path, headers: requestHeaders)), promise: nil)
        if !body.isEmpty { channel.write(HTTPClientRequestPart.body(.byteBuffer(channel.allocator.buffer(string: body))), promise: nil) }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        do {
            let reply = try await promise.futureResult.get()
            timeout.cancel(); try? await channel.close().get()
            return reply
        } catch {
            timeout.cancel(); try? await channel.close().get()
            throw error
        }
    }

    func firstRecord() async -> CaptureRecord? {
        for _ in 0..<50 {
            if let record = proxy.records.drain().records.first { return record }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func shutdown() async {
        await proxy.stop(); await upstream?.stop()
        try? await origin?.close().get()
        try? await group.shutdownGracefully()
    }
}

private func withHTTPSHarness(trustOrigin: Bool = true, originCertificateHost: String = "localhost", _ body: (HTTPSHarness) async throws -> Void) async throws {
    let harness = try HTTPSHarness(trustOrigin: trustOrigin, originCertificateHost: originCertificateHost)
    do { try await harness.prepare(); try await body(harness); await harness.shutdown() }
    catch { await harness.shutdown(); throw error }
}

private final class HTTPSOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    let observation: OSAllocatedUnfairLock<HTTPSOriginObservation>
    private var keepAlive = false
    init(observation: OSAllocatedUnfairLock<HTTPSOriginObservation>) { self.observation = observation }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            keepAlive = head.isKeepAlive && head.uri != "/origin-close"
            observation.withLock { $0.requests += 1; $0.uri = head.uri; $0.header = head.headers.first(name: "X-Key") ?? "" }
        case .body(let buffer):
            observation.withLock { $0.body += String(decoding: buffer.readableBytesView, as: UTF8.self) }
        case .end:
            let channel = context.channel
            let body = "secure-origin-body"
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([
                ("Content-Length", String(body.utf8.count)), ("Connection", keepAlive ? "keep-alive" : "close"), ("X-Origin", "secure")
            ]))
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(string: body))), promise: nil)
            let keepAlive = keepAlive
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                if !keepAlive { channel.close(promise: nil) }
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class HTTPSSequenceCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let results: [EventLoopPromise<HTTPSReply>]
    var index = 0
    var reply = HTTPSReply()
    init(results: [EventLoopPromise<HTTPSReply>]) { self.results = results }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard index < results.count else { return }
        switch unwrapInboundIn(data) {
        case .head(let head): reply = HTTPSReply(); reply.status = head.status.code; reply.headers = head.headers
        case .body(let buffer): reply.body += String(decoding: buffer.readableBytesView, as: UTF8.self)
        case .end:
            let promise = results[index]; index += 1; promise.succeed(reply)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { fail(HTTPSFixtureError.connectionClosed) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
    private func fail(_ error: Error) {
        while index < results.count { let promise = results[index]; index += 1; promise.fail(error) }
    }
}

private final class HTTPSResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let result: EventLoopPromise<HTTPSReply>
    var reply = HTTPSReply()
    var completed = false
    init(result: EventLoopPromise<HTTPSReply>) { self.result = result }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): reply.status = head.status.code; reply.headers = head.headers
        case .body(let buffer): reply.body += String(decoding: buffer.readableBytesView, as: UTF8.self)
        case .end:
            if !completed { completed = true; result.succeed(reply) }
            context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !completed { completed = true; result.fail(HTTPSFixtureError.connectionClosed) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed { completed = true; result.fail(error) }
        context.close(promise: nil)
    }
}

/// Strips the clear-text CONNECT response before TLS. The early-TLS case writes the
/// CONNECT request and the TLS engine's first ClientHello in one socket write.
private final class HTTPSCONNECTGate: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let authority: String
    let coalesce: Bool
    let coalesced: OSAllocatedUnfairLock<Bool>
    var sentCONNECT = false
    var established = false
    var responseBytes: [UInt8] = []
    var pendingWrites: [(ByteBuffer, EventLoopPromise<Void>?)] = []

    init(authority: String, coalesce: Bool, coalesced: OSAllocatedUnfairLock<Bool>) {
        self.authority = authority; self.coalesce = coalesce; self.coalesced = coalesced
    }

    private var connectRequest: String { "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n" }

    func channelActive(context: ChannelHandlerContext) {
        if !coalesce {
            sentCONNECT = true
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: connectRequest)), promise: nil)
        }
        context.fireChannelActive()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var bytes = unwrapOutboundIn(data)
        if !sentCONNECT {
            sentCONNECT = true
            var combined = context.channel.allocator.buffer(string: connectRequest)
            let hasBytes = bytes.readableBytes > 0
            coalesced.withLock { $0 = hasBytes }
            combined.writeBuffer(&bytes)
            context.write(wrapOutboundOut(combined), promise: promise)
        } else if established || coalesce {
            context.write(data, promise: promise)
        } else {
            pendingWrites.append((bytes, promise))
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !established else { context.fireChannelRead(data); return }
        responseBytes += unwrapInboundIn(data).readableBytesView
        guard responseBytes.count >= 4 else { return }
        guard let end = (0...(responseBytes.count - 4)).first(where: {
            responseBytes[$0] == 13 && responseBytes[$0 + 1] == 10 && responseBytes[$0 + 2] == 13 && responseBytes[$0 + 3] == 10
        }) else {
            if responseBytes.count > 16_384 { errorCaught(context: context, error: HTTPSFixtureError.unexpectedCONNECTResponse("oversized headers")) }
            return
        }
        let headerEnd = end + 4
        let response = String(decoding: responseBytes.prefix(headerEnd), as: UTF8.self)
        guard response.hasPrefix("HTTP/1.1 200 ") || response.hasPrefix("HTTP/1.0 200 ") else {
            errorCaught(context: context, error: HTTPSFixtureError.unexpectedCONNECTResponse(response)); return
        }
        established = true
        for (buffer, promise) in pendingWrites { context.write(wrapOutboundOut(buffer), promise: promise) }
        pendingWrites.removeAll(); context.flush()
        if responseBytes.count > headerEnd {
            let leftover = context.channel.allocator.buffer(bytes: responseBytes.dropFirst(headerEnd))
            context.fireChannelRead(wrapInboundOut(leftover))
        }
        responseBytes.removeAll()
    }

    func channelInactive(context: ChannelHandlerContext) {
        for (_, promise) in pendingWrites { promise?.fail(HTTPSFixtureError.connectionClosed) }
        pendingWrites.removeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        for (_, promise) in pendingWrites { promise?.fail(error) }
        pendingWrites.removeAll()
        context.fireErrorCaught(error)
    }
}
