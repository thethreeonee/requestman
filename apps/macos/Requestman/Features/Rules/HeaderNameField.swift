import AppKit
import SwiftUI

/// Mirrored from ModifyHeadersRuleDetail.tsx / COMMON_HEADERS. Keep names and order identical.
struct HeaderNameField: NSViewRepresentable {
    @Binding var name: String
    static let suggestions = [
        "Accept",
        "Accept-Encoding",
        "Accept-Language",
        "Authorization",
        "Cache-Control",
        "Content-Length",
        "Content-Type",
        "Cookie",
        "Host",
        "Origin",
        "Pragma",
        "Referer",
        "Operation-Type",
        "User-Agent",
        "X-Forwarded-For",
        "X-Requested-With",
        "ETag",
        "If-Modified-Since",
        "Last-Modified",
        "Location",
        "Set-Cookie",
        "Access-Control-Allow-Origin",
        "Access-Control-Allow-Headers",
        "Access-Control-Allow-Methods",
        "Access-Control-Expose-Headers",
    ]
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSComboBox {
        let control = NSComboBox()
        control.addItems(withObjectValues: Self.suggestions)
        control.isEditable = true
        control.completes = true
        control.numberOfVisibleItems = 12
        control.placeholderString = "选择或输入 Header"
        control.setAccessibilityLabel("Header 名称")
        control.delegate = context.coordinator
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if control.stringValue != name { control.stringValue = name }
        control.isEnabled = context.environment.isEnabled
    }
    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: HeaderNameField
        init(parent: HeaderNameField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let control = notification.object as? NSComboBox else { return }
            parent.name = control.stringValue
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let control = notification.object as? NSComboBox, let name = control.objectValueOfSelectedItem as? String else { return }
            parent.name = name
        }
    }
}
