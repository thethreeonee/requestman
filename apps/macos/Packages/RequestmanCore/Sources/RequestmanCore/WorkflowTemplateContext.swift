import Foundation

/// One immutable snapshot shared by both stages, including flows run off the event loop.
public struct WorkflowTemplateContext: Sendable {
    private let values: [String: String]

    public init(id: UUID, date: Date, request: HTTPMessageDraft? = nil) {
        let iso = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let hex = Array("0123456789abcdef")
        var values = [
            "$uuid": id.uuidString,
            "$timestamp": String(Int(date.timeIntervalSince1970.rounded(.down))),
            "$timestampMs": String(Int((date.timeIntervalSince1970 * 1000).rounded(.down))),
            "$isoDateTime": iso,
            "$date": String(iso.prefix(10)),
            "$time": String(iso.dropFirst(11).prefix(8)),
            "$randomInt": String(Int.random(in: 0...999_999)),
            "$randomFloat": String(Double.random(in: 0..<1)),
            "$randomBoolean": Bool.random() ? "true" : "false",
            "$randomString": String((0..<16).map { _ in letters.randomElement()! }),
            "$randomHex": String((0..<32).map { _ in hex.randomElement()! }),
        ]
        if let request {
            values["$request.method"] = request.method
            values["$request.url"] = request.url
            if let url = URLComponents(string: request.url) {
                values["$request.host"] = url.host
                values["$request.path"] = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
            }
        }
        self.values = values
    }

    func value(for key: String, responseStatus: Int?) throws -> String {
        if key == "$response.status" {
            guard let responseStatus else { throw WorkflowError.invalid("$response.status 仅在响应阶段可用") }
            return String(responseStatus)
        }
        guard let value = values[key] else { throw WorkflowError.invalid("未找到变量：\(key)") }
        return value
    }

    /// The editor uses the same catalog as the execution contract.
    public static let variables: [(name: String, description: String)] = [
        ("$uuid", "事务 UUID"), ("$timestamp", "Unix 秒"), ("$timestampMs", "Unix 毫秒"),
        ("$isoDateTime", "UTC 日期时间，含毫秒"), ("$date", "UTC 日期 yyyy-MM-dd"), ("$time", "UTC 时间 HH:mm:ss"),
        ("$randomInt", "整数 0–999999"), ("$randomFloat", "小数 [0, 1)"), ("$randomBoolean", "true / false"),
        ("$randomString", "16 位字母和数字"), ("$randomHex", "32 位小写十六进制"),
        ("$request.method", "原始请求方法"), ("$request.url", "原始完整 URL"),
        ("$request.host", "原始主机，不含端口"), ("$request.path", "原始路径，不含查询"),
        ("$response.status", "响应阶段入口状态码（含 Mock）"),
    ]
}
