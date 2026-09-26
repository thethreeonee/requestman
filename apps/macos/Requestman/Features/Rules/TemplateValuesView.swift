import AppKit
import RequestmanCore

@MainActor final class TemplateValuesViewController: NSViewController {
    let rows: [TemplateValueRow]
    init(response: Bool, environment: [NamedValue], onCopy: @escaping (String) -> Void = { text in
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }) {
        let names = Array(Set(environment.map(\.name).filter { !$0.isEmpty })).sorted()
        let environments = names.isEmpty ? [(name: "$env.变量名", description: "环境变量")]
            : names.map { (name: "$env." + $0, description: "环境变量") }
        let variables = environments + WorkflowTemplateContext.variables.filter { response || $0.name != "$response.status" }
        rows = variables.map { TemplateValueRow(template: "{{\($0.name)}}", detail: $0.description, onCopy: onCopy) }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        let title = NativeUI.label("动态值", size: 14, weight: .semibold)
        let stack = NativeUI.stack(rows, spacing: 0)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let document = FlippedView(); NativeUI.pin(stack, to: document)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let content = NativeUI.stack([title, scroll], spacing: 10)
        NativeUI.pin(content, to: view, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        preferredContentSize = NSSize(width: 340, height: min(550, 56 + rows.count * 28))
    }
}

@MainActor final class TemplateValueRow: NSView {
    let template: String
    let copyButton: TemplateCopyButton
    private var tracking: NSTrackingArea?
    private var hovered = false
    init(template: String, detail: String, onCopy: @escaping (String) -> Void) {
        self.template = template
        copyButton = TemplateCopyButton { onCopy(template) }
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        let name = NativeUI.label(template, size: 12)
        name.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        name.isSelectable = true; name.toolTip = template
        let description = NativeUI.label(detail, size: 11, secondary: true)
        description.toolTip = detail
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = NativeUI.stack([name, description, spacer, copyButton], vertical: false, spacing: 10)
        NativeUI.pin(content, to: self)
        copyButton.setAccessibilityLabel("复制 " + template)
        copyButton.toolTip = "复制 " + template
        copyButton.focusChanged = { [weak self] in self?.updateCopyVisibility(animated: false) }
        copyButton.alphaValue = 0
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ value: Bool) { hovered = value; updateCopyVisibility(animated: true) }
    private func updateCopyVisibility(animated: Bool) {
        let visible = hovered || copyButton.hasKeyboardFocus
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            copyButton.animator().alphaValue = visible ? 1 : 0
        }
    }
}

@MainActor final class TemplateCopyButton: NSButton {
    private let onCopy: () -> Void
    var focusChanged: (() -> Void)?
    private(set) var hasKeyboardFocus = false
    init(onCopy: @escaping () -> Void) {
        self.onCopy = onCopy; super.init(frame: .zero)
        title = ""; image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        imagePosition = .imageOnly; bezelStyle = .rounded; controlSize = .small
        target = self; action = #selector(copyValue)
        widthAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    @objc private func copyValue() { onCopy() }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); hasKeyboardFocus = result; focusChanged?(); return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { hasKeyboardFocus = false }; focusChanged?()
        return result
    }
}
