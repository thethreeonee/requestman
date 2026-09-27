import Foundation

public enum HTTPMessageValidation {
    public static let managedHeaders = ["content-length", "transfer-encoding", "connection", "host", "upgrade", "trailer"]
    public static func validateHeader(_ name: String, value: String) throws {
        guard isToken(name), !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
            throw WorkflowError.invalid("Header 名称或值无效")
        }
        guard !managedHeaders.contains(name.lowercased()) else {
            throw WorkflowError.invalid("\(name) 由代理根据目标和 Body 自动维护")
        }
    }

    public static func validateEditedURL(_ value: String) throws {
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else {
            throw WorkflowError.invalid("修改后的 URL 必须是完整的 http:// 或 https:// 地址，且不含空白、账号或片段")
        }
    }

    public static func clearBodyEncoding(_ draft: inout HTTPMessageDraft) {
        for name in ["Content-Encoding", "ETag", "Content-MD5", "Digest", "Content-Range"] { draft.setHeader(name, nil) }
    }
    public static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || Array("!#$%&'*+-.^_`|~".utf8).contains($0) }
    }
}
