import AppKit
import CoreText
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
    private lazy var addButton = ActionButton(title: "") { [weak self] in self?.showAddMenu() }
    var search: String = "" { didSet { if isViewLoaded && !synchronizing { refresh() } } }
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let column = NSTableColumn(identifier: .init("project"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.style = .sourceList; outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 20
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.dataSource = self; outline.delegate = self
        outline.setAccessibilityLabel("项目与请求修改")
        outline.contextMenu = { [weak self] row in self?.menu(forRow: row) }
        outline.target = self; outline.doubleAction = #selector(doubleClickProject)
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        let add = addButton
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加")
        add.identifier = .init("rules.sidebarAdd")
        add.imagePosition = .imageOnly; add.controlSize = .large; add.toolTip = "添加"
        add.setAccessibilityLabel("添加")
        if #available(macOS 26.0, *) { add.bezelStyle = .glass; add.borderShape = .circle } else { add.bezelStyle = .circular }
        searchField.controlSize = .large; searchField.placeholderString = "搜索请求修改"; searchField.delegate = self
        searchField.toolTip = "搜索请求修改（⌘F）"
        searchField.sendsSearchStringImmediately = true; searchField.setAccessibilityLabel("搜索请求修改")
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NativeUI.stack([add, searchField], vertical: false, spacing: 10)
        for child in [scroll, footer] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            add.widthAnchor.constraint(equalTo: add.heightAnchor), add.heightAnchor.constraint(equalTo: searchField.heightAnchor)
        ])
    }
    override func refresh() {
        let focusedItemID = (outline.item(atRow: outline.selectedRow) as? Item)?.id
        synchronizing = true
        outline.animatesDisclosure = false
        defer { synchronizing = false; outline.animatesDisclosure = true }
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
        addButton.isEnabled = model.loaded
        let selectionID = selectionChanged ? model.selectedWorkflowID : (focusedItemID ?? model.selectedWorkflowID)
        if let selected = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? Item)?.id == selectionID }) {
            outline.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            if selectionChanged { outline.scrollRowToVisible(selected) }
        } else { outline.deselectAll(nil) }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Item).map { workflowItems[$0.id]?.count ?? 0 } ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { if let item = item as? Item { return workflowItems[item.id]![index] }; return roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Item)?.isProject == true }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { model.loaded }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool { model.loaded }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { model.loaded }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 30 }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ProjectSidebarRowView() }
    func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView as? ProjectSidebarRowView)?.setHovered(false, animated: false)
    }
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
        cell.showMenu = { [weak self, weak cell] button in
            guard let self, let cell, let row = cell.superview as? ProjectSidebarRowView,
                  let menu = menu(forRow: outline.row(for: cell)) else { return }
            row.isShowingMenu = true
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 3), in: button)
            row.isShowingMenu = false
            row.refreshHover()
        }
    }

    @objc private func doubleClickProject() { toggleProject(at: outline.clickedRow) }

    @discardableResult
    func toggleProject(at row: Int) -> Bool {
        guard model.loaded, let item = outline.item(atRow: row) as? Item, item.isProject else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        view.window?.makeFirstResponder(outline)
        if outline.isItemExpanded(item) { outline.collapseItem(item) }
        else { outline.expandItem(item) }
        return true
    }

    func canPerform(_ command: WorkspaceCommand) -> Bool {
        guard model.loaded, model.selection == .rules, !outline.isHiddenOrHasHiddenAncestor, view.window?.firstResponder === outline,
              let item = outline.item(atRow: outline.selectedRow) as? Item,
              let project = model.document.projects.first(where: { $0.id == item.projectID }),
              item.isProject || project.workflows.contains(where: { $0.id == item.id }) else { return false }
        return [.duplicate, .rename, .delete, .toggleEnabled].contains(command)
    }

    func perform(_ command: WorkspaceCommand) {
        guard canPerform(command), let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
        perform(command, item: item)
    }

    private func perform(_ command: WorkspaceCommand, item: Item) {
        guard model.loaded, let project = model.document.projects.first(where: { $0.id == item.projectID }) else { return }
        switch command {
        case .rename: rename(item)
        case .duplicate:
            if item.isProject { model.duplicateProject(item.id) }
            else if let workflow = project.workflows.first(where: { $0.id == item.id }) {
                model.duplicateWorkflow(workflow, projectID: item.projectID)
            }
        case .toggleEnabled:
            if item.isProject { updateProject(item.id) { $0.enabled.toggle() } }
            else if var workflow = project.workflows.first(where: { $0.id == item.id }) {
                workflow.enabled.toggle(); model.updateWorkflow(workflow)
            }
        case .delete:
            if item.isProject {
                model.document.projects.removeAll { $0.id == item.id }
                if model.workflow == nil { model.selectedWorkflowID = nil; model.selectedStepID = nil }
            } else { model.deleteWorkflow(item.id) }
        default: return
        }
        refresh()
    }

    func createProject() {
        guard model.loaded else { return }
        search = ""
        model.addProject()
        refresh()
        if let root = roots.last { rename(root) }
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
            menu.addItem(RulesMenuItem("添加请求修改", symbol: "doc.badge.plus") { [weak self] in
                guard let self else { return }
                search = ""; collapsedProjects.remove(item.id); model.addWorkflow(projectID: item.id)
            })
            menu.addItem(.separator())
            menu.addItem(RulesMenuItem(project.enabled ? "禁用整个项目" : "启用整个项目") { [weak self] in
                self?.perform(.toggleEnabled, item: item)
            })
            menu.addItem(RulesMenuItem("复制整个项目") { [weak self] in self?.perform(.duplicate, item: item) })
            menu.addItem(RulesMenuItem("重命名") { [weak self] in self?.perform(.rename, item: item) })
            let icons = ProjectIconMenu.make(selected: project.symbol) { [weak self] symbol in
                self?.updateProject(item.id) { $0.symbol = symbol }
            }
            let iconItem = NSMenuItem(title: "修改图标", action: nil, keyEquivalent: ""); iconItem.submenu = icons; menu.addItem(iconItem)
            menu.addItem(RulesMenuItem("导出整组…") { [weak self] in
                guard let self, let current = model.document.projects.first(where: { $0.id == item.id }) else { return }
                WorkspaceTransfer.export(WorkspaceArchive(project: current), name: current.name, window: view.window)
            })
            menu.addItem(.separator())
            menu.addItem(RulesMenuItem("删除项目") { [weak self] in
                self?.perform(.delete, item: item)
            })
        } else if let workflow = project.workflows.first(where: { $0.id == item.id }) {
            menu.addItem(RulesMenuItem(workflow.enabled ? "禁用" : "启用") { [weak self] in
                self?.perform(.toggleEnabled, item: item)
            })
            menu.addItem(RulesMenuItem("重命名") { [weak self] in self?.perform(.rename, item: item) })
            menu.addItem(RulesMenuItem("复制") { [weak self] in
                self?.perform(.duplicate, item: item)
            })
            menu.addItem(RulesMenuItem("导出…") { [weak self] in
                guard let self, let current = model.document.projects.first(where: { $0.id == item.projectID }),
                      let flow = current.workflows.first(where: { $0.id == item.id }) else { return }
                WorkspaceTransfer.export(WorkspaceArchive(project: current, workflowID: item.id), name: flow.name, window: view.window)
            })
            menu.addItem(.separator())
            menu.addItem(RulesMenuItem("删除") { [weak self] in self?.perform(.delete, item: item) })
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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.maxY + 3), in: addButton)
    }
    func addRequest() {
        guard model.loaded else { return }
        let selectedProjectID = (outline.item(atRow: outline.selectedRow) as? Item)?.projectID
        search = ""
        let project = model.document.projects.first { $0.id == selectedProjectID }
            ?? model.document.projects.first { $0.workflows.contains { $0.id == model.selectedWorkflowID } }
            ?? model.document.projects.first
        if let project { collapsedProjects.remove(project.id); model.addWorkflow(projectID: project.id) }
        else { model.addProject() }
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
    func focusName() { refresh(); editor?.focusName() }
    func canPerform(_ command: WorkspaceCommand) -> Bool { editor?.canPerform(command) ?? false }
    func perform(_ command: WorkspaceCommand) { editor?.perform(command) }
    override func refresh() {
        let current = model.workflow
        if lastID != current?.id || content.subviews.isEmpty {
            editor?.stopObserving()
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
    let textView: NSTextView
    private let templateLayout: TemplateLayoutManager?
    private let bodyEditor: Bool
    var onChange: (String) -> Void
    init(editable: Bool = true, template: Bool = false, bodyEditor: Bool = false, onChange: @escaping (String) -> Void = { _ in }) {
        self.onChange = onChange
        self.bodyEditor = bodyEditor
        if template {
            let storage = NSTextStorage()
            let layout = TemplateLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layout); layout.addTextContainer(container)
            textView = TemplateTextView(frame: .zero, textContainer: container); templateLayout = layout
        } else { textView = NSTextView(); templateLayout = nil }
        super.init(frame: .zero)
        hasVerticalScroller = true; borderType = .bezelBorder; documentView = textView
        textView.isRichText = false; textView.isEditable = editable; textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        // A zero-frame NSTextView otherwise inherits the viewport as its maximum height.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 8); textView.delegate = self
        textView.allowsUndo = true
        if template {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 24
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes[.paragraphStyle] = paragraph
            wantsLayer = true; layer?.cornerRadius = 8; layer?.masksToBounds = true
        }
        if bodyEditor {
            verticalRulerView = BodyLineRuler(scrollView: self, orientation: .verticalRuler)
            verticalRulerView?.clientView = textView
            hasVerticalRuler = true; rulersVisible = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let minimum = NSSize(width: 0, height: max(0, contentSize.height))
        if textView.minSize != minimum { textView.minSize = minimum }
    }
    var string: String {
        get { textView.string }
        set { if textView.string != newValue { textView.string = newValue; refreshTokens() } }
    }
    private func refreshTokens() {
        templateLayout?.updateTokens(excluding: textView.markedRange())
        if bodyEditor {
            JSONSyntax.highlight(textView, templateRanges: templateLayout?.tokenRanges ?? [])
            (verticalRulerView as? BodyLineRuler)?.updateLines()
        }
        if templateLayout != nil { textView.typingAttributes.removeValue(forKey: .kern) }
        textView.needsDisplay = true
    }
    func textDidChange(_ notification: Notification) { refreshTokens(); onChange(textView.string) }
    @discardableResult func formatJSON() -> Bool {
        guard textView.isEditable, !textView.hasMarkedText(), let formatted = BodyJSONPresentation.formatted(string) else { return false }
        guard formatted != string else { return true }
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard textView.shouldChangeText(in: range, replacementString: formatted) else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: formatted)
        textView.didChangeText()
        textView.undoManager?.setActionName("格式化 JSON")
        return true
    }
}

/// Keep decoration spacing out of the caret position after ordinary text.
final class TemplateTextView: NSTextView {
    private func leadingPadding(at index: Int) -> CGFloat {
        (layoutManager as? TemplateLayoutManager)?.leadingPadding(at: index) ?? 0
    }

    private func insertionPointRect(_ rect: NSRect, at index: Int) -> NSRect {
        let textFont = (typingAttributes[.font] as? NSFont) ?? font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        // Keep the text's line spacing, but give the native caret only the font's height.
        let height = min(rect.height, ceil(textFont.ascender - textFont.descender))
        return NSRect(x: rect.minX - leadingPadding(at: index), y: rect.midY - height / 2,
                      width: rect.width, height: height)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caret = insertionPointRect(rect, at: selectedRange().location)
        caret.size.width = 2
        super.drawInsertionPoint(in: caret, color: color, turnedOn: flag)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        // Cover both the shifted position and the wider caret when it blinks or moves.
        super.setNeedsDisplay(invalidRect.union(invalidRect.offsetBy(dx: -8, dy: 0)).insetBy(dx: -2, dy: 0))
    }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = super.firstRect(forCharacterRange: range, actualRange: actualRange)
        return range.length == 0 ? insertionPointRect(rect, at: range.location) : rect
    }

    override func characterIndexForInsertion(at point: NSPoint) -> Int {
        let index = super.characterIndexForInsertion(at: point)
        guard let window, let layout = layoutManager as? TemplateLayoutManager else { return index }
        let source = string as NSString
        for token in layout.tokenRanges where token.location > 0 {
            let previous = source.rangeOfComposedCharacterSequence(at: token.location - 1)
            guard index == previous.location || index == token.location else { continue }
            let padding = leadingPadding(at: token.location)
            guard padding > 0 else { continue }
            let screenRect = super.firstRect(forCharacterRange: NSRange(location: token.location, length: 0), actualRange: nil)
            let caret = convert(window.convertFromScreen(screenRect), from: nil)
            let previousScreenRect = super.firstRect(forCharacterRange: NSRange(location: previous.location, length: 0), actualRange: nil)
            let previousCaret = convert(window.convertFromScreen(previousScreenRect), from: nil)
            if point.y >= caret.minY && point.y < caret.maxY,
               point.x >= (previousCaret.minX + caret.minX - padding) / 2 && point.x <= caret.minX {
                return token.location
            }
        }
        return index
    }
}

