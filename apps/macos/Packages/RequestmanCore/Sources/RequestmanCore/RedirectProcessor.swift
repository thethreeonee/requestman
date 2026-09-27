import Foundation

struct RedirectProcessor: StepProcessor {
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        let value = step.usesBodyFile ? step.value : try context.resolve(step.value, step: step)
        let response = context.phase == .response
        guard [301,302,303,307,308].contains(step.status), let url = URL(string: value),
              ["http", "https"].contains(url.scheme), url.host != nil,
              !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw WorkflowError.invalid("重定向地址或状态码无效") }
        if !response { draft.headers = [] }
        draft.status = step.status; draft.setHeader("Location", value)
        draft.replacementBody = ""; draft.replacementBodyData = nil; draft.isMock = !response
        HTTPMessageValidation.clearBodyEncoding(&draft)
    }
}
