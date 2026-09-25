import Foundation
import os

/// Fixed-size metadata only: bodies, URLs, secrets and arbitrary script output
/// never enter this queue. Detailed records require separate bounded storage.
public struct ExecutionEvent: Sendable {
    public enum Kind: Equatable, Sendable {
        case submitted
        case started
        case completed
        case cancelled
        case rejected
        case timedOut
        case failed
    }

    public let executionID: UUID
    public let planVersion: UUID
    public let kind: Kind
    public let timestamp: ContinuousClock.Instant

    public init(executionID: UUID, planVersion: UUID, kind: Kind) {
        self.executionID = executionID
        self.planVersion = planVersion
        self.kind = kind
        timestamp = .now
    }
}

/// Synchronous short critical sections; no disk, UI callbacks or await on append.
/// A slow consumer loses oldest metadata, explicitly reported with every drain.
public final class ExecutionEventBuffer: Sendable {
    public struct Batch: Sendable {
        public let events: [ExecutionEvent]
        public let droppedEvents: Int
    }

    private struct State {
        var slots: [ExecutionEvent?]
        var head = 0
        var count = 0
        var dropped = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    public let capacity: Int
    public let maximumBatch: Int

    public init(capacity: Int, maximumBatch: Int) throws {
        guard capacity > 0, maximumBatch > 0, maximumBatch <= capacity else {
            throw ExecutionResourceError.invalidLimits
        }
        self.capacity = capacity
        self.maximumBatch = maximumBatch
        state = OSAllocatedUnfairLock(initialState: State(slots: .init(repeating: nil, count: capacity)))
    }

    public var pendingCount: Int { state.withLock { $0.count } }

    public func append(_ event: ExecutionEvent) {
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

    /// Single-consumer drain. UI and persistence should share one downstream
    /// consumer rather than independently removing events from this buffer.
    public func drain() -> Batch {
        state.withLock { state in
            var events: [ExecutionEvent] = []
            let count = min(maximumBatch, state.count)
            events.reserveCapacity(count)
            for _ in 0..<count {
                if let event = state.slots[state.head] { events.append(event) }
                state.slots[state.head] = nil
                state.head = (state.head + 1) % capacity
            }
            state.count -= count
            let dropped = state.dropped
            state.dropped = 0
            return Batch(events: events, droppedEvents: dropped)
        }
    }
}
