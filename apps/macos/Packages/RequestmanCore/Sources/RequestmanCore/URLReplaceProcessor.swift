import Foundation

struct URLReplaceProcessor: StepProcessor {
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        func resolveValue(_ text: String) throws -> String { try context.resolve(text, step: step) }
        var url = draft.url
        for entry in step.urlReplacementEntries {
            let search = try resolveValue(entry.search)
            guard !search.isEmpty else { throw WorkflowError.invalid("查找字符串不能为空") }
            let replacement = try resolveValue(entry.replacement)
            url = url.replacingOccurrences(of: search, with: replacement, options: .literal)
            try HTTPMessageValidation.validateEditedURL(url)
        }
        draft.url = url
    }
}
