import Foundation

public enum MatchField: String, Codable, CaseIterable, Sendable {
    case method, url, host, path, scheme, port, query, header, cookie, contentType
    public var title: String {
        switch self {
        case .method: "请求方法"; case .url: "URL"; case .host: "Host"; case .path: "Path"
        case .scheme: "协议"; case .port: "端口"; case .query: "查询参数"; case .header: "Header"
        case .cookie: "Cookie"; case .contentType: "Content-Type"
        }
    }
    public var needsName: Bool { [.query, .header, .cookie].contains(self) }
    public var operators: [MatchOperator] {
        if self == .method || self == .scheme || self == .port { return [.equals, .notEquals, .oneOf, .notOneOf] }
        let text: [MatchOperator] = [.equals, .notEquals, .contains, .notContains, .beginsWith, .endsWith, .wildcard, .regex]
        return text + (self == .host ? [.domainAndSubdomains] : []) + (needsName ? [.exists, .notExists, .isEmpty, .notEmpty] : [])
    }
}

public enum MatchOperator: String, Codable, CaseIterable, Sendable {
    case equals, notEquals, contains, notContains, beginsWith, endsWith, wildcard, regex
    case oneOf, notOneOf, exists, notExists, isEmpty, notEmpty, domainAndSubdomains
    public var title: String {
        switch self {
        case .equals: "等于"; case .notEquals: "不等于"; case .contains: "包含"; case .notContains: "不包含"
        case .beginsWith: "开头是"; case .endsWith: "结尾是"; case .wildcard: "通配符"; case .regex: "正则"
        case .oneOf: "属于"; case .notOneOf: "不属于"; case .exists: "存在"; case .notExists: "不存在"
        case .isEmpty: "为空"; case .notEmpty: "不为空"; case .domainAndSubdomains: "域名及子域名"
        }
    }
    public var needsValue: Bool { ![.exists, .notExists, .isEmpty, .notEmpty].contains(self) }
}

public struct MatchCondition: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var field: MatchField
    public var operation: MatchOperator
    public var name: String
    public var value: String
    public init(field: MatchField = .url, operation: MatchOperator = .contains, name: String = "", value: String = "") {
        self.field = field; self.operation = operation; self.name = name; self.value = value
    }
    public var summary: String { "\(field.title)\(field.needsName ? " · " + name : "") \(operation.title)\(operation.needsValue ? " " + value : "")" }
    public var validationError: String? {
        guard enabled else { return nil }
        guard field.operators.contains(operation) else { return "此字段不支持所选运算符。" }
        if field.needsName && name.isEmpty { return "请输入\(field.title)名称。" }
        if [.header, .cookie].contains(field) && !HTTPMessageValidation.isToken(name) { return "请输入有效的\(field.title)名称。" }
        if operation.needsValue && value.isEmpty { return "请输入匹配值。" }
        if operation == .regex { return WorkflowMatcher.validationError(rule: .regex, pattern: value) }
        if [.oneOf, .notOneOf].contains(operation) && choices.isEmpty { return "请输入至少一个值，以逗号分隔。" }
        if field == .port {
            let ports = [.oneOf, .notOneOf].contains(operation) ? choices : [value]
            if ports.contains(where: { Int($0).map { !(1...65535).contains($0) } ?? true }) { return "端口应为 1–65535。" }
        }
        if field == .method {
            let methods = [.oneOf, .notOneOf].contains(operation) ? choices : [value]
            if !methods.allSatisfy(HTTPMessageValidation.isToken) { return "请输入有效的请求方法。" }
        }
        if field == .scheme {
            let schemes = [.oneOf, .notOneOf].contains(operation) ? choices : [value]
            if !schemes.allSatisfy({ ["http", "https"].contains($0.lowercased()) }) { return "协议应为 http 或 https。" }
        }
        if operation == .domainAndSubdomains && (value.contains("*") || value.contains("/") || value.hasPrefix(".") || value.contains(":")) {
            return "请输入不含协议、端口或通配符的域名。"
        }
        return nil
    }
    private var choices: [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    public func values(method: String, url: String, headers: [HTTPField]) -> [String] {
        RuleMatchingEngine.values(for: self, method: method, url: url, headers: headers)
    }
    public func matches(method: String, url: String, headers: [HTTPField]) -> Bool {
        RuleMatchingEngine.matches(self, method: method, url: url, headers: headers)
    }
}

public struct WorkflowMatchGroup: Codable, Equatable, Identifiable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case all, any
        public var title: String { self == .all ? "全部" : "任一" }
    }
    public var id = UUID()
    public var enabled = true
    public var mode: Mode = .all
    public var conditions: [MatchCondition] = []
    public var groups: [WorkflowMatchGroup] = []
    public init(mode: Mode = .all, conditions: [MatchCondition] = [], groups: [WorkflowMatchGroup] = []) {
        self.mode = mode; self.conditions = conditions; self.groups = groups
    }
    public var conditionCount: Int { conditions.count + groups.reduce(0) { $0 + $1.conditionCount } }
    public var summary: String {
        let parts = conditions.filter(\.enabled).map(\.summary) + groups.filter(\.enabled).map { "（\($0.summary)）" }
        return parts.isEmpty ? "无有效条件，不匹配请求" : parts.joined(separator: mode == .all ? " 且 " : " 或 ")
    }
    public var validationError: String? {
        guard enabled else { return nil }
        if !conditions.contains(where: \.enabled) && !groups.contains(where: \.enabled) { return "请添加或启用至少一个条件；空条件组不会匹配请求。" }
        for condition in conditions where condition.enabled {
            if let error = condition.validationError { return "\(condition.field.title)：\(error)" }
        }
        for group in groups where group.enabled { if let error = group.validationError { return error } }
        return nil
    }
    public func matches(method: String, url: String, headers: [HTTPField]) -> Bool {
        RuleMatchingEngine.matches(self, method: method, url: url, headers: headers)
    }
    public mutating func update(_ id: UUID, _ action: (inout Self) -> Void) {
        if self.id == id { action(&self); return }
        for index in groups.indices { groups[index].update(id, action) }
    }
    public func duplicated() -> Self {
        var copy = self; copy.id = UUID()
        copy.conditions = conditions.map { var item = $0; item.id = UUID(); return item }
        copy.groups = groups.map { $0.duplicated() }
        return copy
    }
}

extension RequestWorkflow {
    public var matchingSummary: String { matchConditions.summary }
}
