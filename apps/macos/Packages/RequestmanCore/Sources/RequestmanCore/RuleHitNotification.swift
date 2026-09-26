import Foundation
import os

public struct RuleHitNotification: Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public var names: [String]
    public var title: String { "规则命中" }
    public var body: String { names.joined(separator: "\n") }
}

@MainActor
public protocol RuleHitNotificationDelivering {
    func prepareAuthorization() async
    func deliver(_ notification: RuleHitNotification, from buffer: RuleHitNotificationBuffer) async
}

/// Independent of request history: hits are captured before execution or upstream I/O.
/// A monotonic clock fixes each round to [first hit, first hit + 3 seconds).
public final class RuleHitNotificationBuffer: Sendable {
    private struct State {
        var sessionID: UUID?
        var startedAt: ContinuousClock.Instant?
        var current: RuleHitNotification?
        var workflowIDs: Set<UUID> = []
        var pending: [RuleHitNotification] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func startSession(enabled: Bool) {
        state.withLock { $0 = State(sessionID: enabled ? UUID() : nil) }
    }

    public func stopSession() { state.withLock { $0 = State() } }

    public func isCurrent(_ notification: RuleHitNotification) -> Bool {
        state.withLock { $0.sessionID == notification.sessionID }
    }

    public func append(workflowID: UUID, name: String, at instant: ContinuousClock.Instant = .now) {
        state.withLock { state in
            guard let sessionID = state.sessionID else { return }
            if state.startedAt == nil || state.startedAt!.duration(to: instant) >= .seconds(3) {
                state.startedAt = instant
                state.current = RuleHitNotification(id: UUID(), sessionID: sessionID, names: [])
                state.workflowIDs.removeAll(keepingCapacity: true)
            }
            guard state.workflowIDs.insert(workflowID).inserted else { return }
            state.current?.names.append(name)
            guard let notification = state.current else { return }
            // Coalesce unread revisions, never combine different rounds. Bound a stalled consumer
            // to 64 rounds (over three minutes); normal host delivery drains every 200 ms.
            if state.pending.last?.id == notification.id {
                state.pending[state.pending.count - 1] = notification
            } else {
                if state.pending.count == 64 { state.pending.removeFirst() }
                state.pending.append(notification)
            }
        }
    }

    public func drain() -> [RuleHitNotification] {
        state.withLock { state in
            let result = state.pending
            state.pending.removeAll(keepingCapacity: true)
            return result
        }
    }
}
