import AppKit
import RequestmanCore

@MainActor final class ProjectSidebarViewController: ObservedViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private final class Item: NSObject {
        let id: UUID
        let projectID: UUID
        let isProject: Bool
        init(id: UUID, projectID: UUID, isProject: Bool) { self.id = id; self.projectID = projectID; self.isProject = isProject }
    }
    let model: WorkspaceModel
    let outline = ProjectOutlineView()
    let searchField = NSSearchField()
    private var roots: [Item] = []
    private var workflowItems: [UUID: [Item]] = [:]
    private var structure: [UUID] = []
    private var collapsedProjects: Set<UUID> = []
    private var synchronizing = false
    private var displayedSearch = ""
    private var displayedSection: WorkspaceSection?
    private var displayedWorkflowID: UUID?
    var search: String = "" { didSet { if isViewLoaded && !synchronizing { refresh() } } }
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let column = NSTableColumn(identifier: .init("project"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.style = .sourceList; outline.rowSizeStyle = .custom
        outline.dataSource = self; outline.delegate = self
        outline.setAccessibilityLabel("项目与请求修改")
        outline.projectClick = { [weak self] row in self?.toggleProject(at: row) ?? false }
        outline.contextMenu = { [weak self] row in self?.menu(forRow: row) }
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let add = ActionButton(title: "") { [weak self] in self?.showAddMenu() }
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加")
        add.identifier = .init("rules.sidebarAdd")
        add.imagePosition = .imageOnly; add.controlSize = .large; add.toolTip = "添加"
        add.setAccessibilityLabel("添加")
        if #available(macOS 26.0, *) { add.bezelStyle = .glass; add.borderShape = .circle } else { add.bezelStyle = .circular }
        searchField.controlSize = .large; searchField.placeholderString = "搜索请求修改"; searchField.delegate = self
        searchField.sendsSearchStringImmediately = true; searchField.setAccessibilityLabel("搜索请求修改")
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NativeUI.stack([add, searchField], vertical: false, spacing: 10)
        for child in [scroll, footer] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10), add.widthAnchor.constraint(equalTo: add.heightAnchor),
            add.heightAnchor.constraint(equalTo: searchField.heightAnchor)
        ])
    }
    override func refresh() {
        synchronizing = true
        defer { synchronizing = false }
        let projects = model.document.projects
        let selectionChanged = displayedWorkflowID != model.selectedWorkflowID || (model.selection == .rules && displayedSection != .rules)
        displayedSection = model.selection
        displayedWorkflowID = model.selectedWorkflowID
        if selectionChanged, let workflow = model.workflow {
            if !search.isEmpty && !workflow.name.localizedCaseInsensitiveContains(search)
                && !workflow.matchPattern.localizedCaseInsensitiveContains(search) { search = "" }
            if let project = projects.first(where: { $0.workflows.contains { $0.id == workflow.id } }) {
                collapsedProjects.remove(project.id)
            }
        }
        let filtered = projects.map { project in (project, project.workflows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.matchPattern.localizedCaseInsensitiveContains(search) }) }
        let ids = filtered.flatMap { [$0.0.id] + $0.1.map(\.id) }
        if structure != ids || displayedSearch != search {
            structure = ids; displayedSearch = search
            roots = filtered.map { Item(id: $0.0.id, projectID: $0.0.id, isProject: true) }
            workflowItems = Dictionary(uniqueKeysWithValues: filtered.map { project, workflows in (project.id, workflows.map { Item(id: $0.id, projectID: project.id, isProject: false) }) })
            outline.reloadData()
            for root in roots where !collapsedProjects.contains(root.id) { outline.expandItem(root) }
        }
        if selectionChanged, let root = roots.first(where: { root in
            workflowItems[root.id]?.contains { $0.id == model.selectedWorkflowID } == true
        }) { outline.expandItem(root) }
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? Item, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? RulesSidebarCell else { continue }
            configure(cell, item: item)
        }
        if searchField.stringValue != search { searchField.stringValue = search }
        searchField.isEnabled = model.loaded
        if let selected = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? Item)?.id == model.selectedWorkflowID }) {
            outline.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            if selectionChanged { outline.scrollRowToVisible(selected) }
        } else { outline.deselectAll(nil) }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Item).map { workflowItems[$0.id]?.count ?? 0 } ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { if let item = item as? Item { return workflowItems[item.id]![index] }; return roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Item)?.isProject == true }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { model.loaded && (item as? Item)?.isProject == false }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 40 }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let cell = RulesSidebarCell(); configure(cell, item: item); return cell
    }
    private func configure(_ cell: RulesSidebarCell, item: Item) {
        guard let project = model.document.projects.first(where: { $0.id == item.projectID }) else { return }
        if item.isProject {
            cell.configure(title: project.name, symbol: project.symbol, suffix: "\(project.workflows.count)", enabled: project.enabled, project: true)
        } else if let workflow = project.workflows.first(where: { $0.id == item.id }) {
            cell.configure(title: workflow.name, symbol: nil, suffix: workflow.enabled ? "" : "⏸", enabled: project.enabled && workflow.enabled, project: false)
        }
    }
    @discardableResult
    func toggleProject(at row: Int) -> Bool {
        guard model.loaded, let item = outline.item(atRow: row) as? Item, item.isProject else { return false }
        if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizing, let item = outline.item(atRow: outline.selectedRow) as? Item, !item.isProject else { return }
        if model.selectedWorkflowID != item.id { model.selectedStepID = nil; model.selectedWorkflowID = item.id }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) { if !synchronizing, let item = notification.userInfo?["NSObject"] as? Item { collapsedProjects.insert(item.id) } }
    func outlineViewItemDidExpand(_ notification: Notification) { if !synchronizing, let item = notification.userInfo?["NSObject"] as? Item { collapsedProjects.remove(item.id) } }
    func controlTextDidChange(_ notification: Notification) { search = searchField.stringValue }
    func menu(forRow row: Int) -> NSMenu? {
        guard model.loaded, let item = outline.item(atRow: row) as? Item,
              let project = model.document.projects.first(where: { $0.id == item.projectID }) else { return nil }
        let menu = NSMenu()
        if item.isProject {
            menu.addItem(RulesMenuItem(project.enabled ? "禁用整个项目" : "启用整个项目") { [weak self] in
                self?.updateProject(item.id) { $0.enabled.toggle() }
            })
            menu.addItem(RulesMenuItem("复制整个项目") { [weak self] in self?.model.duplicateProject(item.id) })
            menu.addItem(RulesMenuItem("重命名") { [weak self] in self?.rename(item) })
            let icons = NSMenu()
            for (title, symbol) in [("文件夹", "folder"), ("网络", "network"), ("地球", "globe"), ("服务器", "server.rack"),
                                    ("终端", "terminal"), ("代码", "curlybraces"), ("工具", "wrench.and.screwdriver"),
                                    ("星标", "star"), ("闪电", "bolt"), ("盒子", "shippingbox")] {
                let choice = RulesMenuItem(title, symbol: symbol) { [weak self] in self?.updateProject(item.id) { $0.symbol = symbol } }
                choice.state = project.symbol == symbol ? .on : .off
                icons.addItem(choice)
            }
            let iconItem = NSMenuItem(title: "修改图标", action: nil, keyEquivalent: ""); iconItem.submenu = icons; menu.addItem(iconItem)
            menu.addItem(RulesMenuItem("导出整组…") { [weak self] in
                guard let self, let current = model.document.projects.first(where: { $0.id == item.id }) else { return }
                WorkspaceTransfer.export(WorkspaceArchive(project: current), name: current.name, window: view.window)
            })
            menu.addItem(.separator())
            menu.addItem(RulesMenuItem("删除项目") { [weak self] in
                guard let self else { return }
                model.document.projects.removeAll { $0.id == item.id }
                if model.workflow == nil { model.selectedWorkflowID = nil; model.selectedStepID = nil }
            })
        } else if let workflow = project.workflows.first(where: { $0.id == item.id }) {
            menu.addItem(RulesMenuItem(workflow.enabled ? "禁用" : "启用") { [weak self] in
                guard let self, var current = model.document.projects.flatMap(\.workflows).first(where: { $0.id == item.id }) else { return }
                current.enabled.toggle(); model.updateWorkflow(current)
            })
            menu.addItem(RulesMenuItem("重命名") { [weak self] in self?.rename(item) })
            menu.addItem(RulesMenuItem("复制") { [weak self] in
                guard let self, let flow = model.document.projects.flatMap(\.workflows).first(where: { $0.id == item.id }) else { return }
                model.duplicateWorkflow(flow, projectID: item.projectID)
            })
            menu.addItem(RulesMenuItem("导出…") { [weak self] in
                guard let self, let current = model.document.projects.first(where: { $0.id == item.projectID }),
                      let flow = current.workflows.first(where: { $0.id == item.id }) else { return }
                WorkspaceTransfer.export(WorkspaceArchive(project: current, workflowID: item.id), name: flow.name, window: view.window)
            })
            menu.addItem(.separator())
            menu.addItem(RulesMenuItem("删除") { [weak self] in self?.model.deleteWorkflow(item.id) })
        }
        return menu
    }
    private func updateProject(_ id: UUID, change: (inout WorkflowProject) -> Void) {
        guard model.loaded, let index = model.document.projects.firstIndex(where: { $0.id == id }) else { return }
        change(&model.document.projects[index])
    }
    private func rename(_ item: Item) {
        guard let project = model.document.projects.first(where: { $0.id == item.projectID }) else { return }
        let name = item.isProject ? project.name : project.workflows.first { $0.id == item.id }?.name ?? ""
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel(item.isProject ? "项目名称" : "请求修改名称")
        let alert = NSAlert()
        alert.messageText = item.isProject ? "重命名项目" : "重命名请求修改"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, model.loaded else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            if item.isProject { updateProject(item.id) { $0.name = name } }
            else if var workflow = model.document.projects.flatMap(\.workflows).first(where: { $0.id == item.id }) {
                workflow.name = name; model.updateWorkflow(workflow)
            }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
    private func showAddMenu() {
        guard model.loaded else { return }
        let menu = NSMenu()
        menu.addItem(RulesMenuItem("添加请求", symbol: "doc.badge.plus") { [weak self] in self?.addRequest() })
        menu.addItem(RulesMenuItem("添加项目", symbol: "folder.badge.plus") { [weak self] in self?.model.addProject() })
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: 46), in: view)
    }
    func addRequest() {
        search = ""
        let project = model.document.projects.first { $0.workflows.contains { $0.id == model.selectedWorkflowID } } ?? model.document.projects.first
        if let project { collapsedProjects.remove(project.id); model.addWorkflow(projectID: project.id) }
        else { model.addProject() }
    }
}

