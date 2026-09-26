import Foundation

public enum WorkflowMatchTarget: String, Codable, CaseIterable, Sendable {
    case url, host
    public var title: String {
        switch self { case .url: "URL 匹配"; case .host: "Host 匹配" }
    }
}

public enum WorkflowMatchRule: String, Codable, CaseIterable, Sendable {
    case wildcard, regex, equals, contains
    public var title: String {
        switch self { case .wildcard: "通配符"; case .regex: "正则"; case .equals: "等于"; case .contains: "包含" }
    }
}

public enum WorkflowMatcher {
    public static func validationError(rule: WorkflowMatchRule, pattern: String) -> String? {
        if pattern.isEmpty { return "请输入匹配值；空值不会匹配请求。" }
        if rule == .regex, (try? NSRegularExpression(pattern: pattern)) == nil { return "正则表达式无效。" }
        return nil
    }

    public static func headerValidationError(name: String, rule: WorkflowMatchRule, pattern: String) -> String? {
        if !WorkflowEngine.isToken(name) { return "请选择或输入有效的 Header 名称。" }
        return validationError(rule: rule, pattern: pattern)
    }

    public static func matchesHeader(name: String, rule: WorkflowMatchRule, pattern: String, headers: [HTTPField]) -> Bool {
        guard headerValidationError(name: name, rule: rule, pattern: pattern) == nil else { return false }
        return headers.contains { field in
            field.name.caseInsensitiveCompare(name) == .orderedSame &&
                matchesValue(field.value, rule: rule, pattern: pattern, ignoreCase: false)
        }
    }

    public static func matches(target: WorkflowMatchTarget, rule: WorkflowMatchRule, pattern: String, url: String) -> Bool {
        guard validationError(rule: rule, pattern: pattern) == nil else { return false }
        let value: String
        if target == .host {
            guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return false }
            value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        } else { value = url }
        return matchesValue(value, rule: rule, pattern: pattern, ignoreCase: target == .host)
    }

    private static func matchesValue(_ value: String, rule: WorkflowMatchRule, pattern: String, ignoreCase: Bool) -> Bool {
        let needle = ignoreCase && rule != .regex ? pattern.lowercased() : pattern
        switch rule {
        case .equals: return value == needle
        case .contains: return value.contains(needle)
        case .wildcard:
            let expression = "\\A" + needle.map { character in
                character == "*" ? ".*" : character == "?" ? "." : NSRegularExpression.escapedPattern(for: String(character))
            }.joined() + "\\z"
            return regexMatches(expression, value: value, ignoreCase: ignoreCase)
        case .regex: return regexMatches(needle, value: value, ignoreCase: ignoreCase)
        }
    }

    private static func regexMatches(_ pattern: String, value: String, ignoreCase: Bool) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []) else { return false }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(20))
        var found = false
        regex.enumerateMatches(in: value, options: [.reportProgress], range: NSRange(value.startIndex..., in: value)) { result, _, stop in
            if ContinuousClock.now >= deadline { stop.pointee = true; return }
            if result != nil { found = true; stop.pointee = true }
        }
        return found
    }
}
