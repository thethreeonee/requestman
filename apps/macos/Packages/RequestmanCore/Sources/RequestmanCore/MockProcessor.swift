import Foundation

struct MockProcessor: StepProcessor {
    func requirements(for step: ModificationStep) -> StepExecutionRequirements {
        .init(background: step.usesBodyFile, bodyFile: step.usesBodyFile)
    }
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        let value = step.usesBodyFile ? step.value : try context.resolve(step.value, step: step)
        guard (200...599).contains(step.status) else { throw WorkflowError.invalid("Mock 状态码无效") }
        try BodyReplacement.replace(value, step: step, in: &draft)
        draft.isMock = true; draft.status = step.status
        draft.headers = [HTTPField("Content-Type", "application/json; charset=utf-8")]
    }
}
