import Foundation
import CoreFoundation

public enum EnvironmentValueType: String, Codable, CaseIterable, Sendable {
    case string, number, boolean, array, object

    public var title: String {
        switch self {
        case .string: "字符串"
        case .number: "数值"
        case .boolean: "布尔"
        case .array: "数组"
        case .object: "对象"
        }
    }

    public var placeholder: String {
        switch self {
        case .string: "值"
        case .number: "例如 123 或 3.14"
        case .boolean: "true 或 false"
        case .array: "例如 [1, 2, 3]"
        case .object: #"例如 {"key": "value"}"#
        }
    }

    public func accepts(_ value: String) -> Bool {
        if self == .string { return true }
        guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) else { return false }
        switch self {
        case .string: return true
        case .number:
            guard let number = json as? NSNumber else { return false }
            return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
        case .boolean: return value.trimmingCharacters(in: .whitespacesAndNewlines) == "true" || value.trimmingCharacters(in: .whitespacesAndNewlines) == "false"
        case .array: return json is [Any]
        case .object: return json is [String: Any]
        }
    }
}

public struct NamedValue: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var value: String
    public var type: EnvironmentValueType
    public init(name: String = "", value: String = "", type: EnvironmentValueType = .string) {
        self.name = name; self.value = value; self.type = type
    }
    private enum CodingKeys: String, CodingKey { case id, name, value, type }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        value = try values.decode(String.self, forKey: .value)
        type = try values.decodeIfPresent(EnvironmentValueType.self, forKey: .type) ?? .string
    }
}

public enum HeaderOperation: String, Codable, CaseIterable, Sendable {
    case add, modify, remove
    /// Retained only for saved add-or-replace configurations.
    case set
    public static let editableCases: [Self] = [.add, .modify, .remove]
    public var title: String {
        switch self {
        case .add: "添加"
        case .modify: "修改"
        case .remove: "删除"
        case .set: "添加或覆盖（旧配置）"
        }
    }
}

public struct HeaderEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Missing operations inherit the legacy step kind.
    public var operation: HeaderOperation?
    public var name: String
    public var value: String
    public init(operation: HeaderOperation? = nil, name: String = "", value: String = "") {
        self.operation = operation; self.name = name; self.value = value
    }
}

public enum QueryParameterOperation: String, Codable, CaseIterable, Sendable {
    case add, modify, remove
}

public struct QueryParameterEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// nil preserves the legacy add-or-replace behavior until an operation is chosen.
    public var operation: QueryParameterOperation?
    public var matchRule: WorkflowMatchRule
    public var name: String
    public var value: String
    public init(operation: QueryParameterOperation? = .add, name: String = "", value: String = "", matchRule: WorkflowMatchRule = .equals) {
        self.operation = operation; self.name = name; self.value = value; self.matchRule = matchRule
    }
    private enum CodingKeys: String, CodingKey { case id, operation, matchRule, name, value }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        operation = try values.decodeIfPresent(QueryParameterOperation.self, forKey: .operation)
        matchRule = try values.decodeIfPresent(WorkflowMatchRule.self, forKey: .matchRule) ?? .equals
        name = try values.decode(String.self, forKey: .name)
        value = try values.decode(String.self, forKey: .value)
    }
}

public struct WorkspaceEnvironment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var variables: [NamedValue] = []
    public init(name: String) { self.name = name }
    public var valueTypes: [String: EnvironmentValueType] {
        variables.reduce(into: [:]) { if !$1.name.isEmpty { $0[$1.name] = $1.type } }
    }
    public var values: [String: String] {
        variables.reduce(into: [:]) { if !$1.name.isEmpty { $0[$1.name] = $1.value } }
    }
}

