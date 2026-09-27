import Foundation
import Testing
@testable import RequestmanCore

struct CaptureEventTests {
    @Test func slowConsumerLosesOldestEventsWithExplicitDropCount() {
        let events = CaptureEventBuffer(capacity: 2)
        let id = UUID()
        events.append(.init(.matched, transactionID: id))
        events.append(.init(.completed, transactionID: id))
        events.append(.init(.sessionStopped))
        let first = events.drain(limit: 1)
        #expect(first.events.map(\.kind) == [.completed])
        #expect(first.events.first?.transactionID == id)
        #expect(first.dropped == 1)
        let next = events.drain()
        #expect(next.events.map(\.kind) == [.sessionStopped])
        #expect(next.dropped == 0)
        #expect(events.drain().events.isEmpty)
    }

    @Test func clearingOrPausingRecordsDoesNotConsumeLifecycleEvents() {
        let records = CaptureRecordBuffer()
        let events = CaptureEventBuffer()
        events.append(.init(.matched))
        records.setPaused(true)
        records.clear()
        #expect(events.drain().events.map(\.kind) == [.matched])
        events.append(.init(.failed, message: String(repeating: "x", count: 1024)))
        #expect(events.drain().events.first?.message?.count == 512)
        events.append(.init(.completed))
        events.clear()
        #expect(events.drain().events.isEmpty)
    }
}
