import Foundation

public struct HTTPField: Equatable, Sendable, Codable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public struct HTTPMessageDraft: Sendable, Codable {
    public var method: String
    public var url: String
    public var status: Int
    public var headers: [HTTPField]
    /// nil means stream the original body, including binary data, without inspection.
    public var replacementBody: String?
    public var bodyText: String?
    public var bodyData: Data?
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
    public static let managedHeaders = ["content-length", "transfer-encoding", "connection", "host", "upgrade", "trailer"]
    /// First enabled match in project order wins, keeping rule composition deterministic.
    public static func match(_ document: WorkspaceDocument, method: String, url: String, headers: [HTTPField] = []) -> WorkflowMatch? {
        for project in document.projects where project.enabled {
            if let workflow = project.workflows.first(where: { $0.matches(method: method, url: url, headers: headers) }) {
                return WorkflowMatch(project: project.name, workflow: workflow, environment: document.environment)
            }
        }
        return nil
    }

    public static func resolve(_ template: String, environment: [String: String], id: UUID, date: Date) throws -> String {
        try resolve(template, environment: environment, context: WorkflowTemplateContext(id: id, date: date))
    }

    public static func resolve(_ template: String, environment: [String: String], context: WorkflowTemplateContext,
                               responseStatus: Int? = nil) throws -> String {
        // Single pass: values cannot inject a second template expansion.
        var output = ""
        var remaining = template[...]
        while let start = remaining.range(of: "{{") {
            output += remaining[..<start.lowerBound]
            guard let end = remaining[start.upperBound...].range(of: "}}") else {
                throw WorkflowError.invalid("动态值缺少 }}")
            }
            let key = remaining[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("$env.") || key.hasPrefix("env.") {
                let prefix = key.hasPrefix("$env.") ? "$env." : "env."
                guard let value = environment[String(key.dropFirst(prefix.count))] else {
                    throw WorkflowError.invalid("未找到变量：\(key)")
                }
                output += value
            } else {
                output += try context.value(for: key, responseStatus: responseStatus)
            }
            remaining = remaining[end.upperBound...]
        }
        output += remaining
        return output
    }

    private static func validateHeader(_ name: String, value: String) throws {
        guard isToken(name), !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
            throw WorkflowError.invalid("Header 名称或值无效")
        }
        guard !managedHeaders.contains(name.lowercased()) else {
            throw WorkflowError.invalid("\(name) 由代理根据目标和 Body 自动维护")
        }
    }