public enum ModificationKind: String, Codable, CaseIterable, Sendable {
    case setHeader, removeHeader, replaceBody, rewriteURL, setQueryParameter, replaceURLString, setMethod, setStatus, mock, redirect, script, delay
    public var title: String {
        switch self {
        case .setHeader, .removeHeader: "修改 Header"
        case .replaceBody: "替换 Body"
        case .rewriteURL: "改写请求 URL"
        case .setQueryParameter: "修改查询参数"
        case .replaceURLString: "替换 URL 字符串"
        case .setMethod: "修改请求方法"
        case .setStatus: "修改状态码"
        case .mock: "返回静态数据"
        case .redirect: "返回重定向"
        case .script: "执行脚本"
        case .delay: "添加延迟"
        }
    }
    public func supports(response: Bool) -> Bool {
        response ? ![.rewriteURL, .setQueryParameter, .replaceURLString, .setMethod, .mock].contains(self) : ![.setStatus, .delay].contains(self)
    }
}

public struct URLReplacementEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var search: String
    public var replacement: String
    public init(search: String = "", replacement: String = "") {
        self.search = search; self.replacement = replacement
    }
}

public struct ModificationStep: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: ModificationKind
    public var enabled = true
    public var name = ""
    public var value = ""
    public var status = 200
    /// nil reads the legacy single name/value pair; an empty array is an empty step.
    public var headers: [HeaderEntry]?
    public var queryParameters: [QueryParameterEntry]?
    public var urlReplacements: [URLReplacementEntry]?
    public var urlReplacementEntries: [URLReplacementEntry] {
        get {
            if let urlReplacements { return urlReplacements }
            var entry = URLReplacementEntry(search: name, replacement: value)
            entry.id = id
            return [entry]
        }
        set { urlReplacements = newValue }
    }
    public var queryParameterEntries: [QueryParameterEntry] {
        get {
            if let queryParameters { return queryParameters }
            var entry = QueryParameterEntry(operation: name.isEmpty && value.isEmpty ? .add : nil, name: name, value: value)
            entry.id = id
            return [entry]
        }
        set { queryParameters = newValue }
    }
    public var headerEntries: [HeaderEntry] {
        get {
            let entries: [HeaderEntry]
            if let headers { entries = headers }
            else {
                var entry = HeaderEntry(operation: kind == .setHeader && name.isEmpty && value.isEmpty ? .add : nil, name: name, value: value); entry.id = id
                entries = [entry]
            }
            return entries.map { entry in
                var entry = entry
                if entry.operation == nil { entry.operation = kind == .removeHeader ? .remove : .set }
                return entry
            }
        }
        set { headers = newValue }
    }
    public var scriptOptions: ScriptOptions?
    public init(kind: ModificationKind) {
        self.kind = kind
        if kind == .redirect { status = 302 }
        if kind == .mock { value = "{\n  \"ok\": true\n}" }
        if kind == .delay { value = "1000" }
    }
}

public struct RequestWorkflow: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var enabled = true
    public var method = "*"
    public var matchTarget: WorkflowMatchTarget = .url
    public var matchRule: WorkflowMatchRule = .wildcard
    public var matchHeaderEnabled = false
    public var matchHeaderName = ""
    public var matchHeaderRule: WorkflowMatchRule = .equals
    public var matchHeaderPattern = ""
    public var matchPattern = "http://localhost:3000/*"
    public var requestSteps: [ModificationStep] = []
    public var responseSteps: [ModificationStep] = []
    public init(name: String = "新的请求修改") { self.name = name }

    /// Compatibility for existing callers. Persisted v1 prefixes migrate without widening matches.
    public var urlPrefix: String {
        get { matchPattern }
        set {
            matchTarget = .url; matchRule = .regex
            matchPattern = newValue.isEmpty ? "" : "\\A" + NSRegularExpression.escapedPattern(for: newValue)
        }
    }
    public func matches(method: String, url: String, headers: [HTTPField] = []) -> Bool {
        enabled && (self.method == "*" || self.method.caseInsensitiveCompare(method) == .orderedSame)
            && WorkflowMatcher.matches(target: matchTarget, rule: matchRule, pattern: matchPattern, url: url)
            && (!matchHeaderEnabled || WorkflowMatcher.matchesHeader(name: matchHeaderName, rule: matchHeaderRule,
                                                                      pattern: matchHeaderPattern, headers: headers))
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, method, matchTarget, matchRule, matchPattern, matchHeaderEnabled, matchHeaderName, matchHeaderRule, matchHeaderPattern, requestSteps, responseSteps
    }
    private enum LegacyKeys: String, CodingKey { case urlPrefix }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        method = try values.decode(String.self, forKey: .method)
        requestSteps = try values.decode([ModificationStep].self, forKey: .requestSteps)
        responseSteps = try values.decode([ModificationStep].self, forKey: .responseSteps)
        matchHeaderEnabled = try values.decodeIfPresent(Bool.self, forKey: .matchHeaderEnabled) ?? false
        matchHeaderRule = try values.decodeIfPresent(WorkflowMatchRule.self, forKey: .matchHeaderRule) ?? .equals
        matchHeaderPattern = try values.decodeIfPresent(String.self, forKey: .matchHeaderPattern) ?? ""
        matchHeaderName = try values.decodeIfPresent(String.self, forKey: .matchHeaderName) ?? ""
        if values.contains(.matchPattern) {
            let target = try values.decode(String.self, forKey: .matchTarget)
            if target == "header" {
                // Preserve previously saved Header-only rules as an unrestricted URL plus Header condition.
                matchTarget = .url; matchRule = .wildcard; matchPattern = "*"
                matchHeaderEnabled = true
                matchHeaderRule = try values.decode(WorkflowMatchRule.self, forKey: .matchRule)
                matchHeaderPattern = try values.decode(String.self, forKey: .matchPattern)
                return
            }
            matchTarget = try values.decode(WorkflowMatchTarget.self, forKey: .matchTarget)
            matchRule = try values.decode(WorkflowMatchRule.self, forKey: .matchRule)
            matchPattern = try values.decode(String.self, forKey: .matchPattern)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            urlPrefix = try legacy.decode(String.self, forKey: .urlPrefix)
        }
    }
}

