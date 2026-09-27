import Foundation

/// A complete, literal HTTP request. Replay never expands templates or evaluates body text.
public struct RequestReplayDraft: Sendable, Equatable {
    public var id = UUID()
    public var sourceRecordID: UUID?
    public var httpVersion = "HTTP/1.1"
    public var method: String
    public var url: String
    public var headers: [HTTPField]
    public var body: Data

    public init(method: String, url: String, headers: [HTTPField], body: Data) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }

    public init(record: CaptureRecord) throws {
        if let reason = Self.unavailableReason(for: record) { throw WorkflowError.invalid(reason) }
        self.init(method: record.method, url: record.url, headers: Self.editableHeaders(record.requestHeaders), body: record.requestBody.data)
        httpVersion = record.clientHTTPVersion ?? "HTTP/1.1"
        sourceRecordID = record.id
    }

    public static func unavailableReason(for record: CaptureRecord) -> String? {
        guard record.captureProtocol != .webSocket, record.outcome != .tunnel else { return "WebSocket 和加密隧道不能作为 HTTP 请求重放" }
        guard !record.urlWasTruncated else { return "请求 URL 已截断" }
        guard !record.requestHeadersInfo.isTruncated, record.requestHeadersInfo.truncatedNames.isEmpty,
              record.requestHeadersInfo.originalCount <= record.requestHeaders.count else { return "请求头未完整采集" }
        guard record.requestBody.isComplete else { return "请求正文未完整采集" }
        do {
            try Self(method: record.method, url: record.url, headers: editableHeaders(record.requestHeaders), body: record.requestBody.data).validate()
            return nil
        } catch { return error.localizedDescription }
    }

    public func validate() throws {
        guard ["HTTP/1.1", "HTTP/2"].contains(httpVersion) else { throw WorkflowError.invalid("不支持此重放 HTTP 版本") }
        if httpVersion == "HTTP/2", URLComponents(string: url)?.scheme != "https" {
            throw WorkflowError.invalid("HTTP/2 重放要求 HTTPS 地址，不转换为 HTTP/1.1")
        }
        guard HTTPMessageValidation.isToken(method), !["CONNECT", "TRACE"].contains(method.uppercased()) else {
            throw WorkflowError.invalid("请输入有效的 HTTP 方法；不支持 CONNECT 或 TRACE 重放")
        }
        try HTTPMessageValidation.validateEditedURL(url)
        if let port = URLComponents(string: url)?.port, !(1...65535).contains(port) { throw WorkflowError.invalid("URL 端口必须在 1–65535 之间") }
        for field in headers { try HTTPMessageValidation.validateHeader(field.name, value: field.value) }
    }

    public static func editableHeaders(_ fields: [HTTPField]) -> [HTTPField] {
        let connectionFields = fields.filter { $0.name.lowercased() == "connection" }
            .flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let excluded = Set(HTTPMessageValidation.managedHeaders + connectionFields + ["proxy-connection", "proxy-authorization", "proxy-authenticate", "keep-alive", "te", "expect"])
        return fields.filter { !excluded.contains($0.name.lowercased()) }
    }

    public static func parseHeaders(_ text: String) throws -> [HTTPField] {
        try text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line in
            guard let colon = line.firstIndex(of: ":") else { throw WorkflowError.invalid("每行请求头应使用“名称: 值”格式") }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            try HTTPMessageValidation.validateHeader(name, value: value)
            return HTTPField(name, value)
        }
    }
}
