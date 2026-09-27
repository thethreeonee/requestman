import Foundation

struct BodyProcessor: StepProcessor {
    func requirements(for step: ModificationStep) -> StepExecutionRequirements {
        .init(background: step.usesBodyFile, bodyFile: step.usesBodyFile)
    }
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        let value = step.usesBodyFile ? step.value : try context.resolve(step.value, step: step)
        try BodyReplacement.replace(value, step: step, in: &draft)
        HTTPMessageValidation.clearBodyEncoding(&draft)
        if !step.usesBodyFile, step.bodyEncoding == .base64, let encoding = step.bodyContentEncoding {
            try HTTPMessageValidation.validateHeader("Content-Encoding", value: encoding)
            draft.setHeader("Content-Encoding", encoding)
        }
    }
}
