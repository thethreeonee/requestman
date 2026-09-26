import AppKit

/// Mirrored from ModifyHeadersRuleDetail.tsx / COMMON_HEADERS. Keep names and order identical.
@MainActor final class HeaderNameField: NSComboBox, NSComboBoxDelegate {
    static let suggestions = [
        "Accept", "Accept-Encoding", "Accept-Language", "Authorization", "Cache-Control",
        "Content-Length", "Content-Type", "Cookie", "Host", "Origin", "Pragma", "Referer",
        "Operation-Type", "User-Agent", "X-Forwarded-For", "X-Requested-With", "ETag",
        "If-Modified-Since", "Last-Modified", "Location", "Set-Cookie", "Access-Control-Allow-Origin",
        "Access-Control-Allow-Headers", "Access-Control-Allow-Methods", "Access-Control-Expose-Headers",
    ]
    var onChange: (String) -> Void
    init(name: String = "", onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        addItems(withObjectValues: Self.suggestions)
        isEditable = true; completes = true; numberOfVisibleItems = 12
        placeholderString = "选择或输入 Header"
        setAccessibilityLabel("Header 名称")
        delegate = self; stringValue = name
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ notification: Notification) { onChange(stringValue) }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let name = objectValueOfSelectedItem as? String else { return }
        stringValue = name; onChange(name)
    }
}
