import Foundation
import Testing
@testable import RequestmanCore

struct CaptureStreamTests {
    @Test func parsesSplitUTF8LinesAndPersistentIDs() {
        var parser = SSEParser()
        let input = Data("\u{feff}: heartbeat\r\nid: 42\revent: update\ndata: 你好\r\ndata: world\r\n\r\ndata: next\n\nretry: 123\nid: bad\0id\n\ndata: unfinished".utf8)
        var events: [(String, String, String)] = []
        for byte in input { parser.append(Data([byte])) { events.append(($0, $1, String(decoding: $2, as: UTF8.self))) } }
        #expect(events.count == 2)
        #expect(events[0].0 == "update" && events[0].1 == "42" && events[0].2 == "你好\nworld")
        #expect(events[1].0 == "message" && events[1].1 == "42" && events[1].2 == "next")
        #expect(parser.retryMilliseconds == 123)
    }
    @Test func storePagesRetainFullContentAndCanContinueAfterRead() async throws {
        let store = CaptureStreamStore()
        for i in 0..<205 {
            await withCheckedContinuation { done in store.appendSSE(Data("id: \(i)\ndata: value\(i)\n\n".utf8)) { done.resume() } }
        }
        let page = try await store.read(from: 200)
        #expect(page.count == 5 && page.first?.eventID == "200")
        let raw = try await store.readRaw(from: 0, limit: 20)
        #expect(String(decoding: raw, as: UTF8.self).hasPrefix("id: 0\n"))
        await withCheckedContinuation { done in store.appendSSE(Data("data: last\n\n".utf8)) { done.resume() } }
        #expect(try await store.read(from: 205).first?.text == "last")
        #expect(try await store.read(from: 0, limit: 1).first?.text == "value0")
        #expect(store.summary.count == 206 && store.summary.error == nil)
    }
    @Test func compressedEventsDecodeIncrementally() async throws {
        let fixtures: [(String, [UInt8])] = [
            ("gzip", [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 75, 73, 44, 73, 180, 82, 120, 218, 215, 253, 124, 207, 202, 39, 187, 186, 159, 236, 222, 198, 197, 5, 0, 232, 117, 142, 64, 20, 0, 0, 0]),
            ("deflate", [120, 156, 75, 73, 44, 73, 180, 82, 120, 218, 215, 253, 124, 207, 202, 39, 187, 186, 159, 236, 222, 198, 197, 5, 0, 109, 190, 10, 209])
        ]
        for (encoding, bytes) in fixtures {
            let store = CaptureStreamStore(contentEncoding: encoding)
            for byte in bytes {
                await withCheckedContinuation { done in store.appendSSE(Data([byte])) { done.resume() } }
            }
            #expect(store.summary.error == nil)
            #expect(try await store.read(from: 0).first?.text == "压缩事件")
            #expect(try await store.readRaw(from: 0) == Data(bytes))
        }
    }
    @Test func coalescesUpdatesAndClearRejectsOldGeneration() {
        let buffer = CaptureRecordBuffer()
        let generation = buffer.generation
        var record = CaptureRecord(method: "GET", url: "http://example.test/events")
        record.connectionState = .open
        buffer.append(record, generation: generation)
        record.responseBytes = 10; buffer.append(record, generation: generation)
        let batch = buffer.drain()
        #expect(batch.records.count == 1 && batch.records[0].responseBytes == 10)
        buffer.clear(); buffer.append(record, generation: generation)
        #expect(buffer.drain().records.isEmpty)
    }
    @Test func SSEConfigurationRoundTripsAndAddsHeadersOnce() throws {
        var workflow = RequestWorkflow()
        workflow.setSSE(true)
        #expect(workflow.responseSteps.count == 1)
        #expect(workflow.responseSteps[0].headerEntries.map(\.name) == ["Content-Type", "Cache-Control"])
        workflow.setSSE(false); workflow.setSSE(true)
        #expect(workflow.responseSteps.count == 1)
        let data = try JSONEncoder().encode(workflow)
        #expect(try JSONDecoder().decode(RequestWorkflow.self, from: data).isSSE)
        #expect(RequestWorkflow().isSSE == false)
    }
    @Test func resumePublishesClosedStateOfPreviouslyVisibleStream() {
        let buffer = CaptureRecordBuffer()
        var record = CaptureRecord(method: "GET", url: "http://example.test/events")
        record.connectionState = .open
        buffer.append(record)
        #expect(buffer.drain().records.count == 1)
        buffer.setPaused(true)
        record.connectionState = .closed
        buffer.append(record)
        #expect(buffer.drain().records.isEmpty)
        buffer.setPaused(false)
        #expect(buffer.drain().records.first?.connectionState == .closed)
        buffer.setPaused(true); buffer.append(record); buffer.clear(); buffer.setPaused(false)
        #expect(buffer.drain().records.isEmpty)
    }
}
