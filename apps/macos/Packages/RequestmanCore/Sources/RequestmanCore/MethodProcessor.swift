import Foundation

struct MethodProcessor: StepProcessor {
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        let value = step.usesBodyFile ? step.value : try context.resolve(step.value, step: step)
        guard HTTPMessageValidation.isToken(value), !["CONNECT", "TRACE"].contains(value.uppercased()) else {
            throw WorkflowError.invalid("不支持此请求方法")
        }
        draft.method = value.uppercased()
    }
}
