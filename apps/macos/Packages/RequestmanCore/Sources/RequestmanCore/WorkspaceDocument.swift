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
    /// Replace all same-name headers, or add the header when absent.
    case set
    public static let editableCases: [Self] = [.add, .modify, .remove, .set]
    public var title: String {
        switch self {
        case .add: "添加"
        case .modify: "修改"
        case .remove: "删除"
        case .set: "添加或覆盖"
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
    case setHeader, removeHeader, modifyJSON, replaceBody, rewriteURL, setQueryParameter, replaceURLString, setMethod, setStatus, mock, redirect, script, delay
    public var title: String {
        switch self {
        case .setHeader, .removeHeader: "修改 Header"
        case .modifyJSON: "修改 JSON"
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

public enum BodySource: String, Codable, Sendable { case text, file }

public enum BodyValueEncoding: String, Codable, Sendable { case text, base64 }

public enum URLRewriteTarget: String, Codable, CaseIterable, Sendable {
    case fullURL, host, path

    public var title: String {
        switch self {
        case .fullURL: "完整 URL"
        case .host: "主机"
        case .path: "路径"
        }
    }
}

public struct ModificationStep: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: ModificationKind
    public var enabled = true
    public var name = ""
    public var value = ""
    public var status = 200
    /// Captured values are literal by default; existing configurations continue resolving templates.
    public var literalValues: Bool?
    public var bodyEncoding: BodyValueEncoding?
    /// Content encoding of captured entity bytes retained as Base64.
    public var bodyContentEncoding: String?
    /// Missing in older workspaces means manual text input.
    public var bodySource: BodySource?
    public var bodyFilePath: String?
    public var usesBodyFile: Bool { [.replaceBody, .mock].contains(kind) && bodySource == .file }
    /// nil reads the legacy single name/value pair; an empty array is an empty step.
    public var headers: [HeaderEntry]?
    public var jsonEdits: [JSONEditEntry]?
    public var jsonEntries: [JSONEditEntry] {
        get { jsonEdits ?? [] }
        set { jsonEdits = newValue }
    }
    public var queryParameters: [QueryParameterEntry]?
    public var urlReplacements: [URLReplacementEntry]?
    /// Missing in older configurations keeps the complete URL rewrite behavior.
    public var urlRewriteTarget: URLRewriteTarget?
    public var effectiveURLRewriteTarget: URLRewriteTarget { urlRewriteTarget ?? .fullURL }
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
        if kind == .modifyJSON { jsonEdits = [JSONEditEntry()] }
    }
}

public struct RequestWorkflow: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var enabled = true
    public var matchConditions = WorkflowMatchGroup(conditions: [MatchCondition(field: .url, operation: .wildcard, value: "http://localhost:3000/*")])
    public var isSSE = false
    public var requestSteps: [ModificationStep] = []
    public var responseSteps: [ModificationStep] = []
    public init(name: String = "新的请求修改") { self.name = name }

    /// Insert a normal, editable response step once when SSE is enabled. Disabling preserves edits.
    public mutating func setSSE(_ enabled: Bool) {
        guard isSSE != enabled else { return }
        isSSE = enabled
        guard enabled else { return }
        let required = [("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-cache")]
        let missing = required.filter { name, value in
            !responseSteps.contains { step in
                step.enabled && step.kind == .setHeader && step.headerEntries.contains {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.value == value && $0.operation == .set
                }
            }
        }
        guard !missing.isEmpty else { return }
        var step = ModificationStep(kind: .setHeader)
        step.headers = missing.map { HeaderEntry(operation: .set, name: $0.0, value: $0.1) }
        responseSteps.append(step)
    }

    public func matches(method: String, url: String, headers: [HTTPField] = []) -> Bool {
        RuleMatchingEngine.matches(self, method: method, url: url, headers: headers)
    }
}

public struct WorkflowProject: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var workflows: [RequestWorkflow] = []
    public var enabled = true
    public var symbol = "folder"
    public init(name: String = "新规则组") { self.name = name }
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
    public var allowLAN = false
    public var upstream: UpstreamRoute = .system
    public init() {}
    private enum CodingKeys: String, CodingKey { case port, allowLAN, upstream }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        port = try values.decode(Int.self, forKey: .port)
        allowLAN = try values.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        upstream = try values.decode(UpstreamRoute.self, forKey: .upstream)
    }
    public func validate() throws {
        guard (1024...65535).contains(port) else { throw WorkflowError.invalid("监听端口需在 1024–65535 之间") }
        if case .httpProxy(let endpoint) = upstream {
            try endpoint.validate()
            guard !(endpoint.port == port && LocalNetwork.isLocalHost(endpoint.host)) else {
                throw WorkflowError.invalid("上游不能指向本地监听端口")
            }
        }
    }
}

public struct WorkspaceDocument: Codable, Equatable, Sendable {
    public var version = 3
    public var projects: [WorkflowProject] = []
    public var environments: [WorkspaceEnvironment] = []
    public var selectedEnvironmentID: UUID?
    public var proxy = ExplicitProxyConfiguration()
    public var httpsDecryption = HTTPSDecryptionConfiguration()
    public var deviceAliases: [String: String] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case version, projects, environments, selectedEnvironmentID, proxy, httpsDecryption, deviceAliases
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        projects = try values.decode([WorkflowProject].self, forKey: .projects)
        environments = try values.decode([WorkspaceEnvironment].self, forKey: .environments)
        selectedEnvironmentID = try values.decodeIfPresent(UUID.self, forKey: .selectedEnvironmentID)
        proxy = try values.decode(ExplicitProxyConfiguration.self, forKey: .proxy)
        httpsDecryption = try values.decodeIfPresent(HTTPSDecryptionConfiguration.self, forKey: .httpsDecryption) ?? .init()
        deviceAliases = try values.decodeIfPresent([String: String].self, forKey: .deviceAliases) ?? [:]
    }
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
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: Data(contentsOf: url))
        guard document.version == 3 else { throw WorkflowError.invalid("不支持此工作区版本，未覆盖原文件") }
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
        copy.matchConditions = matchConditions.duplicated()
        copy.requestSteps = requestSteps.map { var step = $0; step.id = UUID(); return step }
        copy.responseSteps = responseSteps.map { var step = $0; step.id = UUID(); return step }
        return copy
    }
}
