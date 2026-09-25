import Foundation

public struct HTTPField: Equatable, Sendable, Codable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public struct HTTPMessageDraft: Sendable {
    public var method: String
    public var url: String
    public var status: Int
    public var headers: [HTTPField]
    /// nil means stream the original body, including binary data, without inspection.
    public var replacementBody: String?
    public var isMock = false
    public init(method: String, url: String, status: Int = 200, headers: [HTTPField] = []) {
        self.method = method; self.url = url; self.status = status; self.headers = headers
    }
    public mutating func setHeader(_ name: String, _ value: String?) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let value { headers.append(HTTPField(name, value)) }
    }
}

public struct WorkflowMatch: Sendable {
    public let project: String
    public let workflow: RequestWorkflow
    public let environment: WorkspaceEnvironment?
}

public enum WorkflowEngine {
    /// First enabled match in project order wins, keeping rule composition deterministic.
    public static func match(_ document: WorkspaceDocument, method: String, url: String) -> WorkflowMatch? {
        for project in document.projects {
            if let workflow = project.workflows.first(where: { $0.matches(method: method, url: url) }) {
                return WorkflowMatch(project: project.name, workflow: workflow, environment: document.environment)
            }
        }
        return nil
    }

    public static func resolve(_ template: String, environment: [String: String], id: UUID, date: Date) throws -> String {
        // Single pass: values cannot inject a second template expansion.
        var output = ""
        var remaining = template[...]
        while let start = remaining.range(of: "{{") {
            output += remaining[..<start.lowerBound]
            guard let end = remaining[start.upperBound...].range(of: "}}") else {
                throw WorkflowError.invalid("动态值缺少 }}")
            }
            let key = remaining[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            switch key {
            case "$uuid": output += id.uuidString
            case "$timestamp": output += String(Int(date.timeIntervalSince1970))
            default:
                guard key.hasPrefix("env."), let value = environment[String(key.dropFirst(4))] else {
                    throw WorkflowError.invalid("未找到变量：\(key)")
                }
                output += value
            }
            remaining = remaining[end.upperBound...]
        }
        output += remaining
        return output
    }

    public static func apply(_ steps: [ModificationStep], response: Bool, to draft: inout HTTPMessageDraft,
                             environment: [String: String], id: UUID, date: Date) throws -> [String] {
        guard steps.count <= 64 else { throw WorkflowError.invalid("每个方向最多执行 64 个步骤") }
        var trace: [String] = []
        for step in steps where step.enabled {
            guard step.kind.supports(response: response) else { throw WorkflowError.invalid("步骤不适用于当前方向") }
            let value = try resolve(step.value, environment: environment, id: id, date: date)
            switch step.kind {
            case .setHeader, .removeHeader:
                guard isToken(step.name), !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
                    throw WorkflowError.invalid("Header 名称或值无效")
                }
                guard !["content-length", "transfer-encoding", "connection", "host", "upgrade", "trailer"].contains(step.name.lowercased()) else {
                    throw WorkflowError.invalid("\(step.name) 由代理根据目标和 Body 自动维护")
                }
                draft.setHeader(step.name, step.kind == .removeHeader ? nil : value)
            case .replaceBody: draft.replacementBody = value; clearBodyEncoding(&draft)
            case .rewriteURL:
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.fragment == nil else {
                    throw WorkflowError.invalid("当前目标改写只支持完整的 http:// 或 https:// 地址")
                }
                draft.url = value
            case .setMethod:
                guard isToken(value), !["CONNECT", "TRACE"].contains(value.uppercased()) else {
                    throw WorkflowError.invalid("不支持此请求方法")
                }
                draft.method = value.uppercased()
            case .setStatus:
                guard (200...599).contains(step.status) else { throw WorkflowError.invalid("状态码需在 200–599 之间") }
                draft.status = step.status
            case .mock:
                guard (200...599).contains(step.status) else { throw WorkflowError.invalid("Mock 状态码无效") }
                draft.isMock = true; draft.status = step.status; draft.replacementBody = value
                draft.headers = [HTTPField("Content-Type", "application/json; charset=utf-8")]
            case .redirect:
                guard [301,302,303,307,308].contains(step.status), let url = URL(string: value),
                      ["http", "https"].contains(url.scheme), url.host != nil,
                      !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw WorkflowError.invalid("重定向地址或状态码无效") }
                if !response { draft.headers = [] }
                draft.status = step.status; draft.setHeader("Location", value)
                draft.replacementBody = ""; draft.isMock = !response
                clearBodyEncoding(&draft)
            }
            trace.append(step.kind.title)
            if !response && draft.isMock { break }
        }
        return trace
    }

    private static func clearBodyEncoding(_ draft: inout HTTPMessageDraft) {
        for name in ["Content-Encoding", "ETag", "Content-MD5", "Digest", "Content-Range"] { draft.setHeader(name, nil) }
    }
    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || Array("!#$%&'*+-.^_`|~".utf8).contains($0) }
    }
}