/// Keep native outline keyboard navigation/disclosure accessibility; intercept only project clicks.
@MainActor final class ProjectOutlineView: NSOutlineView {
    var projectClick: (Int) -> Bool = { _ in false }
    var contextMenu: (Int) -> NSMenu? = { _ in nil }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
        let row = row(at: convert(event.locationInWindow, from: nil))
        if !projectClick(row) { super.mouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        menu = contextMenu(row(at: convert(event.locationInWindow, from: nil)))
        guard menu != nil else { return nil }
        // AppKit tracks the clicked row and draws/clears its native contextual-menu outline
        // without changing the selected workflow. Returning our menu directly bypasses it.
        return super.menu(for: event)
    }
}

@MainActor private final class RulesSidebarCell: NSTableCellView {
    private let title = NativeUI.label("")
    private let icon = NSImageView()
    private let suffix = NativeUI.label("", size: 11, secondary: true)
    override init(frame: NSRect) {
        super.init(frame: frame)
        textField = title
        let row = NativeUI.stack([icon, title, suffix], vertical: false, spacing: 8)
        NativeUI.pin(row, to: self, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 4))
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        suffix.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(title: String, symbol: String?, suffix: String, enabled: Bool, project: Bool) {
        self.title.stringValue = title; self.title.toolTip = title
        self.title.font = .systemFont(ofSize: 13, weight: project ? .semibold : .regular)
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        if project && icon.image == nil { icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) }
        icon.isHidden = symbol == nil; icon.contentTintColor = .controlAccentColor
        self.suffix.stringValue = suffix; alphaValue = enabled ? 1 : 0.55
    }
}

