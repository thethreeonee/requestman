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
    public static func matchesQueryParameterName(_ name: String, rule: WorkflowMatchRule, pattern: String) -> Bool {
        guard validationError(rule: rule, pattern: pattern) == nil else { return false }
        return matchesValue(name, rule: rule, pattern: pattern, ignoreCase: false)
    }

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
        matchingRange(in: value, rule: rule, pattern: pattern, ignoreCase: ignoreCase) != nil
    }

    /// Uses the same first-match semantics and regex time budget as live matching.
    public static func matchingRange(in value: String, rule: WorkflowMatchRule, pattern: String,
                                     ignoreCase: Bool = false) -> NSRange? {
        let needle = ignoreCase && rule != .regex ? pattern.lowercased() : pattern
        switch rule {
        case .equals: return value == needle ? NSRange(value.startIndex..., in: value) : nil
        case .contains:
            return value.range(of: needle).map { NSRange($0, in: value) }
        case .wildcard:
            let expression = "\\A" + needle.map { character in
                character == "*" ? ".*" : character == "?" ? "." : NSRegularExpression.escapedPattern(for: String(character))
            }.joined() + "\\z"
            return regexRange(expression, value: value, ignoreCase: ignoreCase)
        case .regex: return regexRange(needle, value: value, ignoreCase: ignoreCase)
        }
    }

    private static func regexRange(_ pattern: String, value: String, ignoreCase: Bool) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []) else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(20))
        var found: NSRange?
        regex.enumerateMatches(in: value, options: [.reportProgress], range: NSRange(value.startIndex..., in: value)) { result, _, stop in
            if ContinuousClock.now >= deadline { stop.pointee = true; return }
            if let result { found = result.range; stop.pointee = true }
        }
        return found
    }
}
