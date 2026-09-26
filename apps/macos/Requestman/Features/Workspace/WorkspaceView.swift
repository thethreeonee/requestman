import AppKit
import RequestmanCore

/// AppKit owns the outer frame; each pane's controls occupy its system safe area.
@MainActor
class WorkspacePaneController: NSViewController {
    private var content: NSViewController?
    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = FlippedView() }

    func show(_ controller: NSViewController) {
        guard content !== controller else { return }
        if let content { content.view.removeFromSuperview(); content.removeFromParent() }
        content = controller
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }
}

@MainActor
final class WorkspaceSidebarController: WorkspacePaneController {
    let sidebar: ProjectSidebarViewController
    init(model: WorkspaceModel) { sidebar = ProjectSidebarViewController(model: model); super.init(); show(sidebar) }
    required init?(coder: NSCoder) { nil }
}

@MainActor
final class WorkspaceMainController: WorkspacePaneController {
    let rules: RulesViewController
    let requests: RequestsViewController
    init(model: WorkspaceModel) {
        rules = RulesViewController(model: model)
        requests = RequestsViewController(model: model)
        super.init()
        update(section: model.selection)
    }
    required init?(coder: NSCoder) { nil }
    func update(section: WorkspaceSection) { show(section == .rules ? rules : requests) }
}

@MainActor
final class WorkspaceInspectorController: WorkspacePaneController {
    let steps: StepInspectorViewController
    let requests: RequestInspectorViewController
    init(model: WorkspaceModel, mode: RequestInspectionMode) {
        steps = StepInspectorViewController(model: model)
        requests = RequestInspectorViewController(history: model.history, mode: mode)
        super.init()
        requests.workflowExists = { [weak model] id in
            model?.document.projects.contains { $0.workflows.contains { $0.id == id } } ?? false
        }
        requests.openWorkflow = { [weak model] id in
            guard let model, model.document.projects.contains(where: { $0.workflows.contains { $0.id == id } }) else { return }
            model.selectedWorkflowID = id
            model.selectedStepID = nil
            model.editingResponse = false
            model.selection = .rules
        }
    }
    required init?(coder: NSCoder) { nil }
    func update(section: WorkspaceSection, isPresented: Bool) {
        steps.isPresented = isPresented && section == .rules
        requests.isPresented = isPresented && section == .requests
        show(section == .rules ? steps : requests)
    }
}

@MainActor
final class EnvironmentSelectionPopover: ObservedViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: WorkspaceModel
    private let onDismiss: () -> Void
    private let openSettings: () -> Void
    private let search = NSSearchField()
    private let table = EnvironmentSelectionTable()
    private let scroll = NSScrollView()
    private var environments: [(id: UUID?, name: String)] = []
    private let empty = NativeUI.label("没有匹配的环境", secondary: true)
    private var scrollHeight: NSLayoutConstraint!
    private var updating = false

    init(model: WorkspaceModel, onDismiss: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model; self.onDismiss = onDismiss; self.openSettings = openSettings
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
        search.placeholderString = "筛选环境"; search.setAccessibilityLabel("筛选环境")
        search.delegate = self; search.sendsSearchStringImmediately = true
        table.headerView = nil; table.rowHeight = 32; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .sourceList
        table.addTableColumn(NSTableColumn(identifier: .init("environment")))
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(selectEnvironment(_:))
        table.confirm = { [weak self] in self?.confirmSelection() }
        table.dismiss = { [weak self] in self?.onDismiss() }
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
        scroll.documentView = table
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 180); scrollHeight.isActive = true
        let manage = ActionButton(title: "管理环境…") { [weak self] in
            guard let self else { return }
            model.settingsSection = .environments; onDismiss(); openSettings()
        }
        search.nextKeyView = table
        table.nextKeyView = manage
        manage.nextKeyView = search
        let stack = NativeUI.stack([search, NativeUI.label("环境", size: 11, secondary: true), scroll, empty, NativeUI.separator(), manage])
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        for item in [search, scroll] as [NSView] { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(search) }
    override func viewDidLayout() {
        super.viewDidLayout()
        updateListHeight()
    }
    override func refresh() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        environments = model.document.environments.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.map { ($0.id, $0.name) }
        if query.isEmpty || "无环境".localizedStandardContains(query) { environments.insert((nil, "无环境"), at: 0) }
        updating = true
        table.reloadData()
        if let index = environments.firstIndex(where: { $0.id == model.document.selectedEnvironmentID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updating = false
        empty.isHidden = !environments.isEmpty
        scroll.hasVerticalScroller = environments.count > 7
        updateListHeight()
    }
    private func updateListHeight() {
        // sourceList resolves its top inset during layout after joining a window.
        let visibleRows = min(environments.count, 7)
        let height: CGFloat = visibleRows > 0
            ? ceil(table.rect(ofRow: visibleRows - 1).maxY)
            : table.rowHeight + table.intercellSpacing.height
        if scrollHeight.constant != height { scrollHeight.constant = height }
        let size = NSSize(width: 360, height: height + 124)
        if preferredContentSize != size { preferredContentSize = size }
    }
    func controlTextDidChange(_ obj: Notification) { observeModel() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !environments.isEmpty else { return true }
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = table.selectedRow < 0 ? (delta > 0 ? 0 : environments.count - 1)
                : min(max(0, table.selectedRow + delta), environments.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if table.selectedRow < 0, !environments.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            confirmSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss(); return true
        default: return false
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { environments.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard environments.indices.contains(row) else { return nil }
        let cell = NSTableCellView()
        let label = NativeUI.label(environments[row].name)
        label.toolTip = environments[row].name
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!)
        check.alphaValue = environments[row].id == model.document.selectedEnvironmentID ? 1 : 0
        check.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)!)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NativeUI.stack([check, icon, label, spacer], vertical: false, spacing: 8)
        cell.textField = label
        NativeUI.pin(row, to: cell, insets: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8))
        return cell
    }
    @objc private func selectEnvironment(_ sender: NSTableView) {
        confirmSelection()
    }
    private func confirmSelection() {
        guard !updating, environments.indices.contains(table.selectedRow) else { return }
        model.document.selectedEnvironmentID = environments[table.selectedRow].id
        onDismiss()
    }
    override func cancelOperation(_ sender: Any?) { onDismiss() }
}

@MainActor
private final class EnvironmentSelectionTable: NSTableView {
    var confirm: () -> Void = {}
    var dismiss: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}": confirm()
        case "\u{1b}": dismiss()
        case "\u{f700}", "\u{f701}":
            guard numberOfRows > 0 else { return }
            let delta = event.charactersIgnoringModifiers == "\u{f701}" ? 1 : -1
            let row = selectedRow < 0 ? (delta > 0 ? 0 : numberOfRows - 1)
                : min(max(0, selectedRow + delta), numberOfRows - 1)
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            scrollRowToVisible(row)
        default: super.keyDown(with: event)
        }
    }
}
