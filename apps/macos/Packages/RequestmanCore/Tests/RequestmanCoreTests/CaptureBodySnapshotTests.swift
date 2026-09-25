import Foundation
import Testing
@testable import RequestmanCore

struct CaptureBodySnapshotTests {
    @Test func emptyIncompleteEncodedAndUnavailableRemainDistinct() {
        let empty = CaptureBodyCollector().snapshot(isComplete: true)
        #expect(empty.isComplete && empty.data.isEmpty && empty.observedByteCount == 0)
        #expect(CaptureBodyCollector().snapshot(isComplete: false).state == .incomplete)
        let collector = CaptureBodyCollector(headers: [HTTPField("Content-Encoding", "gzip")])
        collector.append(Array("abcdef".utf8))
        let snapshot = collector.snapshot(isComplete: true)
        #expect(snapshot.isEncoded && snapshot.isComplete)
        #expect(snapshot.data == Data("abcdef".utf8))
        #expect(CaptureBodySnapshot.notCollected.state == .notCollected)
        #expect(CaptureBodySnapshot.unavailable("没有上游").state == .unavailable)
    }

    @Test func capturesBeyondFormerPerBodyAndSharedBudgets() {
        let chunk = Data(repeating: 0x61, count: 1_048_576)
        let collector = CaptureBodyCollector()
        for _ in 0..<33 { collector.append(chunk) }
        let snapshot = collector.snapshot(isComplete: true)
        #expect(snapshot.isComplete && snapshot.data.count == 33 * chunk.count)
        #expect(snapshot.observedByteCount == snapshot.data.count)
        #expect(snapshot.data.suffix(chunk.count) == chunk)
        let other = CaptureBodyCollector()
        other.append(chunk)
        #expect(other.snapshot(isComplete: true).data == chunk)
        #expect(snapshot.data.count == 33 * chunk.count)
    }

    @Test func repeatedSnapshotCannotPromoteAnIncompleteBody() {
        let collector = CaptureBodyCollector()
        collector.append(Array("partial".utf8))
        let first = collector.snapshot(isComplete: false)
        collector.append(Array("-later".utf8))
        let second = collector.snapshot(isComplete: true)
        #expect(first.state == .incomplete && second.state == .incomplete)
        #expect(first.data == second.data && second.data == Data("partial".utf8))
        #expect(second.observedByteCount == 7)
    }

    @Test func completeURLsHeadersAndCredentialsSurviveRepeatedRecording() {
        let url = "https://example.test/" + String(repeating: "x", count: 8_192)
        let longValue = String(repeating: "v", count: 100_000) + "-tail"
        let longName = "X-" + String(repeating: "n", count: 256)
        let headers = [HTTPField("Authorization", "Bearer secret"), HTTPField("Proxy-Authorization", "Basic proxy"),
                       HTTPField("X-API-Key", "key"), HTTPField("Cookie", "session=secret"),
                       HTTPField("Set-Cookie", "session=new"), HTTPField(longName, longValue)]
            + (0..<150).map { HTTPField("X-\($0)", "value") }
        var record = CaptureRecord(method: "GET", url: url)
        record.requestHeaders = headers; record.sentHeaders = headers
        record.receivedHeaders = headers; record.responseHeaders = headers
        let copy = record.bounded().bounded()
        #expect(copy.url == url && copy.finalURL == url && !copy.urlWasTruncated && !copy.finalURLWasTruncated)
        #expect(copy.requestHeaders == headers && copy.sentHeaders == headers)
        #expect(copy.receivedHeaders == headers && copy.responseHeaders == headers)
        for info in [copy.requestHeadersInfo, copy.sentHeadersInfo, copy.receivedHeadersInfo, copy.responseHeadersInfo] {
            #expect(info.originalCount == headers.count && !info.isTruncated && info.truncatedNames.isEmpty)
        }
    }
}
