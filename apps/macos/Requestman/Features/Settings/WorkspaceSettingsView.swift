import AppKit

enum WorkspaceSettingsSection: CaseIterable {
    case general, environments

    var title: String {
        switch self { case .general: "通用"; case .environments: "环境管理" }
    }
}

@MainActor
final class WorkspaceSettingsWindowController: NSWindowController {
    init(model: WorkspaceModel) {
        let controller = WorkspaceSettingsViewController(model: model)
        let window = NSWindow(contentViewController: controller)
        window.title = "设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)
        controller.installToolbar(on: window)
        window.setContentSize(NSSize(width: 800, height: 540))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}

@MainActor
final class WorkspaceSettingsViewController: ObservedViewController, NSToolbarDelegate {
    private let model: WorkspaceModel
    private let general: GeneralSettingsViewController
    private let environments: EnvironmentsViewController
    private var current: NSViewController?
    private lazy var tabs = ToolbarSectionControl(
        labels: WorkspaceSettingsSection.allCases.map(\.title), accessibilityLabel: "设置"
    ) { [weak self] index in
        guard let self, WorkspaceSettingsSection.allCases.indices.contains(index) else { return }
        self.model.settingsSection = WorkspaceSettingsSection.allCases[index]
    }
    private let tabsIdentifier = NSToolbarItem.Identifier("requestman.settings.sections")

    init(model: WorkspaceModel) {
        self.model = model
        general = GeneralSettingsViewController(model: model)
        environments = EnvironmentsViewController(model: model)
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 540)) }

    override func refresh() {
        tabs.selectedSegment = WorkspaceSettingsSection.allCases.firstIndex(of: model.settingsSection) ?? 0
        let next: NSViewController = model.settingsSection == .general ? general : environments
        guard current !== next else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(next)
        NativeUI.pin(next.view, to: view)
        current = next
    }

    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "requestman.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [tabsIdentifier]
        window.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [tabsIdentifier, .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, tabsIdentifier, .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == tabsIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "设置"
        item.view = tabs
        return item
    }
}

/// Shared native form layout for the settings panes. NSBox draws its system group border.
@MainActor
enum SettingsUI {
    static func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NativeUI.label(title)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NativeUI.stack([label, spacer, control], vertical: false, spacing: 12)
        stack.alignment = .centerY
        return stack
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func section(_ title: String, rows: [NSView], footer: String? = nil) -> NSView {
        let box = NSBox()
        box.title = title
        box.boxType = .primary
        box.contentViewMargins = NSSize(width: 12, height: 12)
        let content = NativeUI.stack(rows, spacing: 12)
        content.alignment = .leading
        for row in rows { row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        box.contentView = content
        if let footer {
            let stack = NativeUI.stack([box, note(footer)], spacing: 6)
            stack.alignment = .leading
            stack.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            return stack
        }
        return box
    }

    static func scroll(_ document: NSView, into parent: NSView, inset: CGFloat = 20) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let canvas = FlippedView()
        scroll.documentView = canvas
        canvas.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(document)
        NativeUI.pin(scroll, to: parent)
        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: inset),
            document.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -inset),
            document.topAnchor.constraint(equalTo: canvas.topAnchor, constant: inset),
            document.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -inset)
        ])
    }

    static func sync(_ field: NSTextField, _ value: String) {
        if field.currentEditor() == nil, field.stringValue != value { field.stringValue = value }
    }
}
