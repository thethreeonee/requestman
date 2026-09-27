import Foundation

extension RuleMatchingEngine {
    public static func evaluateConditions(_ workflow: RequestWorkflow, method: String, url: String,
                                headers: [HTTPField]) -> WorkflowMatchTest {
        if let error = WorkflowMatchTest.validationError(for: workflow) { return .init(error: error, conditions: []) }
        guard let address = URLComponents(string: url),
              ["http", "https"].contains(address.scheme?.lowercased() ?? ""),
              let host = address.host, !host.isEmpty else {
            return .init(error: "请输入有效的 HTTP 或 HTTPS 测试 URL。", conditions: [])
        }
        guard HTTPMessageValidation.isToken(method) else {
            return .init(error: "请输入有效的请求方法。", conditions: [])
        }
        guard headers.allSatisfy({ HTTPMessageValidation.isToken($0.name) && !$0.value.contains("\r") && !$0.value.contains("\n") }) else {
            return .init(error: "测试 Header 名称无效或值包含换行。", conditions: [])
        }
        let group = workflow.matchConditions
        var conditions: [WorkflowMatchTest.Condition] = []
        func visit(_ group: WorkflowMatchGroup, depth: Int) {
            guard group.enabled else { return }
            conditions.append(WorkflowMatchTest.Condition(name: String(repeating: "  ", count: depth) + "满足以下\(group.mode.title)条件",
                                        matched: group.matches(method: method, url: url, headers: headers),
                                        detail: "\(group.conditionCount) 个条件", highlight: nil))
            for item in group.conditions where item.enabled {
                let values = item.values(method: method, url: url, headers: headers)
                conditions.append(WorkflowMatchTest.Condition(name: String(repeating: "  ", count: depth + 1) + item.summary,
                                            matched: item.matches(method: method, url: url, headers: headers),
                                            detail: "实际：" + (values.isEmpty ? "字段不存在" : values.map { $0.isEmpty ? "（空值）" : $0 }.joined(separator: " / ")),
                                            highlight: nil))
            }
            for child in group.groups { visit(child, depth: depth + 1) }
        }
        visit(group, depth: 0)
        return .init(error: nil, conditions: conditions, groupMatched: group.matches(method: method, url: url, headers: headers))
    }
}
