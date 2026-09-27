import Foundation

struct StatusProcessor: StepProcessor {
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        _ = try context.resolve(step.value, step: step)
        guard (200...599).contains(step.status) else { throw WorkflowError.invalid("状态码需在 200–599 之间") }
        draft.status = step.status
    }
}