public struct WorkflowProject: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var workflows: [RequestWorkflow] = []
    public var enabled = true
    public var symbol = "folder"
    public init(name: String = "新项目") { self.name = name }
    private enum CodingKeys: String, CodingKey { case id, name, workflows, enabled, symbol }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        workflows = try values.decode([RequestWorkflow].self, forKey: .workflows)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        symbol = try values.decodeIfPresent(String.self, forKey: .symbol) ?? "folder"
    }
    public func duplicated() -> WorkflowProject {
        var copy = self
        copy.id = UUID()
        copy.workflows = workflows.map { $0.duplicated() }
        return copy
    }
}

public struct ExplicitProxyConfiguration: Codable, Equatable, Sendable {
    public var port: Int = 9090
    public var upstream: UpstreamRoute = .system
    public init() {}
    public func validate() throws {
        guard (1024...65535).contains(port) else { throw WorkflowError.invalid("监听端口需在 1024–65535 之间") }
        if case .httpProxy(let endpoint) = upstream {
            try endpoint.validate()
            guard !(endpoint.port == port && ["localhost", "127.0.0.1", "::1"].contains(endpoint.host.lowercased())) else {
                throw WorkflowError.invalid("上游不能指向本地监听端口")
            }
        }
    }
}

public struct WorkspaceDocument: Codable, Equatable, Sendable {
    public var version = 2
    public var projects: [WorkflowProject] = []
    public var environments: [WorkspaceEnvironment] = []
    public var selectedEnvironmentID: UUID?
    public var proxy = ExplicitProxyConfiguration()
    public init() {}
    public var environment: WorkspaceEnvironment? { environments.first { $0.id == selectedEnvironmentID } }
}

public enum WorkflowError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}

/// Disk work is serialized off the main actor. No execution record or body is persisted here.
public actor WorkspaceDocumentStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> WorkspaceDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkspaceDocument() }
        var document = try JSONDecoder().decode(WorkspaceDocument.self, from: Data(contentsOf: url))
        guard [1, 2].contains(document.version) else { throw WorkflowError.invalid("不支持此工作区版本，未覆盖原文件") }
        document.version = 2
        return document
    }
    public func save(_ document: WorkspaceDocument) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension RequestWorkflow {
    public func duplicated() -> RequestWorkflow {
        var copy = self
        copy.id = UUID()
        copy.requestSteps = requestSteps.map { var step = $0; step.id = UUID(); return step }
        copy.responseSteps = responseSteps.map { var step = $0; step.id = UUID(); return step }
        return copy
    }
}
