import Foundation

/// Turns one immutable capture into editable steps, using the original request and available origin response.
public enum CapturedMockWorkflow {
    public static func unavailableReason(for record: CaptureRecord) -> String? {
        guard record.captureProtocol == .http else { return "持续事件与 WebSocket 会话暂不支持生成完整 Mock。" }
        guard record.outcome != .tunnel, record.method.uppercased() != "CONNECT" else { return "加密隧道没有可用的 HTTP 请求。" }
        guard !record.urlWasTruncated, !record.requestHeadersInfo.isTruncated,
              record.requestHeadersInfo.truncatedNames.isEmpty else { return "原始请求信息不完整。" }
        guard record.requestBody.isComplete else { return "请等待原始请求完整采集后再创建 Mock。" }
        guard HTTPMessageValidation.isToken(record.method), !["TRACE", "PRI"].contains(record.method.uppercased()),
              let url = URLComponents(string: record.url), ["http", "https"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { return "当前请求的方法或 URL 不支持创建 Mock。" }
        return nil
    }

    /// The host supplies its content decoder. Unsupported encodings remain lossless Base64.
    public static func make(from record: CaptureRecord,
                            decodeBody: ((CaptureBodySnapshot) throws -> Data)? = nil) throws -> RequestWorkflow {
        if let reason = unavailableReason(for: record) { throw WorkflowError.invalid(reason) }
        let path = URLComponents(string: record.url)?.path ?? ""
        var workflow = RequestWorkflow(name: "Mock \(record.method) \(path.isEmpty ? "/" : path)")
        workflow.matchConditions = WorkflowMatchGroup(conditions: [
            MatchCondition(field: .method, operation: .equals, value: record.method),
            MatchCondition(field: .url, operation: .equals, value: record.url)
        ])
        let request = bodyStep(record.requestBody, headers: record.requestHeaders, decodeBody: decodeBody)
        workflow.requestSteps = [step(.setMethod, value: record.method), step(.rewriteURL, value: record.url),
                                 request.body, headerStep(request.headers)]
        if let originalStatus = record.originalStatus, (200...599).contains(originalStatus),
           record.receivedBody.isComplete, !record.receivedHeadersInfo.isTruncated,
           record.receivedHeadersInfo.truncatedNames.isEmpty {
            let response = bodyStep(record.receivedBody, headers: record.receivedHeaders, decodeBody: decodeBody)
            var status = step(.setStatus)
            status.status = originalStatus
            workflow.responseSteps = [status, response.body, headerStep(response.headers)]
        }
        return workflow
    }

    private static func step(_ kind: ModificationKind, value: String = "") -> ModificationStep {
        var result = ModificationStep(kind: kind)
        result.literalValues = true; result.value = value
        return result
    }

    private static func bodyStep(_ snapshot: CaptureBodySnapshot, headers: [HTTPField],
                                 decodeBody: ((CaptureBodySnapshot) throws -> Data)?) -> (body: ModificationStep, headers: [HTTPField]) {
        var bytes = snapshot.data
        var fields = headers
        var encoded = snapshot.isEncoded
        if encoded, let decodeBody, let decoded = try? decodeBody(snapshot) {
            bytes = decoded; encoded = false
            fields.removeAll { ["content-encoding", "etag", "content-md5", "digest", "content-range"].contains($0.name.lowercased()) }
        }
        var body = step(.replaceBody)
        if !encoded, let text = String(data: bytes, encoding: .utf8), !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) {
            body.value = text
        } else {
            body.bodyEncoding = .base64
            body.value = bytes.base64EncodedString()
            if encoded { body.bodyContentEncoding = snapshot.contentEncoding }
        }
        return (body, fields)
    }

    private static func headerStep(_ fields: [HTTPField]) -> ModificationStep {
        // Framing/connection fields are regenerated, including Connection-nominated extensions.
        let connectionFields = fields.filter { $0.name.lowercased() == "connection" }
            .flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        let excluded = Set(HTTPMessageValidation.managedHeaders + ["proxy-connection", "keep-alive", "te", "expect"] + connectionFields)
        let retained = fields.filter { !excluded.contains($0.name.lowercased()) }
        var result = step(.setHeader)
        result.headers = retained.map { HeaderEntry(operation: .modify, name: $0.name, value: $0.value) }
        return result
    }
}
