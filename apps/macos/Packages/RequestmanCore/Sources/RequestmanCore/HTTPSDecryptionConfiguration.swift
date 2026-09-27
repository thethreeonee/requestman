import Foundation

/// Decides whether a new CONNECT connection may use the local TLS identity.
public struct HTTPSDecryptionConfiguration: Codable, Equatable, Sendable {
    public var decryptAllRequests = true
    public var domains: [String] = []

    public init() {}

    public func shouldDecrypt(host: String) -> Bool {
        if decryptAllRequests { return true }
        let host = Self.normalized(host)
        return domains.contains { entry in
            let pattern = Self.normalized(entry)
            guard Self.isValid(pattern) else { return false }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst())
                return host.count > suffix.count && host.hasSuffix(suffix)
            }
            return host == pattern
        }
    }

    public static func parseDomains(_ text: String) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for entry in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }) {
            let pattern = normalized(String(entry))
            guard isValid(pattern) else {
                throw WorkflowError.invalid("域名格式无效：\(entry)。请输入域名或 *.example.com，不包含协议、端口或路径。")
            }
            if seen.insert(pattern).inserted { result.append(pattern) }
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func isValid(_ pattern: String) -> Bool {
        let domain = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
        guard !domain.isEmpty, domain.utf8.count <= 253 else { return false }
        return domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
