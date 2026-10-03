import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOHTTP1
import Testing
import os
import RequestmanCore
import RequestmanCertificates
@testable import RequestmanProxy

@Suite(.serialized)
struct ProxyIntegrationTests {
    @Test func mobileLANHTTPUsesConfiguredUpstreamAndRecordsPeer() async throws {
        try await withHarness { h in
            var config = ExplicitProxyConfiguration(); config.allowLAN = true
            config.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: h.originPort))
            try await h.start(configuration: config)
            let host = LocalNetwork.addresses().first?.host ?? "127.0.0.1"
            let reply = try await h.exchange("GET http://mobile.test/phone HTTP/1.1\r\nHost: mobile.test\r\n\r\n", host: host)
            #expect(reply.contains("200 OK"))
            #expect(h.observation.withLock { $0.uri } == "http://mobile.test/phone")
            let record = try #require(h.proxy.records.drain().records.last)
            #expect(record.deviceSource == DeviceSource.identifier(for: host))
            #expect(record.url == "http://mobile.test/phone")
        }
    }

    @Test func mobileSetupDownloadsBypassRulesAndUpstream() async throws {
        let certificate = Data("public-certificate-fixture".utf8)
        let h = Harness(certificateProvider: MobilePublicCertificate(data: certificate))
        do {
            try await h.prepare()
            var config = ExplicitProxyConfiguration(); config.allowLAN = true
            config.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: h.originPort))
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = .init(field: .url, operation: .contains, value: "requestman")
            var mock = ModificationStep(kind: .mock); mock.value = "should-not-appear"; workflow.requestSteps = [mock]
            try await h.start(workflow: workflow, configuration: config)
            let host = "127.0.0.1:\(h.proxyPort)"
            let page = try await h.exchange("GET /requestman HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            #expect(page.contains("200 OK") && page.contains("连接 Requestman"))
            let cert = try await h.exchange("GET http://\(host)/requestman/ca.cer HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            #expect(cert.contains("application/pkix-cert") && cert.hasSuffix("public-certificate-fixture"))
            let profile = try await h.exchange("GET /requestman/ios.mobileconfig HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            let body = try #require(profile.components(separatedBy: "\r\n\r\n").last?.data(using: .utf8))
            let plist = try #require(PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])
            let payload = try #require((plist["PayloadContent"] as? [[String: Any]])?.first)
            #expect(payload["PayloadType"] as? String == "com.apple.security.root")
            #expect(payload["PayloadContent"] as? Data == certificate)
            #expect(h.observation.withLock { $0.requests } == 0)
            #expect(h.proxy.records.drain().records.isEmpty)
            await h.shutdown()
        } catch { await h.shutdown(); throw error }
    }

    @Test func mobileSetupIsUnavailableWithoutLANOrCertificate() async throws {
        try await withHarness { h in
            try await h.start()
            let unavailable = try await h.exchange("GET /requestman HTTP/1.1\r\nHost: 127.0.0.1:\(h.proxyPort)\r\n\r\n")
            #expect(!unavailable.contains("200 OK"))
            await h.proxy.stop()
            var config = ExplicitProxyConfiguration(); config.allowLAN = true
            try await h.start(configuration: config)
            let certificate = try await h.exchange("GET /requestman/ca.cer HTTP/1.1\r\nHost: 127.0.0.1:\(h.proxyPort)\r\n\r\n")
            #expect(certificate.contains("503 Service Unavailable"))
        }
    }

    @Test func requestReplayCancellationBeforeAttachmentClosesLaterTransport() throws {
        let records = CaptureRecordBuffer()
        records.setPaused(true)
        var request = RequestReplayDraft(method: "GET", url: "http://example.test/", headers: [], body: Data())
        request.sourceRecordID = UUID()
        let session = ProxyReplaySession(request: request, records: records)
        session.cancel()
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait()
        session.attach(channel)
        #expect(!channel.isActive)
        session.clientClosed()
        let record = try #require(records.drain().records.first)
        #expect(record.replayID == request.id && record.replaySourceID == request.sourceRecordID)
        #expect(record.replayCancelled && record.error == nil && !record.connectionState.isActive)
        session.clientClosed()
        #expect(records.drain().records.isEmpty)
    }

    @Test func requestReplayCancellationIsIsolatedAndVisibleWhilePaused() async throws {
        try await withHarness { h in
            try await h.start()
            h.proxy.records.setPaused(true)
            var first = RequestReplayDraft(method: "GET", url: h.originURL + "events", headers: [], body: Data())
            first.sourceRecordID = UUID()
            let second = RequestReplayDraft(method: "GET", url: h.originURL + "events", headers: [], body: Data())
            try await h.proxy.replay(first)
            try await h.proxy.replay(second)
            var latest: [UUID: CaptureRecord] = [:]
            for _ in 0..<200 {
                for record in h.proxy.records.drain().records { latest[record.id] = record }
                if latest[first.id]?.stream?.summary.count == 1 && latest[second.id]?.stream?.summary.count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(latest[first.id]?.replaySourceID == first.sourceRecordID)
            #expect(latest[second.id]?.connectionState.isActive == true)
            await h.proxy.cancelReplay(first.id)
            for _ in 0..<200 {
                for record in h.proxy.records.drain().records { latest[record.id] = record }
                if latest[first.id]?.replayCancelled == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let cancelled = try #require(latest[first.id])
            #expect(cancelled.replayCancelled)
            #expect(!cancelled.connectionState.isActive)
            #expect(cancelled.error == nil)
            #expect(latest[second.id]?.connectionState.isActive == true)
            // Normal requests and the listener survive individual replay cancellation.
            let reply = try await h.exchange("GET \(h.originURL) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            #expect(reply.contains("200 OK"))
            #expect(h.proxy.records.drain().records.allSatisfy { $0.replayID != nil })
            await h.proxy.stop()
            for _ in 0..<200 {
                for record in h.proxy.records.drain().records { latest[record.id] = record }
                if latest[second.id]?.replayCancelled == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(latest[second.id]?.replayCancelled == true)
        }
    }

    @Test func requestReplayFailurePublishesTerminalResultWithIdentity() async throws {
        try await withHarness { h in
            try await h.start()
            // Deterministic proxy-loop rejection happens after local submission succeeds.
            let request = RequestReplayDraft(method: "GET", url: "http://127.0.0.1:\(h.proxyPort)/", headers: [], body: Data())
            try await h.proxy.replay(request)
            var terminal: CaptureRecord?
            for _ in 0..<200 {
                terminal = h.proxy.records.drain().records.last { $0.id == request.id && !$0.connectionState.isActive } ?? terminal
                if terminal != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let record = try #require(terminal)
            #expect(record.replayID == request.id && record.error != nil && !record.replayCancelled)
            #expect(record.replaySummary?.hasPrefix("重放失败：") == true)
        }
    }

    @Test(arguments: ["HEAD", "headers", "SSE"]) func requestReplayDrainsResponsesAndStopsStreams(kind: String) async throws {
        try await withHarness { h in
            try await h.start()
            let path = kind == "SSE" ? "events" : "large-headers"
            try await h.proxy.replay(RequestReplayDraft(method: kind == "HEAD" ? "HEAD" : "GET", url: h.originURL + path, headers: [], body: Data()))
            var observed: CaptureRecord?
            for _ in 0..<200 {
                for record in h.proxy.records.drain().records {
                    if kind == "SSE" ? record.stream?.summary.count == 1 : record.connectionState == .closed { observed = record }
                }
                if observed != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let record = try #require(observed)
            #expect(record.error == nil && record.status == 200)
            if kind == "HEAD" { #expect(record.responseBody.data.isEmpty && record.responseBody.isComplete) }
            if kind == "headers" { #expect(record.responseHeaders.contains { $0.name == "Set-Cookie" && $0.value.count > 100_000 }) }
            if kind == "SSE" {
                #expect(record.captureProtocol == .sse && record.connectionState.isActive)
                await h.proxy.stop()
                #expect(h.proxy.records.drain().records.last?.connectionState.isActive == false)
            }
        }
    }

    @Test func requestReplayUsesProxyRulesAndPublishesANewRecord() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var header = ModificationStep(kind: .setHeader); header.name = "X-Replayed"; header.value = "yes"
            workflow.requestSteps = [header]
            workflow.responseSteps = []
            try await h.start(workflow: workflow)
            let bytes = Data([0, 255, 65, 10])
            let draft = RequestReplayDraft(method: "POST", url: h.originURL + "replay?q=1", headers: [HTTPField("X-Duplicate", "a"), HTTPField("X-Duplicate", "b")], body: bytes)
            try await h.proxy.replay(draft)
            var completed: CaptureRecord?
            for _ in 0..<200 {
                if let record = h.proxy.records.drain().records.last(where: { $0.connectionState == .closed }) { completed = record; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let record = try #require(completed)
            #expect(record.method == "POST" && record.url == draft.url)
            #expect(record.requestBody.data == bytes && record.sentBody.data == bytes)
            #expect(record.requestHeaders.filter { $0.name == "X-Duplicate" }.map(\.value) == ["a", "b"])
            #expect(record.sentHeaders.contains { $0.name == "X-Replayed" && $0.value == "yes" })
            #expect(record.status == 200 && record.responseBody.isComplete)
            #expect(record.matchedWorkflowID == workflow.id && record.error == nil)
            #expect(h.observation.withLock { $0.requests } == 1)
            await h.proxy.stop()
            await #expect(throws: (any Error).self) { try await h.proxy.replay(draft) }
        }
    }

    @Test(arguments: [false, true])
    func mockBeforeUnreachableBodyWorkRespondsWithoutWaitingForUpload(file: Bool) async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var mock = ModificationStep(kind: .mock); mock.status = 201; mock.value = "immediate-local-response"
            var unreachable = ModificationStep(kind: file ? .replaceBody : .script)
            if file {
                unreachable.bodySource = .file
                unreachable.bodyFilePath = "/missing/requestman-unreachable-body-file"
            } else { unreachable.value = "throw new Error('unreachable script executed');" }
            workflow.requestSteps = [mock, unreachable]
            try await h.start(workflow: workflow)
            let started = ContinuousClock.now
            let reply = try await h.exchange("POST \(h.originURL) HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\n\r\n", timeout: .seconds(2))
            #expect(started.duration(to: .now) < .seconds(1))
            #expect(reply.contains("201 Created") && reply.contains("immediate-local-response"))
            #expect(h.observation.withLock { $0.requests } == 0)
            let record = try #require(h.proxy.records.drain().records.last)
            #expect(record.outcome == .mocked)
            #expect(record.executionTrace.map(\.stepID) == [mock.id])
            #expect(record.executionTrace.allSatisfy { $0.status == .applied })
        }
    }

    @Test(arguments: [false, true]) func SSEReplacementCancelsEndlessOriginAndDelayDoesNotWaitForEOF(file: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("requestman-sse-test-\(UUID())")
        if file { try Data("data: replacement\n\n".utf8).write(to: url) }
        defer { if file { _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil) } }
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var body = ModificationStep(kind: .replaceBody); body.value = "data: replacement\n\n"
            if file { body.bodySource = .file; body.bodyFilePath = url.path }
            var delay = ModificationStep(kind: .delay); delay.value = "20"
            workflow.responseSteps.insert(contentsOf: [delay, body], at: 0)
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)events HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("data: replacement") && !reply.contains("data: origin"))
            try await Task.sleep(for: .milliseconds(80))
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.captureProtocol == .sse && record.connectionState == .closed && record.error == nil)
            #expect(record.closeReason?.contains("取消上游") == true)
            #expect(h.observation.withLock { $0.closedConnections } == 1)
            #expect(try await record.stream?.read(from: 0).first?.text == "replacement")
        }
    }
    @Test func SSEDelayForwardsTheFirstEventWithoutWaitingForEOF() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var delay = ModificationStep(kind: .delay); delay.value = "20"
            var header = ModificationStep(kind: .setHeader); header.name = "X-SSE-Modified"; header.value = "yes"
            var status = ModificationStep(kind: .setStatus); status.status = 202
            workflow.responseSteps = [delay, header, status]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)events HTTP/1.1\r\nHost: localhost\r\n\r\n", until: "data: origin")
            #expect(reply.contains("data: origin") && reply.contains("text/event-stream"))
            #expect(reply.contains("202 Accepted") && reply.lowercased().contains("x-sse-modified: yes"))
        }
    }
    @Test(arguments: [false, true]) func SSERequestHintsAndLegacyFlagDoNotConvertOrdinaryResponses(legacyFlag: Bool) async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            workflow.isSSE = legacyFlag
            var accept = ModificationStep(kind: .setHeader); accept.name = "Accept"; accept.value = "text/event-stream"
            var type = ModificationStep(kind: .setHeader); type.name = "Content-Type"; type.value = "text/event-stream"
            workflow.requestSteps = [accept, type]
            workflow.responseSteps = [type]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)ordinary HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.sentHeaders.contains { $0.name.lowercased() == "accept" && $0.value == "text/event-stream" })
            #expect(reply.contains("origin-body") && reply.lowercased().contains("content-type: text/event-stream"))
            #expect(record.captureProtocol == .http && record.stream == nil && record.receivedStream == nil)
            #expect(record.responseBody.data == Data("origin-body".utf8) && record.responseBody.isComplete)
            #expect(record.error == nil && record.closeReason == nil)
        }
    }
    @Test(arguments: [false, true]) func SSEAutomaticDetectionPreservesBodyScriptBoundary(replaceFirst: Bool) async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var body = ModificationStep(kind: .replaceBody); body.value = "data: replacement\n\n"
            var script = ModificationStep(kind: .script)
            script.value = "response.headers.push({name:'X-Script',value:'applied'}); return response;"
            workflow.responseSteps = replaceFirst ? [body, script] : [script, body]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("POST \(h.originURL)events HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")
            try await Task.sleep(for: .milliseconds(80))
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.captureProtocol == .sse)
            if replaceFirst {
                #expect(record.error == nil && reply.lowercased().contains("x-script: applied"))
                #expect(try await record.stream?.read(from: 0).first?.text == "replacement")
            } else {
                #expect(reply.contains("502") && record.error?.contains("替换 Body 之后") == true)
            }
        }
    }
    @Test func SSEReplacementKeepsLiteralBodyWhenContentTypeChanges() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var body = ModificationStep(kind: .replaceBody); body.value = "{\"ok\":true}"
            var type = ModificationStep(kind: .setHeader); type.name = "Content-Type"; type.value = "application/json"
            workflow.responseSteps = [body, type]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)events HTTP/1.1\r\nHost: localhost\r\n\r\n")
            try await Task.sleep(for: .milliseconds(80))
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(reply.hasSuffix(body.value) && reply.lowercased().contains("content-type: application/json"))
            #expect(!reply.contains("data:") && record.closeReason?.contains("取消上游") == true)
            #expect(try await record.stream?.readRaw(from: 0) == Data(body.value.utf8))
            #expect(record.error == nil && record.stream?.summary.count == 0)
        }
    }
    @Test func SSEPublishesEventsBeforeOriginCloses() async throws {
        try await withHarness { h in
            try await h.start()
            let channel = try await ClientBootstrap(group: h.group).connect(host: "127.0.0.1", port: h.proxyPort).get()
            try await channel.writeAndFlush(channel.allocator.buffer(string: "GET \(h.originURL)events HTTP/1.1\r\nHost: localhost\r\n\r\n")).get()
            try await Task.sleep(for: .milliseconds(350))
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.captureProtocol == .sse && record.connectionState == .open)
            #expect(try await record.stream?.read(from: 0).first?.text == "origin")
            #expect(record.responseBody.state == .unavailable)
            h.proxy.records.clear()
            try await Task.sleep(for: .milliseconds(250))
            #expect(h.proxy.records.drain().records.isEmpty)
            try await channel.close().get()
        }
    }

    @Test func mappedBodyFilesReachRequestResponseAndMock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("requestman-proxy-body-\(UUID()).bin")
        defer { _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        for mode in 0..<4 {
            try await withHarness { h in
                var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
                var file = ModificationStep(kind: mode == 2 ? .mock : .replaceBody)
                file.bodySource = .file; file.bodyFilePath = url.path
                if mode == 0 || mode == 2 { workflow.requestSteps = [file] }
                else {
                    if mode == 3 { workflow.requestSteps = [ModificationStep(kind: .mock)] }
                    workflow.responseSteps = [file]
                }
                try await h.start(workflow: workflow)
                for bytes in [Data([0, 255, 128, 10, 13]), Data("updated {{literal}}".utf8), Data()] {
                    try bytes.write(to: url, options: .atomic)
                    _ = try await h.exchange("POST \(h.originURL)file HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nbody")
                    let record = try #require(h.proxy.records.drain().records.first)
                    #expect(record.error == nil)
                    #expect((mode == 0 ? record.sentBody.data : record.responseBody.data) == bytes)
                    #expect((record.outcome == .mocked) == (mode >= 2))
                }
            }
        }
    }

    @Test func capturedRequestPrefillForwardsAndRestoresOriginalResponse() async throws {
        try await withHarness { h in
            try await h.start()
            let request = "POST \(h.originURL)captured?q=a%2Bb&q=second HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\ninput"
            _ = try await h.exchange(request)
            var captured = try #require(h.proxy.records.drain().records.first)
            captured.originalStatus = 202
            captured.receivedHeaders = [HTTPField("Content-Type", "application/x-captured"), HTTPField("X-Origin-Snapshot", "saved")]
            let body = CaptureBodyCollector(headers: captured.receivedHeaders)
            body.append(Data("saved original response".utf8))
            captured.receivedBody = body.snapshot(isComplete: true)
            let workflow = try CapturedMockWorkflow.make(from: captured)
            #expect(workflow.responseSteps.map(\.kind) == [.setStatus, .replaceBody, .setHeader])
            var project = WorkflowProject(); project.workflows = [workflow]
            var document = WorkspaceDocument(); document.projects = [project]
            await h.proxy.update(document)
            _ = try await h.exchange(request.replacingOccurrences(of: "input", with: "other"))
            #expect(h.observation.withLock { $0.requests } == 2)
            let forwarded = try #require(h.proxy.records.drain().records.first)
            #expect(forwarded.outcome != .mocked)
            #expect(forwarded.sentBody.data == Data("input".utf8))
            #expect(forwarded.status == 202)
            #expect(forwarded.responseBody.data == Data("saved original response".utf8))
            #expect(forwarded.responseBody.data != forwarded.receivedBody.data)
            #expect(forwarded.responseHeaders.contains(HTTPField("Content-Type", "application/x-captured")))
            #expect(!forwarded.responseHeaders.contains { $0.name == "X-Origin-Snapshot" })
        }
    }

    @Test func capturedBinaryRequestWritesOriginalBytesAndHeadersToOrigin() async throws {
        try await withHarness { h in
            var captured = CaptureRecord(method: "POST", url: h.originURL + "binary")
            captured.requestHeaders = [HTTPField("Content-Type", "application/octet-stream"), HTTPField("X-Value", "first"), HTTPField("X-Value", "second")]
            let bytes = Data([0, 255, 128, 10, 13, 65])
            let collector = CaptureBodyCollector(headers: captured.requestHeaders); collector.append(bytes)
            captured.requestBody = collector.snapshot(isComplete: true)
            let workflow = try CapturedMockWorkflow.make(from: captured)
            try await h.start(workflow: workflow)
            _ = try await h.exchange("POST \(captured.url) HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nX-Value: old1\r\nX-Value: old2\r\nContent-Length: 0\r\n\r\n")
            let forwarded = try #require(h.proxy.records.drain().records.first)
            #expect(forwarded.sentBody.data == bytes && forwarded.sentBody.isComplete)
            #expect(forwarded.sentHeaders.filter { $0.name == "X-Value" }.map(\.value) == ["second", "second"])
            #expect(forwarded.sentHeaders.first { $0.name == "Content-Length" }?.value == "6")
            #expect(h.observation.withLock { $0.requests } == 1)
        }
    }

    @Test func originAndMockDelaysCanExceedThirtySeconds() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for mocked in [false, true] {
                group.addTask {
                    try await withHarness { h in
                        var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
                        if mocked { workflow.requestSteps = [ModificationStep(kind: .mock)] }
                        var delay = ModificationStep(kind: .delay); delay.value = "31000"
                        var status = ModificationStep(kind: .setStatus); status.status = 202
                        var script = ModificationStep(kind: .script)
                        script.value = "response.headers.push({name:'X-Completed',value:'yes'}); return response;"
                        workflow.responseSteps = [delay, status, script]
                        try await h.start(workflow: workflow)
                        let start = ContinuousClock.now
                        let reply = try await h.exchange("GET \(h.originURL)long-delay HTTP/1.1\r\nHost: localhost\r\n\r\n", timeout: .seconds(40))
                        #expect(start.duration(to: .now) >= .seconds(31))
                        #expect(reply.contains("202 Accepted") && reply.lowercased().contains("x-completed: yes"))
                        let record = try #require(h.proxy.records.drain().records.first)
                        #expect(record.error == nil && record.duration >= 31)
                        #expect(record.matchedRules.filter(\.response).map(\.kind) == [.delay, .setStatus, .script])
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func activeHTTPAndDecryptedHTTPSUploadsHaveNoTotalDeadline() throws {
        for secure in [false, true] {
            let shared = ProxySharedState(), records = CaptureRecordBuffer()
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: "\(secure ? "https" : "http")://example.test/")
            // Keep the body pending, without starting an upstream connection or script process.
            workflow.requestSteps = [ModificationStep(kind: .script)]
            var project = WorkflowProject(); project.workflows = [workflow]
            var document = WorkspaceDocument(); document.projects = [project]
            shared.document.withLock { [document] in $0 = document }
            let channel = EmbeddedChannel(handler: ProxyConnection(configuration: .init(), shared: shared,
                records: records, tlsAuthority: secure ? "example.test:443" : nil))
            defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            try channel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .POST,
                uri: secure ? "/upload" : "http://example.test/upload",
                headers: HTTPHeaders([("Host", "example.test"), ("Content-Length", "100")]))))
            try channel.writeInbound(HTTPServerRequestPart.body(channel.allocator.buffer(string: "partial")))
            channel.embeddedEventLoop.advanceTime(by: .seconds(60))
            #expect(channel.isActive && records.drain().records.isEmpty)
            #expect(try channel.readOutbound(as: HTTPServerResponsePart.self) == nil)
            try channel.close().wait()
            let record = try #require(records.drain().records.first)
            #expect(record.requestBody.state == .incomplete && record.error == "客户端连接已关闭")
        }
    }

    @Test func waitingForFirstRequestStillHasIdleTimeout() throws {
        let channel = EmbeddedChannel(handler: ProxyConnection(configuration: .init(), shared: ProxySharedState(), records: CaptureRecordBuffer()))
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        channel.embeddedEventLoop.advanceTime(by: .seconds(31))
        #expect(!channel.isActive)
    }

    @Test func responseDelayWaitsForOriginAndMockBeforeFollowingSteps() async throws {
        for mocked in [false, true] {
            try await withHarness { h in
                var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
                if mocked { workflow.requestSteps = [ModificationStep(kind: .mock)] }
                var delay = ModificationStep(kind: .delay); delay.value = "100"
                var status = ModificationStep(kind: .setStatus); status.status = 202
                workflow.responseSteps = [delay, status]
                try await h.start(workflow: workflow)
                let start = ContinuousClock.now
                let reply = try await h.exchange("GET \(h.originURL)delay HTTP/1.1\r\nHost: localhost\r\n\r\n")
                #expect(start.duration(to: .now) >= .milliseconds(100))
                #expect(reply.contains("202 Accepted"))
                #expect(reply.contains(mocked ? "\"ok\": true" : "origin-body"))
                #expect(h.observation.withLock { $0.requests } == (mocked ? 0 : 1))
                let record = try #require(h.proxy.records.drain().records.first)
                #expect(record.error == nil && record.duration >= 0.1)
                #expect(record.matchedRules.filter(\.response).map(\.kind) == [.delay, .setStatus])
            }
        }
    }

    @Test func concurrentDelaysDoNotUseScriptSlotsOrBlockOtherRequests() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL + "delay")
            var delay = ModificationStep(kind: .delay); delay.value = "500"
            workflow.responseSteps = [delay]
            try await h.start(workflow: workflow)
            let completed = OSAllocatedUnfairLock(initialState: 0)
            let requests = (0..<6).map { index in
                Task {
                    let reply = try await h.exchange("GET \(h.originURL)delay/\(index) HTTP/1.1\r\nHost: localhost\r\n\r\n")
                    completed.withLock { $0 += 1 }
                    return reply
                }
            }
            defer { requests.forEach { $0.cancel() } }
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while h.observation.withLock({ $0.requests }) < 6 && ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let reply = try await h.exchange("GET \(h.originURL)unmatched HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("200 OK") && completed.withLock { $0 } == 0)
            for request in requests { #expect(try await request.value.contains("200 OK")) }
            let records = h.proxy.records.drain().records
            #expect(records.count == 7 && records.allSatisfy { $0.error == nil })
        }
    }

    @Test func stoppingCaptureCancelsDelayAndSkipsFollowingSteps() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var delay = ModificationStep(kind: .delay); delay.value = "10000"
            var status = ModificationStep(kind: .setStatus); status.status = 201
            var header = ModificationStep(kind: .setHeader); header.name = "X-Before-Delay"; header.value = "yes"
            workflow.responseSteps = [header, delay, status]
            try await h.start(workflow: workflow)
            let request = Task { try await h.exchange("GET \(h.originURL)delay HTTP/1.1\r\nHost: localhost\r\n\r\n") }
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while h.observation.withLock({ $0.requests }) == 0 && ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try await Task.sleep(for: .milliseconds(50))
            let start = ContinuousClock.now
            await h.proxy.stop()
            let reply = try await request.value
            #expect(start.duration(to: .now) < .seconds(1))
            #expect(!reply.contains("201 Created"))
            var final = h.proxy.records.drain().records.last
            let traceDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while final?.executionTrace.last?.status != .cancelled && ContinuousClock.now < traceDeadline {
                try await Task.sleep(for: .milliseconds(5))
                if let update = h.proxy.records.drain().records.last { final = update }
            }
            let record = try #require(final)
            #expect(record.executionTrace.map(\.stepID) == [header.id, delay.id])
            #expect(record.executionTrace.map(\.status) == [.applied, .cancelled])
            #expect(record.matchedRules.map(\.kind) == [.setHeader])
            #expect(h.proxy.events.drain().events.map(\.kind) == [.matched, .cancelled])
        }
    }

    @Test func delayPreservesEncodedBytesAndWorksWithScripts() async throws {
        for scripted in [false, true] {
            try await withHarness { h in
                var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
                var delay = ModificationStep(kind: .delay); delay.value = "50"
                workflow.responseSteps = [delay]
                if scripted {
                    var script = ModificationStep(kind: .script)
                    script.value = "response.headers.push({name:'X-Delayed',value:'yes'}); return response;"
                    workflow.responseSteps.append(script)
                }
                try await h.start(workflow: workflow)
                let reply = try await h.exchange("GET \(h.originURL)encoded HTTP/1.1\r\nHost: localhost\r\n\r\n")
                #expect(reply.contains("200 OK"))
                let record = try #require(h.proxy.records.drain().records.first)
                #expect(record.error == nil)
                if scripted {
                    #expect(reply.lowercased().contains("x-delayed: yes"))
                    #expect(record.matchedRules.map(\.kind) == [.delay, .script])
                } else {
                    #expect(record.responseBody.data == Data(gzipJSONFixture))
                    #expect(record.responseHeaders.contains { $0.name.lowercased() == "content-encoding" && $0.value == "gzip" })
                }
            }
        }
    }

    @Test func notifiesAtMatchingBeforeRequestBodyAndIndependentlyOfPausedHistory() throws {
        let shared = ProxySharedState(), records = CaptureRecordBuffer()
        records.setPaused(true)
        shared.ruleHitNotifications.startSession(enabled: true)
        var workflow = RequestWorkflow()
        workflow.name = "慢请求规则"
        workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: "http://example.test/")
        var script = ModificationStep(kind: .script)
        script.value = "return request;"
        workflow.requestSteps = [script]
        var project = WorkflowProject(); project.workflows = [workflow]
        var document = WorkspaceDocument(); document.projects = [project]
        shared.document.withLock { [document] in $0 = document }
        let channel = EmbeddedChannel(handler: ProxyConnection(configuration: .init(), shared: shared, records: records))
        defer { _ = try? channel.finish() }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "http://example.test/slow",
                                   headers: HTTPHeaders([("Host", "example.test"), ("Content-Length", "100")]))
        _ = try channel.writeInbound(HTTPServerRequestPart.head(head))
        #expect(shared.ruleHitNotifications.drain().first?.names == ["慢请求规则"])
        #expect(records.drain().records.isEmpty)
    }

    @Test func onlyMatchedRequestsNotifyAndEachWorkflowAppearsOnce() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.name = "本地 Mock"
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL + "matched")
            var mock = ModificationStep(kind: .mock); mock.value = "mock-body"
            workflow.requestSteps = [mock]
            try await h.start(workflow: workflow)
            h.proxy.ruleHitNotifications.startSession(enabled: true)
            _ = try await h.exchange("GET \(h.originURL)unmatched HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(h.proxy.ruleHitNotifications.drain().isEmpty)
            let reply = try await h.exchange("GET \(h.originURL)matched HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("mock-body"))
            #expect(h.proxy.ruleHitNotifications.drain().first?.names == ["本地 Mock"])
        }
    }

    @Test(arguments: [false, true])
    func componentRewritesUseRegexCapturesAndPreserveQuery(scripted: Bool) async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .regex, value: #"^http://unresolved\.test/(before)/([^?]+)"#)
            var host = ModificationStep(kind: .rewriteURL); host.urlRewriteTarget = .host
            host.value = "127.0.0.1:\(h.originPort)"
            var path = ModificationStep(kind: .rewriteURL); path.urlRewriteTarget = .path; path.value = "/after/$1/$2"
            workflow.requestSteps = [host, path]
            if scripted {
                var script = ModificationStep(kind: .script); script.value = "return request;"
                workflow.requestSteps.insert(script, at: 0)
            }
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("POST http://unresolved.test/before/a%2fpart?keep=%2f+%20&flag HTTP/1.1\r\nHost: unresolved.test\r\nContent-Length: 7\r\n\r\npayload")
            #expect(reply.contains("origin-body"))
            #expect(h.observation.withLock { $0.uri } == "/after/before/a%2fpart?keep=%2f+%20&flag")
            #expect(h.observation.withLock { $0.bodyBytes } == 7)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.error == nil && record.method == "POST")
            #expect(record.sentHeaders.contains { $0.name.lowercased() == "host" && $0.value == "127.0.0.1:\(h.originPort)" })
        }
    }

    @Test func templateSnapshotSpansStreamingAndScriptStages() async throws {
        for scripted in [false, true] {
            try await withHarness { h in
                var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
                var rewrite = ModificationStep(kind: .rewriteURL); rewrite.value = h.originURL + "after"
                var header = ModificationStep(kind: .setHeader); header.name = "X-Key"; header.value = "{{$randomHex}}"
                var responseHeader = ModificationStep(kind: .setHeader)
                responseHeader.headerEntries = [HeaderEntry(name: "X-Random", value: "{{$randomHex}}"),
                    HeaderEntry(name: "X-Original", value: "{{$request.url}}"),
                    HeaderEntry(name: "X-Status", value: "{{$response.status}}")]
                var status = ModificationStep(kind: .setStatus); status.status = 202
                workflow.requestSteps = [rewrite, header]; workflow.responseSteps = [status, responseHeader]
                if scripted {
                    var requestScript = ModificationStep(kind: .script); requestScript.value = "return request;"
                    var responseScript = ModificationStep(kind: .script); responseScript.value = "return response;"
                    workflow.requestSteps.insert(requestScript, at: 0); workflow.responseSteps.insert(responseScript, at: 0)
                }
                try await h.start(workflow: workflow)
                let original = h.originURL + "before"
                let reply = try await h.exchange("GET \(original) HTTP/1.1\r\nHost: localhost\r\n\r\n")
                #expect(reply.contains("202 Accepted"))
                #expect(reply.contains("X-Original: \(original)"))
                #expect(reply.contains("X-Status: 200"))
                let random = h.observation.withLock { $0.header }
                #expect(reply.contains("X-Random: \(random)"))
                #expect(random.count == 32)
                #expect(h.observation.withLock { $0.uri } == "/after")
            }
        }
    }
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
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
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
            #expect(record.requestBody.isComplete)
            #expect(record.requestBody.data == Data(body.utf8))
            #expect(record.requestBody.observedByteCount == body.utf8.count)
            #expect(record.sentBody.data == record.requestBody.data)
            #expect(record.sentBody.isComplete)
            #expect(record.receivedBody.data == Data("origin-body".utf8))
            #expect(record.responseBody.data == record.receivedBody.data)
            #expect(record.originalStatus == 200 && record.status == 202)
            #expect(record.matchedWorkflowID == workflow.id)
            #expect(record.hasSentRequestHeaders)
            #expect(record.matchedRules.map(\.kind) == [.setHeader, .setHeader, .setStatus])
            #expect(record.matchedRules.map(\.response) == [false, true, true])
            #expect(record.matchedRules.allSatisfy { $0.name == workflow.name })
            #expect(record.executionTrace.map(\.stepID) == [reqHeader.id, respHeader.id, status.id])
            #expect(record.executionTrace.map(\.phase) == [.request, .response, .response])
            #expect(record.executionTrace.allSatisfy { $0.status == .applied })
            let events = h.proxy.events.drain().events
            #expect(events.map(\.kind) == [.matched, .completed])
            #expect(events.allSatisfy { $0.transactionID == record.id && $0.workflowID == workflow.id })
        }
    }
    @Test func headerMatchingUsesOriginalRequestValues() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0].field = .url; workflow.matchConditions.conditions[0].operation = .equals; workflow.matchConditions.conditions[0].value = "\(h.originURL)headers"
            workflow.matchConditions.conditions.append(MatchCondition(field: .header, operation: .equals, name: "X-Environment", value: "staging"))
            var header = ModificationStep(kind: .setHeader); header.name = "X-Environment"; header.value = "changed"
            var status = ModificationStep(kind: .setStatus); status.status = 202
            workflow.requestSteps = [header]; workflow.responseSteps = [status]
            try await h.start(workflow: workflow)
            for (path, fields, matched) in [("headers", "", false), ("headers", "X-Environment: production\r\n", false),
                                            ("other", "X-Environment: staging\r\n", false),
                                            ("headers", "x-environment: other\r\nX-Environment: staging\r\n", true)] {
                let reply = try await h.exchange("GET \(h.originURL)\(path) HTTP/1.1\r\nHost: localhost\r\n\(fields)\r\n")
                #expect(reply.contains(matched ? "202 Accepted" : "200 OK"))
                let record = try #require(h.proxy.records.drain().records.first)
                #expect(record.matchedWorkflowID == (matched ? workflow.id : nil))
                if matched {
                    #expect(record.requestHeaders.contains { $0.name == "X-Environment" && $0.value == "staging" })
                    #expect(record.sentHeaders.contains { $0.name == "X-Environment" && $0.value == "changed" })
                }
            }
        }
    }
    @Test func groupedQueryCookieAndHeaderConditionsSelectBeforeModification() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions = WorkflowMatchGroup(conditions: [
                .init(field: .path, operation: .equals, value: "/orders"),
                .init(field: .query, operation: .equals, name: "preview", value: "true"),
                .init(field: .header, operation: .exists, name: "X-Test")], groups: [
                    WorkflowMatchGroup(mode: .any, conditions: [
                        .init(field: .cookie, operation: .equals, name: "debug", value: "1"),
                        .init(field: .header, operation: .equals, name: "X-Env", value: "staging")])])
            var status = ModificationStep(kind: .setStatus); status.status = 202
            workflow.responseSteps = [status]
            try await h.start(workflow: workflow)
            for (query, headers, matched) in [
                ("preview=true", "X-Test: 1\r\nCookie: debug=1\r\n", true),
                ("preview=false&preview=true", "X-Test: 1\r\nX-Env: staging\r\n", true),
                ("preview=false", "X-Test: 1\r\nCookie: debug=1\r\n", false),
                ("preview=true", "Cookie: debug=1\r\n", false),
                ("preview=true", "X-Test: 1\r\nCookie: debug=0\r\n", false)] {
                let reply = try await h.exchange("GET \(h.originURL)orders?\(query) HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n")
                #expect(reply.contains(matched ? "202 Accepted" : "200 OK"))
                let record = try #require(h.proxy.records.drain().records.first)
                #expect(record.matchedWorkflowID == (matched ? workflow.id : nil))
            }
        }
    }
    @Test func queryAndURLReplacementReachOriginAndCaptureFinalURL() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var query = ModificationStep(kind: .setQueryParameter)
            query.name = "q"; query.value = "中文 & value"
            var replacement = ModificationStep(kind: .replaceURLString)
            replacement.urlReplacementEntries = [
                URLReplacementEntry(search: "v1", replacement: "v2"),
                URLReplacementEntry(search: "v2", replacement: "v3")
            ]
            workflow.requestSteps = [query, replacement]
            try await h.start(workflow: workflow)
            let original = "\(h.originURL)v1/v1/search?version=v1&keep=%2f&q=old&q=duplicate"
            let reply = try await h.exchange("GET \(original) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("origin-body"))
            let path = "/v3/v3/search?version=v3&keep=%2f&q=%E4%B8%AD%E6%96%87%20%26%20value"
            #expect(h.observation.withLock { $0.uri } == path)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.url == original)
            #expect(record.finalURL == String(h.originURL.dropLast()) + path)
            #expect(record.outcome == .modified)
            #expect(record.matchedRules.map(\.kind) == [.setQueryParameter, .replaceURLString])
        }
    }
    @Test(arguments: [false, true]) func JSONEditsRequireFiniteSSEBody(replaceFirst: Bool) async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var body = ModificationStep(kind: .replaceBody); body.value = #"{"n":1}"#
            var edit = ModificationStep(kind: .modifyJSON); edit.jsonEntries = [.init(path: "n", value: "2")]
            workflow.responseSteps = replaceFirst ? [body, edit] : [edit, body]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)events HTTP/1.1\r\nHost: localhost\r\n\r\n")
            // As in the other SSE fixtures, allow asynchronous stream/connection completion before teardown.
            try await Task.sleep(for: .milliseconds(80))
            let record = try #require(h.proxy.records.drain().records.first)
            // Drain queued stream writes before the harness shuts down its event loop.
            _ = try await record.receivedStream?.readRaw(from: 0)
            _ = try await record.stream?.readRaw(from: 0)
            if replaceFirst {
                #expect(reply.hasSuffix(#"{"n":2}"#) && record.error == nil)
            } else {
                #expect(reply.contains("502") && record.error?.contains("替换 Body 之后") == true)
            }
        }
    }

    @Test func JSONEditsModifyChunkedRequestAndGzipResponse() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var request = ModificationStep(kind: .modifyJSON)
            request.jsonEntries = [.init(path: "n", value: "123")]
            var response = ModificationStep(kind: .modifyJSON)
            response.jsonEntries = [.init(operation: .modify, path: "ok", value: "false")]
            workflow.requestSteps = [request]; workflow.responseSteps = [response]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("POST \(h.originURL)encoded HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n")
            #expect(reply.hasSuffix(#"{"ok":false}"#))
            #expect(!reply.lowercased().contains("content-encoding: gzip"))
            #expect(h.observation.withLock { $0.bodyBytes } == 9)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.sentBody.data == Data(#"{"n":123}"#.utf8))
            #expect(record.receivedBody.data == Data(gzipJSONFixture))
            #expect(record.responseBody.data == Data(#"{"ok":false}"#.utf8))
            #expect(record.matchedRules.map(\.kind) == [.modifyJSON, .modifyJSON])
        }
    }

    @Test func JSONNoOpPreservesGzipAndMockFeedsResponseEdits() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var edit = ModificationStep(kind: .modifyJSON)
            edit.jsonEntries = [.init(operation: .modify, path: "missing", value: "{{$env.unused}}")]
            workflow.responseSteps = [edit]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)encoded HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.lowercased().contains("content-encoding: gzip"))
            #expect(try #require(h.proxy.records.drain().records.first).responseBody.data == Data(gzipJSONFixture))
            var mock = ModificationStep(kind: .mock); mock.value = #"{"ok":true}"#
            edit.jsonEntries = [.init(path: "ok", value: "false")]
            workflow.requestSteps = [mock]; workflow.responseSteps = [edit]
            var project = WorkflowProject(); project.workflows = [workflow]
            var document = WorkspaceDocument(); document.projects = [project]
            await h.proxy.update(document)
            let mocked = try await h.exchange("GET \(h.originURL)json-mock HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(mocked.hasSuffix(#"{"ok":false}"#))
            #expect(h.observation.withLock { $0.requests } == 1)
        }
    }

    @Test func scriptStepsModifyRealRequestAndResponseBodies() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0].field = .host
            workflow.matchConditions.conditions[0].operation = .equals; workflow.matchConditions.conditions[0].value = "127.0.0.1"
            var request = ModificationStep(kind: .script)
            request.value = "request.body = request.body.toUpperCase(); request.headers.push({name:'X-Key',value:'script-key'}); return request;"
            var response = ModificationStep(kind: .script)
            response.value = "response.body = response.body + ':' + request.body; response.status = 201; return response;"
            workflow.requestSteps = [request]; workflow.responseSteps = [response]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("POST \(h.originURL)script HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello")
            #expect(reply.contains("201 Created"))
            #expect(reply.hasSuffix("origin-body:HELLO"))
            #expect(h.observation.withLock { $0.header } == "script-key")
            #expect(h.observation.withLock { $0.bodyBytes } == 5)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.sentBody.data == Data("HELLO".utf8))
            #expect(record.responseBody.data == Data("origin-body:HELLO".utf8))
            #expect(record.matchedRules.map(\.kind) == [.script, .script])
            #expect(record.requestBody.isComplete && record.receivedBody.isComplete && record.responseBody.isComplete)
        }
    }

    @Test func scriptFetchModifiesBothLanesWithoutRecursionAndAssociatesAuxiliaryRecords() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            // Both auxiliary URLs deliberately match the same rule as the main request.
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var request = ModificationStep(kind: .script)
            request.value = """
                await Promise.resolve();
                const reply = await fetch('\(h.originURL)script-token');
                if (!reply.ok) throw new Error('token request failed');
                const token = await reply.json();
                request.headers.push({name:'X-Key',value:token.token});
                return request;
                """
            var response = ModificationStep(kind: .script)
            response.value = """
                const reply = await fetch('\(h.originURL)script-token-response');
                const token = await reply.json();
                response.body += ':' + token.token;
                response.status = 201;
                return response;
                """
            workflow.requestSteps = [request]; workflow.responseSteps = [response]
            try await h.start(workflow: workflow)

            let reply = try await h.exchange("GET \(h.originURL)script-main HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("201 Created") && reply.hasSuffix("origin-body:response-token"))
            #expect(h.observation.withLock { $0.requestURIs } == ["/script-token", "/script-main", "/script-token-response"])
            #expect(h.observation.withLock { $0.requestKeys["/script-main"] } == "request-token")
            #expect(h.observation.withLock { $0.requestKeys["/script-token"] } == "")
            #expect(h.observation.withLock { $0.requestKeys["/script-token-response"] } == "")

            let records = await terminalScriptRecords(h, count: 3)
            let parent = try #require(records.values.first { !$0.isAuxiliary })
            #expect(records.count == 3 && parent.error == nil && parent.matchedWorkflowID == workflow.id)
            #expect(parent.executionTrace.map(\.stepID) == [request.id, response.id])
            #expect(parent.executionTrace.allSatisfy { $0.status == .applied })
            #expect(parent.sentHeaders.contains(HTTPField("X-Key", "request-token")))
            #expect(parent.responseBody.data == Data("origin-body:response-token".utf8))
            let auxiliaries = records.values.filter(\.isAuxiliary)
            #expect(auxiliaries.count == 2)
            #expect(Set(auxiliaries.compactMap(\.auxiliaryStepID)) == Set([request.id, response.id]))
            #expect(Set(auxiliaries.compactMap(\.auxiliaryCallID)).count == 2)
            #expect(Set(auxiliaries.compactMap(\.auxiliaryExecutionID)).count == 2)
            for auxiliary in auxiliaries {
                #expect(auxiliary.auxiliaryParentID == parent.id && auxiliary.auxiliaryCallID == auxiliary.id)
                #expect(auxiliary.status == 200 && auxiliary.error == nil)
                #expect(auxiliary.receivedBody.isComplete && auxiliary.responseBody.isComplete)
                #expect(auxiliary.matchedWorkflowID == nil && auxiliary.matchedRules.isEmpty && auxiliary.executionTrace.isEmpty)
            }
        }
    }

    @Test(arguments: [false, true])
    func scriptFetchCancelsPendingTransportOnClientDisconnectOrCaptureStop(stopCapture: Bool) async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow()
            workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var script = ModificationStep(kind: .script)
            script.value = "await fetch('\(h.originURL)script-pending'); request.headers.push({name:'X-After-Fetch',value:'wrong'}); return request;"
            var options = ScriptOptions(); options.timeoutMilliseconds = 10_000; script.scriptOptions = options
            var following = ModificationStep(kind: .setHeader); following.name = "X-After-Script"; following.value = "wrong"
            workflow.requestSteps = [script, following]
            try await h.start(workflow: workflow)
            let collected = h.group.next().makePromise(of: String.self)
            let client = try await ClientBootstrap(group: h.group).channelInitializer { channel in
                channel.pipeline.addHandler(RawCollector(result: collected, until: nil))
            }.connect(host: "127.0.0.1", port: h.proxyPort).get()
            client.writeAndFlush(client.allocator.buffer(string:
                "GET \(h.originURL)script-cancel-main HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"), promise: nil)
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !h.observation.withLock({ $0.requestURIs.contains("/script-pending") }) && ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(h.observation.withLock { $0.requestURIs } == ["/script-pending"])

            let started = ContinuousClock.now
            if stopCapture { await h.proxy.stop() } else { try await client.close().get() }
            let records = await terminalScriptRecords(h, count: 2)
            let closeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !h.observation.withLock({ $0.closedURIs.contains("/script-pending") }) && ContinuousClock.now < closeDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(started.duration(to: .now) < .seconds(3))
            #expect(h.observation.withLock { $0.closedURIs.contains("/script-pending") })
            #expect(h.observation.withLock { $0.requestURIs } == ["/script-pending"])
            let parent = try #require(records.values.first { !$0.isAuxiliary })
            let auxiliary = try #require(records.values.first { $0.isAuxiliary })
            #expect(parent.executionTrace.map(\.stepID) == [script.id])
            #expect(parent.executionTrace.last?.status == .cancelled && parent.matchedRules.isEmpty)
            #expect(!parent.connectionState.isActive && !auxiliary.connectionState.isActive)
            #expect(auxiliary.auxiliaryParentID == parent.id && auxiliary.auxiliaryStepID == script.id)
            #expect(!auxiliary.receivedBody.isComplete && !auxiliary.responseBody.isComplete)
            #expect(auxiliary.closeReason != nil)
            _ = try await collected.futureResult.get()
            if !stopCapture {
                // Cancelling this client's script does not close the listener.
                await h.proxy.update(WorkspaceDocument())
                let reply = try await h.exchange("GET \(h.originURL)unmatched HTTP/1.1\r\nHost: localhost\r\n\r\n")
                #expect(reply.contains("200 OK") && !reply.contains("X-After-Fetch") && !reply.contains("X-After-Script"))
            }
        }
    }

    @Test func scriptFetchKeepsTransactionUpstreamSnapshotAcrossConfigurationChange() async throws {
        let replacement = Harness()
        do {
            try await replacement.prepare()
            try await withHarness { h in
                var workflow = RequestWorkflow()
                workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: "http://script-upstream.test/")
                var script = ModificationStep(kind: .script)
                script.value = """
                    const first = await fetch('http://script-upstream.test/script-gated-token');
                    await first.json();
                    const second = await fetch('http://script-upstream.test/script-token');
                    const token = await second.json();
                    request.headers.push({name:'X-Key',value:token.token});
                    return request;
                    """
                workflow.requestSteps = [script]
                var configuration = ExplicitProxyConfiguration()
                configuration.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: h.originPort))
                try await h.start(workflow: workflow, configuration: configuration)
                let request = Task { try await h.exchange("GET http://script-upstream.test/script-main HTTP/1.1\r\nHost: script-upstream.test\r\n\r\n") }
                let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                while h.observation.withLock({ $0.gatedTokenChannels.isEmpty }) && ContinuousClock.now < readyDeadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(h.observation.withLock { $0.gatedTokenChannels.count } == 1)
                configuration.port = h.proxyPort
                configuration.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: replacement.originPort))
                try await h.proxy.updateConfiguration(configuration)
                try await h.releaseGatedTokenResponses()
                let reply = try await request.value
                #expect(reply.contains("200 OK"))
                #expect(h.observation.withLock { $0.requestURIs } == [
                    "http://script-upstream.test/script-gated-token", "http://script-upstream.test/script-token", "http://script-upstream.test/script-main"])
                #expect(h.observation.withLock { $0.requestKeys["http://script-upstream.test/script-main"] } == "request-token")
                #expect(replacement.observation.withLock { $0.requests } == 0)
                let records = await terminalScriptRecords(h, count: 3)
                #expect(records.count == 3 && records.values.allSatisfy { $0.error == nil })
                let parent = try #require(records.values.first { !$0.isAuxiliary })
                // Streaming responses may use chunked framing in the raw TCP collector.
                #expect(parent.responseBody.data == Data("origin-body".utf8) && parent.responseBody.isComplete)

                let next = try await h.exchange("GET http://next-upstream.test/new HTTP/1.1\r\nHost: next-upstream.test\r\n\r\n")
                #expect(next.contains("200 OK"))
                #expect(replacement.observation.withLock { $0.requestURIs } == ["http://next-upstream.test/new"])
                #expect(h.observation.withLock { $0.requests } == 3)
            }
            await replacement.shutdown()
        } catch { await replacement.shutdown(); throw error }
    }

    @Test func scriptTimeoutFailsBeforeForwardingAndMockScriptsStillRun() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var script = ModificationStep(kind: .script); script.value = "while(true) {}"
            var options = ScriptOptions(); options.timeoutMilliseconds = 150; script.scriptOptions = options
            workflow.requestSteps = [script]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)timeout HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("400 Bad Request"))
            #expect(h.observation.withLock { $0.requests } == 0)
            let failed = try #require(h.proxy.records.drain().records.first)
            #expect(failed.outcome == .failed && failed.matchedRules.isEmpty)
            var mock = ModificationStep(kind: .mock); mock.value = "local"
            script.value = "response.body += '-script'; return response;"; script.scriptOptions = nil
            workflow.requestSteps = [mock]; workflow.responseSteps = [script]
            var project = WorkflowProject(); project.workflows = [workflow]
            var document = WorkspaceDocument(); document.projects = [project]
            await h.proxy.update(document)
            let mocked = try await h.exchange("GET \(h.originURL)mock-script HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(mocked.hasSuffix("local-script"))
            #expect(h.observation.withLock { $0.requests } == 0)
        }
    }
    @Test func scriptKeepsCompressedBytesAndBuffersChunkedInput() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var request = ModificationStep(kind: .script); request.value = "request.body += '-script'; return request;"
            var response = ModificationStep(kind: .script); response.value = "response.headers.push({name:'X-Script', value:String(response.body)}); return response;"
            workflow.requestSteps = [request]; workflow.responseSteps = [response]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("POST \(h.originURL)encoded HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
            #expect(reply.lowercased().contains(#"x-script: {"ok":true}"#))
            #expect(reply.lowercased().contains("content-encoding: gzip"))
            #expect(h.observation.withLock { $0.bodyBytes } == 10)
            let preserved = try #require(h.proxy.records.drain().records.first)
            #expect(preserved.responseBody.data == Data(gzipJSONFixture))
            response.value = "const body = JSON.parse(response.body); body.ok = false; response.body = JSON.stringify(body); return response;"
            workflow.responseSteps = [response]
            var project = WorkflowProject(); project.workflows = [workflow]
            var document = WorkspaceDocument(); document.projects = [project]
            await h.proxy.update(document)
            let changed = try await h.exchange("GET \(h.originURL)encoded HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(changed.hasSuffix(#"{"ok":false}"#))
            #expect(!changed.lowercased().contains("content-encoding"))
        }
    }
    @Test func mockSkipsOriginAndResponseLaneStillRuns() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var mock = ModificationStep(kind: .mock); mock.value = "local-static"; mock.status = 201
            var header = ModificationStep(kind: .setHeader); header.name = "X-Response-Flow"; header.value = "yes"
            workflow.requestSteps = [mock]; workflow.responseSteps = [header]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL)mock HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("201 Created")); #expect(reply.contains("local-static")); #expect(reply.contains("X-Response-Flow: yes"))
            #expect(h.observation.withLock { $0.requests } == 0)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.outcome == .mocked)
            #expect(!record.hasSentRequestHeaders)
            #expect(record.matchedRules.map(\.kind) == [.mock, .setHeader])
            #expect(record.sentBody.state == .unavailable && record.receivedBody.state == .unavailable)
            #expect(record.responseBody.isComplete && record.responseBody.data == Data("local-static".utf8))
        }
    }
    @Test func responseReplacementRepairsEncodingAndHeadHasNoBody() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
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
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            var step = ModificationStep(kind: .setHeader); step.name = "X-Key"; step.value = "{{env.missing}}"
            var first = ModificationStep(kind: .setHeader); first.name = "X-First"; first.value = "ok"
            workflow.requestSteps = [first, step]
            try await h.start(workflow: workflow)
            let reply = try await h.exchange("GET \(h.originURL) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.contains("400 Bad Request")); #expect(h.observation.withLock { $0.requests } == 0)
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.outcome == .failed)
            #expect(record.executionTrace.map(\.stepID) == [first.id, step.id])
            #expect(record.executionTrace.map(\.status) == [.applied, .failed])
            #expect(record.steps == [first.kind.title])
            #expect(h.proxy.events.drain().events.map(\.kind) == [.matched, .failed])
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
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
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
    @Test func largeHeadersURLsAndGeneratedBodiesRemainComplete() async throws {
        try await withHarness { h in
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
            let body = String(repeating: "b", count: 2 * 1_048_576)
            var mock = ModificationStep(kind: .mock); mock.value = body
            var header = ModificationStep(kind: .setHeader); header.name = "X-Large"; header.value = String(repeating: "h", count: 100_000)
            workflow.requestSteps = [mock]; workflow.responseSteps = [header]
            try await h.start(workflow: workflow)
            let url = h.originURL + String(repeating: "path", count: 1_024)
            let auth = "Bearer " + String(repeating: "a", count: 100_000)
            let headers = (0..<150).map { "X-\($0): value\r\n" }.joined()
            let reply = try await h.exchange("GET \(url) HTTP/1.1\r\nHost: localhost\r\nAuthorization: \(auth)\r\n" + headers + "\r\n")
            #expect(reply.hasSuffix(body))
            #expect(reply.contains("X-Large: " + header.value))
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.url == url && !record.urlWasTruncated)
            #expect(record.requestHeaders.count == 153 && !record.requestHeadersInfo.isTruncated)
            #expect(record.requestHeaders.first { $0.name == "Authorization" }?.value == auth)
            #expect(record.responseBody.isComplete && record.responseBody.data == Data(body.utf8))
            #expect(h.observation.withLock { $0.requests } == 0)
        }
    }
    @Test func largeUpstreamHeadersAreForwardedAndCapturedWithoutMasking() async throws {
        try await withHarness { h in
            try await h.start()
            let reply = try await h.exchange("GET \(h.originURL)large-headers HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let cookie = "session=" + String(repeating: "c", count: 100_000)
            #expect(reply.contains("Set-Cookie: " + cookie))
            #expect(reply.contains("origin-body"))
            let record = try #require(h.proxy.records.drain().records.first)
            #expect(record.receivedHeaders.count > 128)
            #expect(record.receivedHeaders.first { $0.name == "Set-Cookie" }?.value == cookie)
            #expect(record.responseBody.data == Data("origin-body".utf8))
            #expect(record.responseHeaders.first { $0.name == "Set-Cookie" }?.value == cookie)
            #expect(!record.receivedHeadersInfo.isTruncated && !record.responseHeadersInfo.isTruncated)
        }
    }
    @Test func largeResponseStreamsAllBytesAndRedirectDoesNotReflectCredentials() async throws {
        try await withHarness { h in
            try await h.start()
            let reply = try await h.exchange("GET \(h.originURL)large HTTP/1.1\r\nHost: localhost\r\n\r\n")
            #expect(reply.filter { $0 == "z" }.count == 1_048_576)
            #expect(h.proxy.records.drain().records.first?.responseBytes == 1_048_576)
            var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: h.originURL)
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
        var workflow = RequestWorkflow(); workflow.matchConditions.conditions[0] = MatchCondition(field: .url, operation: .beginsWith, value: "http://example.test/")
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

private struct OriginObservation {
    var requests = 0; var header = ""; var bodyBytes = 0; var uri = ""; var closedConnections = 0
    var requestURIs: [String] = []
    var requestKeys: [String: String] = [:]
    var closedURIs: [String] = []
    var gatedTokenChannels: [Channel] = []
}
private final class Harness: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let proxy: LocalProxyServer
    init(certificateProvider: (any TLSCertificateProviding)? = nil) { proxy = LocalProxyServer(certificateProvider: certificateProvider) }
    let observation = OSAllocatedUnfairLock(initialState: OriginObservation())
    var origin: Channel?
    var originPort = 0
    var proxyPort = 0
    var originURL: String { "http://127.0.0.1:\(originPort)/" }
    func prepare() async throws {
        let observation = observation
        origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                // Keep reading FIN while the fixture's SSE response remains open.
                // Pipelining assistance otherwise suspends reads until response end.
                try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
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
    func exchange(_ request: String, until: String? = nil, timeout: TimeAmount = .seconds(4), host: String = "127.0.0.1") async throws -> String {
        // This raw fixture collects until EOF; explicitly opt out of persistence.
        let request = request.hasPrefix("CONNECT ") ? request : request.replacingOccurrences(
            of: "HTTP/1.1\r\n", with: "HTTP/1.1\r\nConnection: close\r\n")
        let promise = group.next().makePromise(of: String.self)
        let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
            channel.pipeline.addHandler(RawCollector(result: promise, until: until))
        }.connect(host: host, port: proxyPort).get()
        let timeout = channel.eventLoop.scheduleTask(in: timeout) { channel.close(promise: nil) }
        channel.writeAndFlush(channel.allocator.buffer(string: request), promise: nil)
        do { let reply = try await promise.futureResult.get(); timeout.cancel(); try? await channel.close().get(); return reply }
        catch { timeout.cancel(); try? await channel.close().get(); throw error }
    }
    func releaseGatedTokenResponses() async throws {
        let channels = observation.withLock { state in
            let channels = state.gatedTokenChannels
            state.gatedTokenChannels = []
            return channels
        }
        for channel in channels {
            try await channel.eventLoop.submit {
                let body = #"{"token":"gated-token"}"#
                channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok,
                    headers: HTTPHeaders([("Content-Type", "application/json"), ("Content-Length", String(body.utf8.count)), ("Connection", "close")]))), promise: nil)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(string: body))), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
            }.get()
        }
    }
    func shutdown() async { await proxy.stop(); try? await origin?.close().get(); try? await group.shutdownGracefully() }
}
private func withHarness(_ body: (Harness) async throws -> Void) async throws {
    let h = Harness()
    do { try await h.prepare(); try await body(h); await h.shutdown() }
    catch { await h.shutdown(); throw error }
}
private func terminalScriptRecords(_ h: Harness, count: Int) async -> [UUID: CaptureRecord] {
    var records: [UUID: CaptureRecord] = [:]
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    repeat {
        for record in h.proxy.records.drain().records { records[record.id] = record }
        if records.count >= count && records.values.allSatisfy({
            !$0.connectionState.isActive && ($0.isAuxiliary || !$0.executionTrace.isEmpty)
        }) { break }
        try? await Task.sleep(for: .milliseconds(5))
    } while ContinuousClock.now < deadline
    return records
}
private final class OriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    let observation: OSAllocatedUnfairLock<OriginObservation>
    var method = HTTPMethod.GET
    var uri = ""
    init(observation: OSAllocatedUnfairLock<OriginObservation>) { self.observation = observation }
    func channelInactive(context: ChannelHandlerContext) {
        observation.withLock { $0.closedConnections += 1; $0.closedURIs.append(uri) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            method = head.method; uri = head.uri
            observation.withLock {
                $0.requests += 1; $0.header = head.headers.first(name: "X-Key") ?? ""; $0.uri = head.uri
                $0.requestURIs.append(head.uri); $0.requestKeys[head.uri] = $0.header
            }
        case .body(let bytes): observation.withLock { $0.bodyBytes += bytes.readableBytes }
        case .end:
            let channel = context.channel
            if uri.hasSuffix("/script-pending") { return }
            if uri.hasSuffix("/script-gated-token") {
                observation.withLock { $0.gatedTokenChannels.append(channel) }
                return
            }
            if uri.hasSuffix("/events") {
                channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok,
                    headers: HTTPHeaders([("Content-Type", "text/event-stream"), ("Transfer-Encoding", "chunked")]))), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(channel.allocator.buffer(string: "data: origin\n\n"))), promise: nil)
                return
            }
            let body: String
            if uri.hasSuffix("/script-token") { body = #"{"token":"request-token"}"# }
            else if uri.hasSuffix("/script-token-response") { body = #"{"token":"response-token"}"# }
            else { body = uri.hasSuffix("/large") ? String(repeating: "z", count: 1_048_576) : "origin-body" }
            let bytes = uri.hasSuffix("/encoded") ? gzipJSONFixture : Array(body.utf8)
            let interrupted = uri.hasSuffix("/interrupted")
            var headers = HTTPHeaders([("Content-Length", String(bytes.count + (interrupted ? 32 : 0))), ("Connection", "close")])
            if uri.hasPrefix("/captured?") {
                headers.add(name: "Content-Type", value: "text/plain")
            }
            if uri.hasSuffix("/large-headers") {
                headers.add(name: "Set-Cookie", value: "session=" + String(repeating: "c", count: 100_000))
                for index in 0..<150 { headers.add(name: "X-\(index)", value: "value") }
            }
            if uri.hasSuffix("/encoded") {
                headers.add(name: "Content-Encoding", value: "gzip")
                headers.add(name: "Content-Type", value: "application/json")
            }
            if uri.hasSuffix("/script-token") || uri.hasSuffix("/script-token-response") {
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

private struct MobilePublicCertificate: TLSCertificateProviding {
    let data: Data
    func serverIdentity(for host: String) async throws -> TLSCertificateIdentity? { nil }
    func publicCertificateDER() async throws -> Data? { data }
}
