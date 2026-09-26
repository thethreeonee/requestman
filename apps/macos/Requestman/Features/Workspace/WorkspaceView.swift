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
    private let rules: RulesViewController
    private let requests: RequestsViewController
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
    private let table = NSTableView()
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
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = table
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 180); scrollHeight.isActive = true
        let manage = ActionButton(title: "管理环境…") { [weak self] in
            guard let self else { return }
            model.settingsSection = .environments; onDismiss(); openSettings()
        }
        let stack = NativeUI.stack([search, NativeUI.label("环境", size: 11, secondary: true), scroll, empty, NativeUI.separator(), manage])
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        for item in [search, scroll] as [NSView] { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(search) }
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
        scrollHeight.constant = CGFloat(max(1, min(environments.count, 7))) * 36
        preferredContentSize = NSSize(width: 360, height: scrollHeight.constant + 124)
    }
    func controlTextDidChange(_ obj: Notification) { observeModel() }
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
        guard !updating, environments.indices.contains(table.selectedRow) else { return }
        model.document.selectedEnvironmentID = environments[table.selectedRow].id
        onDismiss()
    }
    override func cancelOperation(_ sender: Any?) { onDismiss() }
}
