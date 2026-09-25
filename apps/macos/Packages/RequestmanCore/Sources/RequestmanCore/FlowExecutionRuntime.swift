import Foundation
import os

/// One invocation's immutable plan and independently tracked body preparation.
public final class FlowExecutionContext: Sendable {
    private struct State {
        var prepared: Set<FlowPhase> = []
        var finished = false
    }

    public let id: UUID
    public let plan: FlowExecutionPlan
    private let limits: ExecutionLimits
    private let budget: BodyBufferBudget
    private let deadline: ContinuousClock.Instant
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        id: UUID, plan: FlowExecutionPlan, limits: ExecutionLimits,
        budget: BodyBufferBudget, deadline: ContinuousClock.Instant
    ) {
        self.id = id
        self.plan = plan
        self.limits = limits
        self.budget = budget
        self.deadline = deadline
    }

    /// Prepare once per phase, then share its result across nodes. The streaming
    /// path never calls read(). The transport still owns streaming backpressure.
    @concurrent
    public func prepareBody(_ reader: any BodyReader, for phase: FlowPhase) async throws -> PreparedBody {
        try Task.checkCancellation()
        try state.withLock { state in
            guard !state.finished else { throw ExecutionResourceError.executionFinished }
            guard deadline > .now else { throw ExecutionResourceError.timedOut }
            guard state.prepared.insert(phase).inserted else {
                throw ExecutionResourceError.bodyAlreadyPrepared
            }
        }
        switch plan.bodyMode(for: phase) {
        case .streaming: return .streaming(reader)
        case .buffered:
            let body = try await BodyCollector.collect(from: reader, limits: limits, budget: budget)
            try Task.checkCancellation()
            guard !state.withLock({ $0.finished }) else { throw ExecutionResourceError.executionFinished }
            guard deadline > .now else { throw ExecutionResourceError.timedOut }
            return .buffered(body)
        }
    }

    func finish() { state.withLock { $0.finished = true } }
}

/// Integrates admission, body preparation and lossy metadata recording without
/// depending on SwiftUI, a database, a proxy framework or a JavaScript runtime.
public final class FlowExecutionRuntime: Sendable {
    public let limits: ExecutionLimits
    public let events: ExecutionEventBuffer
    public let bodyBudget: BodyBufferBudget
    private let gate: BoundedExecutionGate

    public init(limits: ExecutionLimits) throws {
        self.limits = limits
        gate = try BoundedExecutionGate(maximumActive: limits.maximumActive, maximumWaiting: limits.maximumWaiting)
        bodyBudget = try BodyBufferBudget(capacity: limits.maximumBufferedBytes)
        events = try ExecutionEventBuffer(capacity: limits.eventCapacity, maximumBatch: limits.maximumEventBatch)
    }

    public var admission: BoundedExecutionGate.Snapshot { gate.snapshot }

    /// The operation spans both phases and forwarding. Its async transport must
    /// cooperate with cancellation. This is not a hard kill boundary for scripts.
    @concurrent
    public func execute<Value: Sendable>(
        plan: FlowExecutionPlan,
        deadline: ContinuousClock.Instant? = nil,
        operation: @escaping @Sendable (FlowExecutionContext) async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        let end = min(deadline ?? .now.advanced(by: limits.timeout), .now.advanced(by: limits.timeout))
        record(.submitted, id: id, plan: plan)
        do {
            try Task.checkCancellation()
            guard end > .now else { throw ExecutionResourceError.timedOut }
            let result = try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask {
                    try await self.gate.run {
                        try Task.checkCancellation()
                        guard end > .now else { throw ExecutionResourceError.timedOut }
                        self.record(.started, id: id, plan: plan)
                        let context = FlowExecutionContext(
                            id: id, plan: plan, limits: self.limits,
                            budget: self.bodyBudget, deadline: end
                        )
                        defer { context.finish() }
                        return try await operation(context)
                    }
                }
                group.addTask {
                    try await ContinuousClock().sleep(until: end)
                    throw ExecutionResourceError.timedOut
                }
                defer { group.cancelAll() }
                // Both children either return or throw; the group cannot be empty.
                return try await group.next()!
            }
            try Task.checkCancellation()
            guard end > .now else { throw ExecutionResourceError.timedOut }
            record(.completed, id: id, plan: plan)
            return result
        } catch {
            let kind: ExecutionEvent.Kind
            if error is CancellationError {
                kind = .cancelled
            } else if let resource = error as? ExecutionResourceError {
                switch resource {
                case .queueFull: kind = .rejected
                case .timedOut: kind = .timedOut
                default: kind = .failed
                }
            } else {
                kind = .failed
            }
            record(kind, id: id, plan: plan)
            throw error
        }
    }

    private func record(_ kind: ExecutionEvent.Kind, id: UUID, plan: FlowExecutionPlan) {
        events.append(ExecutionEvent(executionID: id, planVersion: plan.version, kind: kind))
    }
}
