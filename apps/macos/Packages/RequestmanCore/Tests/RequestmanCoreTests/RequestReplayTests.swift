import Foundation
import Testing
@testable import RequestmanCore

struct RequestReplayTests {
    @Test func originalSnapshotKeepsBinaryAndDuplicateHeaders() throws {
        var record = CaptureRecord(method: "POST", url: "https://example.test/original?q=1&q=2")
        record.sentMethod = "DELETE"; record.finalURL = "https://example.test/modified"
        record.requestHeaders = [HTTPField("X-Test", "one"), HTTPField("X-Test", "two"), HTTPField("Content-Encoding", "gzip"),
            HTTPField("Host", "old.test"), HTTPField("Content-Length", "99"), HTTPField("Connection", "X-Hop"), HTTPField("X-Hop", "omit")]
        let bytes = Data([0, 255, 13, 10, 9])
        let body = CaptureBodyCollector(); body.append(bytes); record.requestBody = body.snapshot(isComplete: true)
        let draft = try RequestReplayDraft(record: record)
        #expect(draft.sourceRecordID == record.id && draft.id != record.id)
        #expect(draft.method == "POST" && draft.url == record.url && draft.body == bytes)
        #expect(draft.headers.map(\.name) == ["X-Test", "X-Test", "Content-Encoding"])
        #expect(draft.headers.map(\.value) == ["one", "two", "gzip"])
    }
    @Test func replayBypassesPauseButRespectsClearGeneration() {
        let buffer = CaptureRecordBuffer()
        buffer.setPaused(true)
        var replay = CaptureRecord(method: "GET", url: "http://example.test/")
        replay.replayID = replay.id; replay.replaySourceID = UUID(); replay.connectionState = .open
        let generation = buffer.generation
        buffer.append(CaptureRecord(method: "GET", url: "http://ordinary.test/"))
        buffer.append(replay, generation: generation)
        #expect(buffer.drain().records.map(\.id) == [replay.id])
        replay.connectionState = .closed; replay.status = 500
        buffer.append(replay, generation: generation)
        #expect(buffer.drain().records.first?.replaySummary == "重放已完成 · HTTP 500")
        buffer.clear()
        buffer.append(replay, generation: generation)
        #expect(buffer.drain().records.isEmpty)
        replay.replayCancelled = true
        #expect(replay.replaySummary == "重放已取消")
        replay.replayCancelled = false; replay.error = "上游失败"
        #expect(replay.replaySummary == "重放失败：上游失败")
    }

    @Test func incompleteAndUnsupportedRequestsAreUnavailable() {
        var record = CaptureRecord(method: "GET", url: "https://example.test/")
        #expect(RequestReplayDraft.unavailableReason(for: record) != nil)
        record.requestBody = CaptureBodyCollector().snapshot(isComplete: true)
        #expect(RequestReplayDraft.unavailableReason(for: record) == nil)
        record.captureProtocol = .webSocket
        #expect(RequestReplayDraft.unavailableReason(for: record) != nil)
        record.captureProtocol = .http; record.urlWasTruncated = true
        #expect(RequestReplayDraft.unavailableReason(for: record) != nil)
        record.urlWasTruncated = false; record.requestHeadersInfo.originalCount = 1
        #expect(RequestReplayDraft.unavailableReason(for: record) != nil)
    }
    @Test func editedInputRejectsInjectionAndMaintainsRepeatedFields() throws {
        #expect(throws: (any Error).self) { try RequestReplayDraft.parseHeaders("Content-Length: 1") }
        #expect(throws: (any Error).self) { try RequestReplayDraft.parseHeaders("Bad Header: value") }
        #expect(throws: (any Error).self) { try RequestReplayDraft.parseHeaders("not-a-header") }
        #expect(try RequestReplayDraft.parseHeaders("X-Test: a:b\nX-Test: \n").map(\.value) == ["a:b", ""])
        for url in ["file:///tmp/a", "https://user:pass@example.test/", "https://example.test/#fragment", "https://example.test:99999/", "https://example.test/\r\nX: y"] {
            #expect(throws: (any Error).self) { try RequestReplayDraft(method: "GET", url: url, headers: [], body: Data()).validate() }
        }
    }
}
