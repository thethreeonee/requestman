import AppKit

/// Mirrored from ModifyHeadersRuleDetail.tsx / COMMON_HEADERS. Keep the same names; display in alphabetical order.
@MainActor final class HeaderNameField: ActionComboBox {
    static let suggestions = [
        "Accept", "Accept-Encoding", "Accept-Language", "Authorization", "Cache-Control",
        "Content-Length", "Content-Type", "Cookie", "Host", "Origin", "Pragma", "Referer",
        "Operation-Type", "User-Agent", "X-Forwarded-For", "X-Requested-With", "ETag",
        "If-Modified-Since", "Last-Modified", "Location", "Set-Cookie", "Access-Control-Allow-Origin",
        "Access-Control-Allow-Headers", "Access-Control-Allow-Methods", "Access-Control-Expose-Headers",
    ].sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    init(name: String = "", onChange: @escaping (String) -> Void) {
        super.init(name, placeholder: "选择或输入 Header", suggestions: Self.suggestions, completes: true, onChange: onChange)
        setAccessibilityLabel("Header 名称")
    }
    required init?(coder: NSCoder) { nil }
}