    public static func apply(_ steps: [ModificationStep], response: Bool, to draft: inout HTTPMessageDraft,
                             environment: [String: String], id: UUID, date: Date,
                             request: HTTPMessageDraft? = nil, control: ScriptExecutionControl? = nil,
                             templateContext: WorkflowTemplateContext? = nil, originalResponseStatus: Int? = nil,
                             environmentTypes: [String: EnvironmentValueType] = [:],
                             onApplied: ((ModificationKind) -> Void)? = nil) throws -> [String] {
        guard steps.count <= 64 else { throw WorkflowError.invalid("每个方向最多执行 64 个步骤") }
        let context = templateContext ?? WorkflowTemplateContext(id: id, date: date, request: response ? request : draft)
        let responseStatus = response ? (originalResponseStatus ?? draft.status) : nil
        func resolveValue(_ text: String) throws -> String {
            try resolve(text, environment: environment, context: context, responseStatus: responseStatus)
        }
        var trace: [String] = []
        for step in steps where step.enabled {
            try control?.check()
            guard step.kind.supports(response: response) else { throw WorkflowError.invalid("步骤不适用于当前方向") }
            let value = [.script, .setHeader, .removeHeader, .setQueryParameter, .replaceURLString].contains(step.kind) ? step.value : try resolveValue(step.value)
            switch step.kind {
            case .delay:
                throw WorkflowError.invalid("延迟步骤需要异步执行流程")
            case .script:
                draft = try WorkflowScript.run(source: value, draft: draft, response: response, request: request,
                    environment: environment, timeoutMilliseconds: (step.scriptOptions ?? ScriptOptions()).timeoutMilliseconds, control: control, environmentTypes: environmentTypes)
            case .setHeader, .removeHeader:
                // Stage sequential edits so a later invalid entry cannot partially change the draft.
                var headers = draft.headers
                for entry in step.headerEntries {
                    try validateHeader(entry.name, value: "")
                    let matches = headers.indices.filter { headers[$0].name.caseInsensitiveCompare(entry.name) == .orderedSame }
                    switch entry.operation {
                    case .remove:
                        headers.removeAll { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
                    case .modify:
                        guard !matches.isEmpty else { continue }
                        let value = try resolveValue(entry.value)
                        try validateHeader(entry.name, value: value)
                        for index in matches { headers[index].value = value }
                    case .add:
                        let value = try resolveValue(entry.value)
                        try validateHeader(entry.name, value: value)
                        headers.append(HTTPField(entry.name, value))
                    case .set, nil:
                        let value = try resolveValue(entry.value)
                        try validateHeader(entry.name, value: value)
                        headers.removeAll { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
                        headers.append(HTTPField(entry.name, value))
                    }
                }
                draft.headers = headers
            case .replaceBody: draft.replacementBody = value; clearBodyEncoding(&draft)
            case .rewriteURL:
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.fragment == nil else {
                    throw WorkflowError.invalid("当前目标改写只支持完整的 http:// 或 https:// 地址")
                }
                draft.url = value
            case .setQueryParameter:
                // Stage the whole list locally so a later invalid entry cannot partially edit the URL.
                let entries: [QueryParameterEntry]
                if let configured = step.queryParameters { entries = configured }
                else { entries = [QueryParameterEntry(operation: nil, name: step.name, value: step.value)] }
                if entries.isEmpty { break }
                guard var components = URLComponents(string: draft.url) else {
                    throw WorkflowError.invalid("查询参数名称或 URL 无效")
                }
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                for entry in entries {
                    let name = try resolveValue(entry.name)
                    guard !name.isEmpty else { throw WorkflowError.invalid("查询参数名称不能为空") }
                    let matchRule = entry.operation == .modify || entry.operation == .remove ? entry.matchRule : .equals
                    if let error = WorkflowMatcher.validationError(rule: matchRule, pattern: name) {
                        throw WorkflowError.invalid("查询参数名称：" + error)
                    }
                    let parts = components.percentEncodedQuery.map { $0.isEmpty ? [] : $0.components(separatedBy: "&") } ?? []
                    func matches(_ part: String) -> Bool {
                        guard !part.isEmpty else { return false }
                        let key = String(part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                        guard let decoded = key.removingPercentEncoding else { return false }
                        return WorkflowMatcher.matchesQueryParameterName(decoded, rule: matchRule, pattern: name)
                    }
                    let exists = parts.contains(where: matches)
                    if entry.operation == .add && exists || entry.operation == .modify && !exists { continue }
                    if entry.operation == .remove {
                        guard exists else { continue }
                        let remaining = parts.filter { !matches($0) }
                        components.percentEncodedQuery = remaining.isEmpty ? nil : remaining.joined(separator: "&")
                        continue
                    }
                    let value = try resolveValue(entry.value)
                    let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)!
                    let pair = name.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + encodedValue
                    var updated: [String] = []
                    var replaced = false
                    for part in parts {
                        if matches(part) {
                            if entry.operation == .modify {
                                let key = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                                updated.append(String(key) + "=" + encodedValue)
                            } else if !replaced { updated.append(pair) }
                            replaced = true
                        } else { updated.append(part) }
                    }
                    if !replaced { updated.append(pair) }
                    components.percentEncodedQuery = updated.joined(separator: "&")
                }
                guard let url = components.string else { throw WorkflowError.invalid("查询参数修改后的 URL 无效") }
                try validateEditedURL(url)
                draft.url = url
            case .replaceURLString:
                var url = draft.url
                for entry in step.urlReplacementEntries {
                    let search = try resolveValue(entry.search)
                    guard !search.isEmpty else { throw WorkflowError.invalid("查找字符串不能为空") }
                    let replacement = try resolveValue(entry.replacement)
                    url = url.replacingOccurrences(of: search, with: replacement, options: .literal)
                    try validateEditedURL(url)
                }
                draft.url = url
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
            onApplied?(step.kind)
            if !response && draft.isMock { break }
        }
        return trace
    }

    /// Runs suspended steps in order without blocking a network or UI thread.
    public static func applyAsync(_ steps: [ModificationStep], response: Bool, to draft: inout HTTPMessageDraft,
                                  environment: [String: String], id: UUID, date: Date,
                                  request: HTTPMessageDraft? = nil, control: ScriptExecutionControl? = nil,
                                  templateContext: WorkflowTemplateContext? = nil,
                                  environmentTypes: [String: EnvironmentValueType] = [:],
                                  onApplied: ((ModificationKind) -> Void)? = nil) async throws -> [String] {
        guard steps.count <= 64 else { throw WorkflowError.invalid("每个方向最多执行 64 个步骤") }
        let control = control ?? ScriptExecutionControl()
        let context = templateContext ?? WorkflowTemplateContext(id: id, date: date, request: response ? request : draft)
        let responseStatus = response ? draft.status : nil
        var trace: [String] = []
        for step in steps where step.enabled {
            try Task.checkCancellation()
            try control.check()
            guard step.kind.supports(response: response) else { throw WorkflowError.invalid("步骤不适用于当前方向") }
            if step.kind == .delay {
                let milliseconds = try delayMilliseconds(step.value)
                let end = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
                while ContinuousClock.now < end {
                    try control.check()
                    try await Task.sleep(until: min(end, .now.advanced(by: .milliseconds(25))), clock: .continuous)
                }
                try Task.checkCancellation()
                try control.check()
                trace.append(step.kind.title)
                onApplied?(step.kind)
            } else {
                trace += try apply([step], response: response, to: &draft, environment: environment, id: id, date: date,
                                   request: request, control: control, templateContext: context,
                                   originalResponseStatus: responseStatus, environmentTypes: environmentTypes, onApplied: onApplied)
            }
            if !response && draft.isMock { break }
        }
        return trace
    }

    public static func delayMilliseconds(_ value: String) throws -> Int {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let milliseconds = Int(value) else {
            throw WorkflowError.invalid("延迟时间需为非负整数，单位 ms")
        }
        return milliseconds
    }

    private static func validateEditedURL(_ value: String) throws {
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else {
            throw WorkflowError.invalid("修改后的 URL 必须是完整的 http:// 或 https:// 地址，且不含空白、账号或片段")
        }
    }

    static func clearBodyEncoding(_ draft: inout HTTPMessageDraft) {
        for name in ["Content-Encoding", "ETag", "Content-MD5", "Digest", "Content-Range"] { draft.setHeader(name, nil) }
    }
    static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || Array("!#$%&'*+-.^_`|~".utf8).contains($0) }
    }
}
