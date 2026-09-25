import Foundation
import os

/// FIFO admission. No UI isolation, detached tasks, or unbounded internal task queue.
public final class BoundedExecutionGate: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let active: Int
        public let waiting: Int
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var active: Set<UUID> = []
        var waiting: [Waiter] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maximumActive: Int
    private let maximumWaiting: Int

    public init(maximumActive: Int, maximumWaiting: Int) throws {
        guard maximumActive > 0, maximumWaiting >= 0 else {
            throw ExecutionResourceError.invalidLimits
        }
        self.maximumActive = maximumActive
        self.maximumWaiting = maximumWaiting
    }

    public var snapshot: Snapshot {
        state.withLock { Snapshot(active: $0.active.count, waiting: $0.waiting.count) }
    }

    /// Cancellation of running work is cooperative. Never execute untrusted JS here.
    @concurrent
    public func run<Value: Sendable>(
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        try await acquire(id)
        defer { release(id) }
        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    private func acquire(_ id: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    // Check under the same lock as cancellation to close the
                    // cancellation-before-registration race.
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if state.active.count < maximumActive {
                        state.active.insert(id)
                        continuation.resume()
                    } else if state.waiting.count < maximumWaiting {
                        state.waiting.append(Waiter(id: id, continuation: continuation))
                    } else {
                        continuation.resume(throwing: ExecutionResourceError.queueFull)
                    }
                }
            }
        } onCancel: {
            self.cancelWaiting(id)
        }
    }

    private func cancelWaiting(_ id: UUID) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
            return state.waiting.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        let next = state.withLock { state -> Waiter? in
            guard state.active.remove(id) != nil, !state.waiting.isEmpty else { return nil }
            let waiter = state.waiting.removeFirst()
            state.active.insert(waiter.id)
            return waiter
        }
        next?.continuation.resume()
    }
}
