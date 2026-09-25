import AppKit
import SwiftUI
import Observation

@MainActor @Observable final class HeaderValue {
    var name = "X-Initial"
}
struct HeaderFieldHost: View {
    @Bindable var value: HeaderValue
    var body: some View { HeaderNameField(name: $value.name).frame(width: 260) }
}
@main @MainActor struct HeaderNameFieldChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let value = HeaderValue()
        let host = NSHostingController(rootView: HeaderFieldHost(value: value))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        let control = findCombo(host.view)!
        precondition(control.isEditable && control.completes)
        precondition(control.objectValues as? [String] == HeaderNameField.suggestions)
        precondition(control.stringValue == "X-Initial")
        control.selectItem(withObjectValue: "Operation-Type")
        control.delegate?.comboBoxSelectionDidChange?(Notification(name: NSComboBox.selectionDidChangeNotification, object: control))
        precondition(value.name == "Operation-Type")
        control.stringValue = "X-Custom-Header"
        control.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: control))
        precondition(value.name == "X-Custom-Header")
        value.name = "Set-Cookie"
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(control.stringValue == "Set-Cookie")
        print("Native Header combo checks passed: candidate selection, custom input and model-to-control updates. No App built or launched.")
    }
    static func findCombo(_ view: NSView) -> NSComboBox? {
        if let combo = view as? NSComboBox { return combo }
        return view.subviews.compactMap(findCombo).first
    }
}
