import Foundation
import Testing
@testable import RequestmanCore

struct CaptureBodySnapshotTests {
    @Test func emptyIncompleteEncodedAndTruncatedRemainDistinct() {
        let empty = CaptureBodyCollector().snapshot(isComplete: true)
        #expect(empty.state == .complete)
        #expect(empty.data.isEmpty && empty.observedByteCount == 0 && !empty.isTruncated)
        let incomplete = CaptureBodyCollector().snapshot(isComplete: false)
        #expect(incomplete.state == .incomplete)
        let collector = CaptureBodyCollector(headers: [HTTPField("Content-Encoding", "gzip")], maximumBytes: 3)
        collector.append(Array("abcdef".utf8))
        let truncated = collector.snapshot(isComplete: true)
        #expect(truncated.isEncoded && truncated.isTruncated)
        #expect(!truncated.isComplete)
        #expect(truncated.observedByteCount == 6)
        #expect(truncated.data == Data("abc".utf8))
        #expect(CaptureBodySnapshot.notCollected.state == .notCollected)
        #expect(CaptureBodySnapshot.unavailable("没有上游").state == .unavailable)
    }

    @Test func previewBudgetFollowsSnapshotsAndPreservesPrefixAfterExhaustion() {
        let budget = CaptureBodyBudget(capacity: 5)
        func makeSnapshot() -> CaptureBodySnapshot {
            let collector = CaptureBodyCollector(budget: budget)
            collector.append(Array("abc".utf8))
            return collector.snapshot(isComplete: true)
        }
        var retained = makeSnapshot()
        #expect(budget.usedByteCount == 3)
        let collector = CaptureBodyCollector(budget: budget)
        collector.append(Array("defg".utf8))
        #expect(budget.usedByteCount == 5)
        retained = .notCollected
        #expect(retained.state == .notCollected)
        #expect(budget.usedByteCount == 2)
        collector.append(Array("hijk".utf8))
        let snapshot = collector.snapshot(isComplete: true)
        #expect(snapshot.data == Data("de".utf8))
        #expect(snapshot.observedByteCount == 8 && snapshot.isTruncated)
        #expect(budget.usedByteCount == 2)
        collector.append(Array("cannot-change-a-retained-snapshot".utf8))
        #expect(snapshot.data == Data("de".utf8))
    }

    @Test func repeatedSnapshotCannotPromoteAnIncompleteBody() {
        let budget = CaptureBodyBudget(capacity: 32)
        let collector = CaptureBodyCollector(budget: budget)
        collector.append(Array("partial".utf8))
        let first = collector.snapshot(isComplete: false)
        collector.append(Array("-later".utf8))
        let second = collector.snapshot(isComplete: true)
        #expect(first.state == .incomplete && second.state == .incomplete)
        #expect(first.data == second.data && second.data == Data("partial".utf8))
        #expect(second.observedByteCount == 7 && budget.usedByteCount == 7)
    }

    @Test func queueEvictionDrainAndHistoryRemovalReleaseSmallBodyBudget() {
        let budget = CaptureBodyBudget(capacity: 16_384)
        let buffer = CaptureRecordBuffer()
        for _ in 0..<1000 {
            let collector = CaptureBodyCollector(budget: budget)
            collector.append(Array(repeating: UInt8(1), count: 16))
            var record = CaptureRecord(method: "GET", url: "https://example.test/")
            record.responseBody = collector.snapshot(isComplete: true)
            buffer.append(record)
        }
        #expect(budget.usedByteCount == 256 * 16)
        var history = buffer.drain().records
        #expect(history.count == 64 && budget.usedByteCount == 256 * 16)
        buffer.clear()
        #expect(budget.usedByteCount == 64 * 16)
        history.removeAll()
        #expect(budget.usedByteCount == 0)
    }

    @Test func metadataRedactionAndTruncationAreExplicitAndIdempotent() {
        var record = CaptureRecord(method: "GET", url: "http://localhost/" + String(repeating: "x", count: 2048))
        record.requestHeaders = [HTTPField("Authorization", "secret"), HTTPField("X-Long", String(repeating: "x", count: 300))]
            + (0..<40).map { HTTPField("X-\($0)", "value") }
        let bounded = record.bounded().bounded()
        #expect(bounded.urlWasTruncated && bounded.finalURLWasTruncated)
        #expect(bounded.requestHeaders.count == 40)
        #expect(bounded.requestHeadersInfo.originalCount == 42)
        #expect(bounded.requestHeadersInfo.isTruncated)
        #expect(bounded.requestHeadersInfo.redactedNames == ["authorization"])
        #expect(bounded.requestHeadersInfo.truncatedNames == ["x-long"])
        #expect(bounded.requestHeaders.first?.value == "••••••")
    }
}
