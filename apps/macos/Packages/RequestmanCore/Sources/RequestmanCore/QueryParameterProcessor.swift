import Foundation

struct QueryParameterProcessor: StepProcessor {
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        func resolveValue(_ text: String) throws -> String { try context.resolve(text, step: step) }
        // Stage the whole list locally so a later invalid entry cannot partially edit the URL.
        let entries: [QueryParameterEntry]
        if let configured = step.queryParameters { entries = configured }
        else { entries = [QueryParameterEntry(operation: nil, name: step.name, value: step.value)] }
        if entries.isEmpty { return }
        guard var components = URLComponents(string: draft.url) else {
            throw WorkflowError.invalid("查询参数名称或 URL 无效")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for entry in entries {
            let name = try resolveValue(entry.name)
            guard !name.isEmpty else { throw WorkflowError.invalid("查询参数名称不能为空") }
            let matchRule = entry.operation == .modify || entry.operation == .remove ? entry.matchRule : .equals
            if let error = WorkflowMatcher.validationError(rule: matchRule, pattern: name) {
                throw WorkflowError.invalid("查询参数名称：" + error)
            }
            let parts = components.percentEncodedQuery.map { $0.isEmpty ? [] : $0.components(separatedBy: "&") } ?? []
            func matches(_ part: String) -> Bool {
                guard !part.isEmpty else { return false }
                let key = String(part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                guard let decoded = key.removingPercentEncoding else { return false }
                return WorkflowMatcher.matchesQueryParameterName(decoded, rule: matchRule, pattern: name)
            }
            let exists = parts.contains(where: matches)
            if entry.operation == .add && exists || entry.operation == .modify && !exists { continue }
            if entry.operation == .remove {
                guard exists else { continue }
                let remaining = parts.filter { !matches($0) }
                components.percentEncodedQuery = remaining.isEmpty ? nil : remaining.joined(separator: "&")
                continue
            }
            let value = try resolveValue(entry.value)
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)!
            let pair = name.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + encodedValue
            var updated: [String] = []
            var replaced = false
            for part in parts {
                if matches(part) {
                    if entry.operation == .modify {
                        let key = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                        updated.append(String(key) + "=" + encodedValue)
                    } else if !replaced { updated.append(pair) }
                    replaced = true
                } else { updated.append(part) }
            }
            if !replaced { updated.append(pair) }
            components.percentEncodedQuery = updated.joined(separator: "&")
        }
        guard let url = components.string else { throw WorkflowError.invalid("查询参数修改后的 URL 无效") }
        try HTTPMessageValidation.validateEditedURL(url)
        draft.url = url
    }
}