/// Presentation-only marks: the backing string, undo history and clipboard stay plain text.
final class TemplateLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let textStorage else { return false }
        let range = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let text = textStorage.attributedSubstring(from: range)
        let outlines = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
        guard !outlines.isEmpty else { return false }
        // A 20 pt mark gets a dedicated 24 pt row, including 2 pt clear space on either side.
        let height = max(lineFragmentRect.pointee.height, outlines.height + 8, 24)
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = height / 2 + outlines.midY
        return true
    }

    private(set) var tokenRanges: [NSRange] = []
    private static let expression = try! NSRegularExpression(pattern: #"\{\{[^{}\r\n]+\}\}"#)
    func updateTokens(excluding markedRange: NSRange = NSRange(location: NSNotFound, length: 0)) {
        guard let textStorage else { return }
        let range = NSRange(location: 0, length: textStorage.length)
        removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        tokenRanges = Self.expression.matches(in: textStorage.string, range: range).map(\.range).filter {
            markedRange.location == NSNotFound || NSIntersectionRange($0, markedRange).length == 0
        }
        // Reserve real layout space at token boundaries without inserting characters.
        let source = textStorage.string as NSString
        var spacing: [Int: CGFloat] = [:]
        for token in tokenRanges {
            if token.location > 0 {
                let previous = source.rangeOfComposedCharacterSequence(at: token.location - 1)
                if source.substring(with: previous).rangeOfCharacter(from: .newlines) == nil {
                    spacing[previous.location, default: 0] += 8
                }
            }
            spacing[NSMaxRange(token) - 1, default: 0] += 8
        }
        textStorage.beginEditing()
        textStorage.removeAttribute(.kern, range: range)
        for (position, padding) in spacing {
            textStorage.addAttribute(.kern, value: padding, range: source.rangeOfComposedCharacterSequence(at: position))
        }
        textStorage.endEditing()
        for token in tokenRanges { addTemporaryAttribute(.foregroundColor, value: NSColor.systemBlue, forCharacterRange: token) }
    }
    func leadingPadding(at index: Int) -> CGFloat {
        guard let textStorage, index > 0, index < textStorage.length,
              tokenRanges.contains(where: { $0.location == index }),
              !tokenRanges.contains(where: { NSMaxRange($0) == index }) else { return 0 }
        let previous = (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: index - 1)
        guard let padding = textStorage.attribute(.kern, at: previous.location, effectiveRange: nil) as? CGFloat else { return 0 }
        let before = glyphIndexForCharacter(at: previous.location)
        let after = glyphIndexForCharacter(at: index)
        // A wrapped token starts a new line; RTL boundaries keep native positioning.
        guard lineFragmentRect(forGlyphAt: before, effectiveRange: nil) == lineFragmentRect(forGlyphAt: after, effectiveRange: nil),
              location(forGlyphAt: after).x > location(forGlyphAt: before).x else { return 0 }
        return padding
    }

    func backgroundRects(forCharacterRange range: NSRange) -> [NSRect] {
        guard NSMaxRange(range) <= (textStorage?.length ?? 0) else { return [] }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var result: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { line, _, container, lineGlyphs, _ in
            let fragment = NSIntersectionRange(glyphs, lineGlyphs)
            guard fragment.length > 0 else { return }
            let text = self.visibleTextBounds(forGlyphRange: fragment, in: container)
            // Center on the drawn glyphs, not the line box (which includes leading).
            // Clamp both sides equally so clipping cannot shift the optical center.
            let halfHeight = min(max(20, text.height + 4) / 2, text.midY - line.minY, line.maxY - text.midY)
            let mark = NSRect(x: text.minX - 4, y: text.midY - halfHeight,
                              width: text.width + 8, height: halfHeight * 2)
            let bounds = NSRect(x: 0, y: line.minY, width: container.containerSize.width, height: line.height)
            result.append(mark.intersection(bounds))
        }
        return result
    }
    func visibleTextBounds(forGlyphRange glyphs: NSRange, in container: NSTextContainer) -> NSRect {
        let typographic = boundingRect(forGlyphRange: glyphs, in: container)
        guard let textStorage else { return typographic }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = textStorage.attributedSubstring(from: characters)
        // Core Text includes fallback fonts and measures the actual outlines, including braces.
        let outlines = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
        guard !outlines.isEmpty else { return typographic }
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = line.minY + location(forGlyphAt: glyphs.location).y
        return NSRect(x: line.minX + location(forGlyphAt: glyphs.location).x + outlines.minX, y: baseline - outlines.maxY,
                      width: outlines.width, height: outlines.height)
    }
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        NSColor.systemBlue.withAlphaComponent(0.20).setFill()
        for token in tokenRanges {
            guard NSMaxRange(token) <= (textStorage?.length ?? 0),
                  NSIntersectionRange(glyphRange(forCharacterRange: token, actualCharacterRange: nil), glyphsToShow).length > 0 else { continue }
            for rect in backgroundRects(forCharacterRange: token) {
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 5, yRadius: 5).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
