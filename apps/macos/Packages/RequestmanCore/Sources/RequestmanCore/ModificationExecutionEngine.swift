import Foundation

/// Stops on the first failure. Each successful step commits atomically; earlier commits remain.
public enum ModificationExecutionEngine {
    public static func execute(_ steps: [ModificationStep], to draft: inout HTTPMessageDraft,
                               context: ModificationExecutionContext,
                               onApplied: ((StepExecutionTrace) -> Void)? = nil,
                               onTrace: ((StepExecutionTrace) -> Void)? = nil) throws -> ModificationExecutionResult {
        try validateCount(steps)
        var trace: [StepExecutionTrace] = []
        for step in steps where step.enabled {
            let start = ContinuousClock.now
            do {
                try validate(step, context: context)
                var candidate = draft
                try StepProcessors.processor(for: step.kind).process(step, draft: &candidate, context: context)
                try context.control.check()
                draft = candidate
                let item = entry(step, context: context, start: start)
                trace.append(item); onApplied?(item); onTrace?(item)
            } catch {
                onTrace?(entry(step, context: context, start: start, error: error))
                throw error
            }
            if context.phase == .request && draft.isMock { break }
        }
        return result(trace, draft: draft, context: context)
    }

    /// Call on a background executor when the plan includes blocking file or script work.
    public static func executeAsync(_ steps: [ModificationStep], to draft: inout HTTPMessageDraft,
                                    context: ModificationExecutionContext,
                                    onApplied: ((StepExecutionTrace) -> Void)? = nil,
                                    onTrace: ((StepExecutionTrace) -> Void)? = nil) async throws -> ModificationExecutionResult {
        try validateCount(steps)
        var trace: [StepExecutionTrace] = []
        for step in steps where step.enabled {
            let start = ContinuousClock.now
            do {
                try Task.checkCancellation()
                try validate(step, context: context)
                var candidate = draft
                try await StepProcessors.processor(for: step.kind).processAsync(step, draft: &candidate, context: context)
                try Task.checkCancellation()
                try context.control.check()
                draft = candidate
                let item = entry(step, context: context, start: start)
                trace.append(item); onApplied?(item); onTrace?(item)
            } catch {
                onTrace?(entry(step, context: context, start: start, error: error))
                throw error
            }
            if context.phase == .request && draft.isMock { break }
        }
        return result(trace, draft: draft, context: context)
    }

    public static func delayMilliseconds(_ value: String) throws -> Int { try DelayProcessor.milliseconds(value) }

    private static func validateCount(_ steps: [ModificationStep]) throws {
        guard steps.count <= 64 else { throw WorkflowError.invalid("每个方向最多执行 64 个步骤") }
    }

    private static func validate(_ step: ModificationStep, context: ModificationExecutionContext) throws {
        try context.control.check()
        guard step.kind.supports(response: context.phase == .response) else {
            throw WorkflowError.invalid("步骤不适用于当前方向")
        }
    }

    private static func entry(_ step: ModificationStep, context: ModificationExecutionContext,
                              start: ContinuousClock.Instant, error: (any Error)? = nil) -> StepExecutionTrace {
        StepExecutionTrace(stepID: step.id, kind: step.kind, phase: context.phase, elapsed: start.duration(to: .now),
            status: error == nil ? .applied : (error is CancellationError || context.control.isCancelled ? .cancelled : .failed),
            error: error?.localizedDescription)
    }

    private static func result(_ trace: [StepExecutionTrace], draft: HTTPMessageDraft,
                               context: ModificationExecutionContext) -> ModificationExecutionResult {
        ModificationExecutionResult(trace: trace,
            disposition: context.phase == .request && draft.isMock ? .localResponse : .forward)
    }
}
