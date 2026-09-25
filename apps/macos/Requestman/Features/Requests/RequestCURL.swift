import Foundation
import RequestmanCore

/// Replays the captured HTTP entity, while curl rebuilds connection and transfer framing.
/// Only complete snapshots can be exported.
enum RequestCURL {
    enum Version { case original, modified }

    static func unavailableReason(for record: CaptureRecord, version: Version) -> String? {
        let request = snapshot(for: record, version: version)
        if request.urlWasTruncated { return "URL 已截断" }
        guard let url = URLComponents(string: request.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.fragment == nil,
              !request.url.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else {
            return "请求 URL 不可用"
        }
        guard isToken(request.method), request.method != "CONNECT" else { return "请求方法无法导出" }
        if request.info.isTruncated || !request.info.truncatedNames.isEmpty || request.info.originalCount > request.headers.count {
            return "请求头已截断"
        }
        if request.headers.contains(where: { !isToken($0.name) || $0.value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) }) {
            return "请求头包含无法导出的字符"
        }
        if request.headers.filter({ $0.name.lowercased() == "host" }).count > 1 {
            return "重复 Host 无法可靠导出"
        }
        switch request.body.state {
        case .notCollected: return "未采集请求正文"
        case .incomplete: return "请求正文未接收完整"
        case .unavailable: return request.body.unavailableReason ?? "请求正文不可用"
        case .complete: break
        }
        if request.body.isTruncated { return "请求正文已截断" }
        // curl's --head has no upload mode. Do not export a command that can hang waiting for a HEAD response body.
        if request.method == "HEAD" && !request.body.data.isEmpty { return "带正文的 HEAD 无法可靠导出" }
        return nil
    }

    static func command(for record: CaptureRecord, version: Version) -> String? {
        guard unavailableReason(for: record, version: version) == nil else { return nil }
        let request = snapshot(for: record, version: version)
        let connectionFields = request.headers.filter { $0.name.lowercased() == "connection" }
            .flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let framing = Set(connectionFields + ["connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization", "proxy-authenticate", "content-length"])
        let headers = request.headers.filter { !framing.contains($0.name.lowercased()) }
        let names = Set(headers.map { $0.name.lowercased() })
        var lines: [String] = []
        // --disable must be curl's first option; do not inherit ~/.curlrc options or credentials.
        var options = ["curl --disable", "--globoff", "--path-as-is", "--http1.1", "--request " + quote(request.method)]
        if request.method == "HEAD" { options.append("--head") }
        for field in headers {
            // In curl, Name: suppresses a header; Name; sends the captured empty header instead.
            options.append("--header " + quote(field.value.isEmpty ? field.name + ";" : field.name + ": " + field.value))
        }
        for name in ["Content-Type", "Accept", "User-Agent", "Expect"] where !names.contains(name.lowercased()) {
            options.append("--header " + quote(name + ":"))
        }
        let hasFraming = request.headers.contains { ["content-length", "transfer-encoding"].contains($0.name.lowercased()) }
        let bytes = request.body.data
        let text = request.body.isEncoded ? nil : String(data: bytes, encoding: .utf8).flatMap { $0.contains("\0") ? nil : $0 }
        if !bytes.isEmpty {
            // --data-raw treats even a leading @ as literal text; binary and encoded entities use stdin.
            if let text { options.append("--data-raw " + quote(text)) }
            else { options.append("--data-binary '@-'") }
        } else if hasFraming {
            if request.method == "HEAD" { options.append("--header 'Content-Length: 0'") }
            else { options.append("--data-binary ''") }
        }
        options.append("--url " + quote(request.url))
        let curl = options.joined(separator: " \\\n  ")
        if bytes.isEmpty || text != nil { lines.append(curl) }
        else { lines.append("printf '%s' " + quote(bytes.base64EncodedString()) + " | /usr/bin/base64 --decode | \\\n" + curl) }
        return lines.joined(separator: "\n")
    }

    private struct Snapshot {
        let method: String
        let url: String
        let urlWasTruncated: Bool
        let headers: [HTTPField]
        let info: CaptureHeadersInfo
        let body: CaptureBodySnapshot
    }

    private static func snapshot(for record: CaptureRecord, version: Version) -> Snapshot {
        switch version {
        case .original:
            Snapshot(method: record.method, url: record.url, urlWasTruncated: record.urlWasTruncated,
                     headers: record.requestHeaders, info: record.requestHeadersInfo, body: record.requestBody)
        case .modified:
            Snapshot(method: record.sentMethod, url: record.finalURL, urlWasTruncated: record.finalURLWasTruncated,
                     headers: record.sentHeaders, info: record.sentHeadersInfo, body: record.sentBody)
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || Array("!#$%&'*+-.^_`|~".utf8).contains($0)
        }
    }
}