@MainActor final class RulesViewController: ObservedViewController {
    let model: WorkspaceModel
    private let content = NSView()
    private var editor: FlowEditorViewController?
    private var lastID: UUID?
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = content }
    override func refresh() {
        let current = model.workflow
        if lastID != current?.id || content.subviews.isEmpty {
            editor?.removeFromParent(); editor = nil
            content.subviews.forEach { $0.removeFromSuperview() }
            lastID = current?.id
            if current != nil {
                let controller = FlowEditorViewController(model: model); editor = controller
                addChild(controller); NativeUI.pin(controller.view, to: content)
            } else {
                let title = NativeUI.label("编排一次，自动处理每次请求", size: 20, weight: .semibold)
                let description = NativeUI.label("在项目中创建请求修改，设置匹配条件，再添加请求和响应步骤。", secondary: true)
                description.maximumNumberOfLines = 0
                let add = ActionButton(title: "新建项目") { [weak self] in self?.model.addProject() }; add.isEnabled = model.loaded
                let stack = NativeUI.stack([title, description, add], spacing: 12)
                content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: content.centerXAnchor), stack.centerYAnchor.constraint(equalTo: content.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48)])
            }
        }
        editor?.refresh()
        if current == nil { content.subviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? ActionButton }.forEach { $0.isEnabled = model.loaded } }
    }
}

@MainActor final class RulesMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        handler = action; super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

@MainActor final class RulesSwitch: NSSwitch {
    var onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange; super.init(frame: .zero); target = self; action = #selector(changed) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { onChange(state == .on) }
}

@MainActor final class RulesTextArea: NSScrollView, NSTextViewDelegate {
    let textView = NSTextView()
    var onChange: (String) -> Void
    init(editable: Bool = true, onChange: @escaping (String) -> Void = { _ in }) {
        self.onChange = onChange; super.init(frame: .zero)
        hasVerticalScroller = true; borderType = .bezelBorder; documentView = textView
        textView.isRichText = false; textView.isEditable = editable; textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 8); textView.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var string: String { get { textView.string } set { if textView.string != newValue { textView.string = newValue } } }
    func textDidChange(_ notification: Notification) { onChange(textView.string) }
}
