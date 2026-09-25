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
    case setHeader, removeHeader, replaceBody, rewriteURL, setMethod, setStatus, mock, redirect
    public var title: String {
        switch self {
        case .setHeader: "设置 Header"
        case .removeHeader: "移除 Header"
        case .replaceBody: "替换 Body"
        case .rewriteURL: "切换目标地址"
        case .setMethod: "修改请求方法"
        case .setStatus: "修改状态码"
        case .mock: "返回静态数据"
        case .redirect: "重定向"
        }
    }
    public func supports(response: Bool) -> Bool {
        response ? ![.rewriteURL, .setMethod, .mock].contains(self) : self != .setStatus
    }
}

public struct ModificationStep: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: ModificationKind
    public var enabled = true
    public var name = ""
    public var value = ""
    public var status = 200
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
    /// Absolute URL prefix. An empty prefix never matches traffic.
    public var urlPrefix = "http://localhost:3000/"
    public var requestSteps: [ModificationStep] = []
    public var responseSteps: [ModificationStep] = []
    public init(name: String = "新的请求修改") { self.name = name }
    public func matches(method: String, url: String) -> Bool {
        enabled && !urlPrefix.isEmpty && (self.method == "*" || self.method == method) && url.hasPrefix(urlPrefix)
    }
}

public struct WorkflowProject: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var workflows: [RequestWorkflow] = []
    public init(name: String = "新项目") { self.name = name }
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
    public var version = 1
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
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw WorkflowError.invalid("不支持此工作区版本，未覆盖原文件") }
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
