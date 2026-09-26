import Foundation

public struct NamedValue: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var value: String
    public init(name: String = "", value: String = "") { self.name = name; self.value = value }
}

public struct WorkspaceEnvironment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var variables: [NamedValue] = []
    public init(name: String) { self.name = name }
    public var values: [String: String] {
        variables.reduce(into: [:]) { if !$1.name.isEmpty { $0[$1.name] = $1.value } }
    }
}

public enum ModificationKind: String, Codable, CaseIterable, Sendable {
    case setHeader, removeHeader, replaceBody, rewriteURL, setQueryParameter, replaceURLString, setMethod, setStatus, mock, redirect, script
    public var title: String {
        switch self {
        case .setHeader: "添加或覆盖 Header"
        case .removeHeader: "移除 Header"
        case .replaceBody: "替换 Body"
        case .rewriteURL: "切换目标地址"
        case .setQueryParameter: "修改查询参数"
        case .replaceURLString: "替换 URL 字符串"
        case .setMethod: "修改请求方法"
        case .setStatus: "修改状态码"
        case .mock: "返回静态数据"
        case .redirect: "重定向"
        case .script: "执行脚本"
        }
    }
    public func supports(response: Bool) -> Bool {
        response ? ![.rewriteURL, .setQueryParameter, .replaceURLString, .setMethod, .mock].contains(self) : self != .setStatus
    }
}

public struct ModificationStep: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: ModificationKind
    public var enabled = true
    public var name = ""
    public var value = ""
    public var status = 200
    public var scriptOptions: ScriptOptions?
    public init(kind: ModificationKind) {
        self.kind = kind
        if kind == .redirect { status = 302 }
        if kind == .mock { value = "{\n  \"ok\": true\n}" }
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
