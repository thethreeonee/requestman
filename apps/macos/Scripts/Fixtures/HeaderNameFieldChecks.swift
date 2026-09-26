import AppKit

@main @MainActor struct HeaderNameFieldChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var name = "X-Initial"
        let control = HeaderNameField(name: name) { name = $0 }
        precondition(control.isEditable && control.completes)
        precondition(control.objectValues as? [String] == HeaderNameField.suggestions)
        precondition(control.stringValue == "X-Initial")
        control.selectItem(withObjectValue: "Operation-Type")
        control.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: control))
        precondition(name == "Operation-Type")
        control.stringValue = "X-Custom-Header"
        control.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: control))
        precondition(name == "X-Custom-Header")
        control.stringValue = "Set-Cookie"
        precondition(control.stringValue == "Set-Cookie")
        print("Native Header combo checks passed: candidate selection, custom input and control updates. No App built or launched.")
    }
}
