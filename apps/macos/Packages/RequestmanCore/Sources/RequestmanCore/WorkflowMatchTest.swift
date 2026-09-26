import Foundation

/// A local condition check. Workflow/project enablement and step execution are intentionally excluded.
public struct WorkflowMatchTest: Sendable {
    public struct Condition: Sendable {
        public let name: String
        public let matched: Bool
        public let detail: String
        public let highlight: NSRange?
    }

    public let error: String?
    public let conditions: [Condition]
    public var matched: Bool { error == nil && !conditions.isEmpty && conditions.allSatisfy(\.matched) }

    public static func validationError(for workflow: RequestWorkflow) -> String? {
        if let error = WorkflowMatcher.validationError(rule: workflow.matchRule, pattern: workflow.matchPattern) {
            return "\(workflow.matchTarget.title)：\(error)"
        }
        if workflow.matchHeaderEnabled,
           let error = WorkflowMatcher.headerValidationError(name: workflow.matchHeaderName,
                                                             rule: workflow.matchHeaderRule,
                                                             pattern: workflow.matchHeaderPattern) {
            return "Header：\(error)"
        }
        return nil
    }

    public static func evaluate(_ workflow: RequestWorkflow, method: String, url: String,
                                headers: [HTTPField]) -> Self {
        if let error = validationError(for: workflow) { return .init(error: error, conditions: []) }
        guard let address = URLComponents(string: url),
              ["http", "https"].contains(address.scheme?.lowercased() ?? ""),
              let host = address.host, !host.isEmpty else {
            return .init(error: "请输入有效的 HTTP 或 HTTPS 测试 URL。", conditions: [])
        }
        guard WorkflowEngine.isToken(method) else {
            return .init(error: "请输入有效的请求方法。", conditions: [])
        }
        guard headers.allSatisfy({ WorkflowEngine.isToken($0.name) && !$0.value.contains("\r") && !$0.value.contains("\n") }) else {
            return .init(error: "测试 Header 名称无效或值包含换行。", conditions: [])
        }
        let methodMatches = workflow.method == "*" || workflow.method.caseInsensitiveCompare(method) == .orderedSame
        let value = workflow.matchTarget == .url ? url : host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let range = WorkflowMatcher.matchingRange(in: value, rule: workflow.matchRule,
                                                 pattern: workflow.matchPattern, ignoreCase: workflow.matchTarget == .host)
        var conditions = [Condition(name: "请求方法", matched: methodMatches,
                                    detail: "期望：\(workflow.method == "*" ? "全部" : workflow.method)    实际：\(method)", highlight: nil),
                          Condition(name: "\(workflow.matchTarget.title) · \(workflow.matchRule.title)", matched: range != nil,
                                    detail: value, highlight: range)]
        if workflow.matchHeaderEnabled {
            let values = headers.filter { $0.name.caseInsensitiveCompare(workflow.matchHeaderName) == .orderedSame }.map(\.value)
            let matched = WorkflowMatcher.matchesHeader(name: workflow.matchHeaderName, rule: workflow.matchHeaderRule,
                                                         pattern: workflow.matchHeaderPattern, headers: headers)
            conditions.append(Condition(name: "Header · \(workflow.matchHeaderName)", matched: matched,
                                        detail: "期望（\(workflow.matchHeaderRule.title)）：\(workflow.matchHeaderPattern)\n实际：\(values.isEmpty ? "缺少此 Header" : values.joined(separator: " / "))",
                                        highlight: nil))
        }
        return .init(error: nil, conditions: conditions)
    }
}
