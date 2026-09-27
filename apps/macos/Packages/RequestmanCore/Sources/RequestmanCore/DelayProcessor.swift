import Foundation

public struct DelayProcessor: StepProcessor {
    func requirements(for step: ModificationStep) -> StepExecutionRequirements {
        .init(background: true, delay: true)
    }
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        throw WorkflowError.invalid("延迟步骤需要异步执行流程")
    }

    func processAsync(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) async throws {
        let milliseconds = try Self.milliseconds(step.value)
        let end = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        while ContinuousClock.now < end {
            try context.control.check()
            try await Task.sleep(until: min(end, .now.advanced(by: .milliseconds(25))), clock: .continuous)
        }
        try Task.checkCancellation()
        try context.control.check()
    }

    public static func milliseconds(_ value: String) throws -> Int {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let milliseconds = Int(value) else {
            throw WorkflowError.invalid("延迟时间需为非负整数，单位 ms")
        }
        return milliseconds
    }
}
