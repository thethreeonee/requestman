import Foundation
import os

/// Capture lifecycle metadata, independent of request-log pause and clear.
public struct CaptureEvent: Sendable {
    public enum Kind: Sendable, Equatable {
        case sessionStarted, sessionStopped, matched, completed, failed, cancelled
    }

    public let kind: Kind
    public let transactionID: UUID?
    public let workflowID: UUID?
    public let date: Date
    public let message: String?

    public init(_ kind: Kind, transactionID: UUID? = nil, workflowID: UUID? = nil,
                message: String? = nil, date: Date = Date()) {
        self.kind = kind
        self.transactionID = transactionID
        self.workflowID = workflowID
        self.date = date
        self.message = message.map { String($0.prefix(512)) }
    }
}

/// Lossy single-consumer diagnostics; publishing never waits for UI or storage.
public final class CaptureEventBuffer: Sendable {
    public struct Batch: Sendable {
        public let events: [CaptureEvent]
        public let dropped: Int
    }

    private struct State {
        var slots: [CaptureEvent?]
        var head = 0
        var count = 0
        var dropped = 0
    }

    public let capacity: Int
    private let state: OSAllocatedUnfairLock<State>

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
        state = OSAllocatedUnfairLock(initialState: State(slots: .init(repeating: nil, count: max(1, capacity))))
    }

    public func append(_ event: CaptureEvent) {
        state.withLock { state in
            if state.count == capacity {
                state.slots[state.head] = event
                state.head = (state.head + 1) % capacity
                if state.dropped < Int.max { state.dropped += 1 }
            } else {
                state.slots[(state.head + state.count) % capacity] = event
                state.count += 1
            }
        }
    }

    public func drain(limit: Int = 64) -> Batch {
        state.withLock { state in
            var events: [CaptureEvent] = []
            for _ in 0..<min(max(1, limit), state.count) {
                if let event = state.slots[state.head] { events.append(event) }
                state.slots[state.head] = nil
                state.head = (state.head + 1) % capacity
                state.count -= 1
            }
            let dropped = state.dropped
            state.dropped = 0
            return Batch(events: events, dropped: dropped)
        }
    }

    public func clear() {
        state.withLock { $0 = State(slots: .init(repeating: nil, count: capacity)) }
    }
}
