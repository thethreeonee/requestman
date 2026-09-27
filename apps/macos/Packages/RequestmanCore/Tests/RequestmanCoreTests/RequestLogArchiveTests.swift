import Foundation
import Testing
@testable import RequestmanCore

struct RequestLogArchiveTests {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("requestman-log-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder.appendingPathComponent("session.requestmanlog.json")
    }
    private func cleanup(_ url: URL) { _ = try? FileManager.default.trashItem(at: url.deletingLastPathComponent(), resultingItemURL: nil) }
    private func body(_ data: Data, complete: Bool = true, headers: [HTTPField] = []) -> CaptureBodySnapshot {
        let collector = CaptureBodyCollector(headers: headers); collector.append(data)
        return collector.snapshot(isComplete: complete)
    }
    @Test func readableJSONPreservesOriginalAndFinalBytesHeadersAndTrace() async throws {
        let url = try temporaryFile(); defer { cleanup(url) }
        var record = CaptureRecord(method: "POST", url: "https://example.test/a?q=1&q=2")
        record.startedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        record.sentMethod = "PUT"; record.finalURL = "https://example.test/b"
        record.project = "登录"; record.workflow = "修改结果"; record.environment = "开发"
        record.matchedWorkflowID = UUID(); record.status = 201; record.originalStatus = 200
        record.outcome = .modified; record.hasSentRequestHeaders = true; record.duration = 0.125
        record.requestHeaders = [.init("X-Item", " one "), .init("X-Item", "two"), .init("Authorization", "Bearer test-token")]
        record.sentHeaders = [.init("X-Item", "changed")]
        record.receivedHeaders = [.init("Set-Cookie", "a=1"), .init("Set-Cookie", "b=2")]
        record.responseHeaders = [.init("Content-Type", "application/json")]
        record.requestBody = body(Data("{\"name\":\"你好\",\"number\":12345678901234567890}".utf8))
        record.sentBody = body(Data([0, 255, 1, 10]))
        record.receivedBody = .unavailable("上游正文不可用")
        record.responseBody = body(Data("unfinished".utf8), complete: false)
        record.requestHeadersInfo.originalCount = 3
        record.requestHeadersInfo.truncatedNames = ["legacy"]
        record.matchedRules = [.init(kind: .replaceBody, name: "替换", response: true)]
        record.executionTrace = [.init(stepID: UUID(), kind: .replaceBody, phase: .response,
                                       elapsed: .nanoseconds(123456), status: .failed, error: "fixture")]
        record.steps = ["执行失败"]; record.error = "fixture error"
        try await RequestLogArchive.write([record], to: url)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["format"] as? String == "requestman.log")
        #expect(json["version"] as? Int == 1)
        let entries = try #require(json["records"] as? [[String: Any]])
        let saved = try #require(entries.first?["record"] as? [String: Any])
        let requestBody = try #require(saved["requestBody"] as? [String: Any])
        #expect((requestBody["payload"] as? [String: String])?["text"]?.contains("你好") == true)
        let sentBody = try #require(saved["sentBody"] as? [String: Any])
        #expect((sentBody["payload"] as? [String: String])?["base64"] == Data([0, 255, 1, 10]).base64EncodedString())
        let loaded = try #require(RequestLogArchive.read(from: url).records.first)
        #expect(loaded.id == record.id && loaded.startedAt == record.startedAt && loaded.archivedAt != nil)
        #expect(loaded.requestHeaders == record.requestHeaders && loaded.receivedHeaders == record.receivedHeaders)
        #expect(loaded.sentHeaders == record.sentHeaders && loaded.responseHeaders == record.responseHeaders)
        #expect(loaded.requestBody.data == record.requestBody.data && loaded.sentBody.data == record.sentBody.data)
        #expect(loaded.responseBody.state == .incomplete && loaded.responseBody.data == record.responseBody.data)
        #expect(loaded.receivedBody.unavailableReason == "上游正文不可用")
        #expect(loaded.executionTrace.first?.elapsed == record.executionTrace.first?.elapsed)
        #expect(loaded.executionTrace.first?.status == .failed && loaded.matchedRules == record.matchedRules)
        #expect(loaded.requestHeadersInfo.truncatedNames == ["legacy"])
        var normalized = loaded; normalized.archivedAt = nil
        #expect(try RequestLogArchive.encoder().encode(normalized) == RequestLogArchive.encoder().encode(record))
    }
    @Test func compressedBodyIncludesReadableTextWithoutChangingBytes() async throws {
        let url = try temporaryFile(); defer { cleanup(url) }
        let bytes = Data([31,139,8,0,0,0,0,0,2,255,75,73,44,73,180,82,120,218,215,253,124,207,202,39,187,186,159,236,222,198,197,5,0,232,117,142,64,20,0,0,0])
        var record = CaptureRecord(method: "GET", url: "https://example.test/")
        record.responseBody = body(bytes, headers: [.init("Content-Encoding", "gzip")])
        try await RequestLogArchive.write([record], to: url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("压缩事件"))
        let restored = try #require(RequestLogArchive.read(from: url).records.first)
        #expect(restored.responseBody.data == bytes && restored.responseBody.contentEncoding == "gzip")
    }
    @Test func streamSnapshotIncludesAllPagesAndPartialRawWithoutFollowingLaterAppends() async throws {
        let url = try temporaryFile(); defer { cleanup(url) }
        let stream = CaptureStreamStore()
        var raw = Data()
        for index in 0..<205 {
            let chunk = Data("id: \(index)\ndata: 事件\(index)\n\n".utf8); raw.append(chunk)
            await withCheckedContinuation { done in stream.appendSSE(chunk) { done.resume() } }
        }
        let tail = Data("data: 未完成".utf8); raw.append(tail)
        await withCheckedContinuation { done in stream.appendSSE(tail) { done.resume() } }
        let snapshot = try await stream.archiveSnapshot()
        await withCheckedContinuation { done in stream.appendSSE(Data("\n\n".utf8)) { done.resume() } }
        let frozen = try snapshot.contents()
        #expect(frozen.messages.count == 205 && frozen.raw.data == raw)
        var record = CaptureRecord(method: "POST", url: "https://example.test/events")
        record.captureProtocol = .sse; record.connectionState = .open
        record.stream = stream; record.receivedStream = stream
        record.replayID = record.id; record.replaySourceID = UUID()
        try await RequestLogArchive.write([record], to: url)
        let restored = try #require(RequestLogArchive.read(from: url).records.first)
        #expect(restored.stream === restored.receivedStream)
        let restoredStream = try #require(restored.stream)
        #expect(try await restoredStream.read(from: 200).count == 6)
        #expect(try await restoredStream.readRaw(from: 0, limit: 100_000) == raw + Data("\n\n".utf8))
        #expect(restored.connectionState == .open && restored.connectionSummary == "保存时：接收中")
        #expect(restored.replaySummary == "保存时重放尚未完成")
    }
    @Test func websocketDirectionsBinaryAndStoreErrorsRoundTrip() async throws {
        let url = try temporaryFile(); defer { cleanup(url) }
        let stream = CaptureStreamStore()
        for message in [CaptureStreamMessage(direction: .sent, kind: "文本", data: Data("hello".utf8)),
                        CaptureStreamMessage(direction: .received, kind: "二进制", data: Data([255, 0, 1]))] {
            await withCheckedContinuation { done in stream.append(message) { done.resume() } }
        }
        stream.recordError("fixture disk error")
        var record = CaptureRecord(method: "GET", url: "https://example.test/ws")
        record.captureProtocol = .webSocket; record.stream = stream; record.closeReason = "1000 完成"
        try await RequestLogArchive.write([record], to: url)
        let loaded = try #require(RequestLogArchive.read(from: url).records.first?.stream)
        let messages = try await loaded.read(from: 0)
        #expect(messages.map(\.direction) == [.sent, .received])
        #expect(messages.last?.data == Data([255, 0, 1]) && loaded.summary.error == "fixture disk error")
    }
    @Test func unknownVersionBrokenFileDuplicateIDsAndInvalidPayloadAreRejected() async throws {
        let url = try temporaryFile(); defer { cleanup(url) }
        let record = CaptureRecord(method: "GET", url: "https://example.test/")
        try await RequestLogArchive.write([record], to: url)
        let original = try Data(contentsOf: url)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["version"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: (any Error).self) { try RequestLogArchive.read(from: url) }
        object["version"] = 1
        let entries = try #require(object["records"] as? [[String: Any]])
        object["records"] = entries + entries
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: (any Error).self) { try RequestLogArchive.read(from: url) }
        try original.prefix(original.count / 2).write(to: url)
        #expect(throws: (any Error).self) { try RequestLogArchive.read(from: url) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LogPayload.self, from: Data("{\"base64\":\"%%%\"}".utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LogPayload.self, from: Data("{\"text\":\"x\",\"base64\":\"eA==\"}".utf8)) }
    }
    @Test func orderMoreThanLiveLimitAndFailedOverwrite() async throws {
        let url = try temporaryFile(); defer { cleanup(url) }
        let records = (0..<510).map { CaptureRecord(method: "GET", url: "https://example.test/\($0)") }
        try await RequestLogArchive.write(records, to: url)
        #expect(try RequestLogArchive.read(from: url).records.map(\.id) == records.map(\.id))
        let original = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) { try await RequestLogArchive.write([records[0], records[0]], to: url) }
        #expect(try Data(contentsOf: url) == original)
        var invalid = records[0]; invalid.duration = .nan
        await #expect(throws: (any Error).self) { try await RequestLogArchive.write([records[1], invalid], to: url) }
        #expect(try Data(contentsOf: url) == original, "A failure after a partial temporary write must preserve the original")
    }
}
