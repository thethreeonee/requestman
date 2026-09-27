import Foundation

extension RuleMatchingEngine {
    public static func values(for condition: MatchCondition, method: String, url: String, headers: [HTTPField]) -> [String] {
        RuleConditionEvaluator(condition: condition).values(method: method, url: url, headers: headers)
    }
    public static func matches(_ condition: MatchCondition, method: String, url: String, headers: [HTTPField]) -> Bool {
        RuleConditionEvaluator(condition: condition).matches(method: method, url: url, headers: headers)
    }
}

private struct RuleConditionEvaluator {
    let condition: MatchCondition
    var field: MatchField { condition.field }
    var operation: MatchOperator { condition.operation }
    var name: String { condition.name }
    var value: String { condition.value }
    var validationError: String? { condition.validationError }
    var choices: [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func values(method: String, url: String, headers: [HTTPField]) -> [String] {
        let address = URLComponents(string: url)
        switch field {
        case .method: return [method]
        case .url: return [url]
        case .host: return address?.host.map { [$0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))] } ?? []
        case .path: return address.map { [$0.percentEncodedPath.isEmpty ? "/" : $0.percentEncodedPath] } ?? []
        case .scheme: return address?.scheme.map { [$0.lowercased()] } ?? []
        case .port: return address.flatMap { $0.port ?? ($0.scheme?.lowercased() == "https" ? 443 : 80) }.map { [String($0)] } ?? []
        case .query: return address?.queryItems?.filter { $0.name == name }.map { $0.value ?? "" } ?? []
        case .header: return headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        case .contentType: return headers.filter { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }.map {
            String($0.value.split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        case .cookie:
            return headers.filter { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }.flatMap { header in
                header.value.split(separator: ";").compactMap { part in
                    let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name else { return nil }
                    return pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
    }
    func matches(method: String, url: String, headers: [HTTPField]) -> Bool {
        guard validationError == nil else { return false }
        let values = values(method: method, url: url, headers: headers)
        if operation == .exists { return !values.isEmpty }
        if operation == .notExists { return values.isEmpty }
        guard !values.isEmpty else { return false }
        let insensitive = [.host, .scheme, .method, .contentType].contains(field)
        func normalized(_ text: String) -> String { insensitive ? text.lowercased() : text }
        let pattern = normalized(value)
        func positive(_ original: String) -> Bool {
            let actual = normalized(original)
            switch operation {
            case .equals, .notEquals: return actual == pattern
            case .contains, .notContains: return actual.contains(pattern)
            case .beginsWith: return actual.hasPrefix(pattern)
            case .endsWith: return actual.hasSuffix(pattern)
            case .wildcard, .regex:
                return WorkflowMatcher.matchingRange(in: actual, rule: operation == .regex ? .regex : .wildcard,
                                                      pattern: value, ignoreCase: insensitive) != nil
            case .oneOf, .notOneOf: return choices.map(normalized).contains(actual)
            case .isEmpty, .notEmpty: return actual.isEmpty
            case .domainAndSubdomains:
                let domain = pattern.hasSuffix(".") ? String(pattern.dropLast()) : pattern
                return actual == domain || actual.hasSuffix("." + domain)
            case .exists, .notExists: return false
            }
        }
        if [.notEquals, .notContains, .notOneOf, .notEmpty].contains(operation) { return values.allSatisfy { !positive($0) } }
        return values.contains(where: positive)
    }
}
