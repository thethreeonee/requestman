import AppKit
import RequestmanCore

@MainActor
final class EnvironmentsViewController: ObservedViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: WorkspaceModel
    private let split = NSSplitViewController()
    private let table = NSTableView()
    private let editor = NSViewController()
    private var emptyState: NSView!
    private lazy var create = ActionButton(title: "新建环境") { [weak self] in self?.model.addEnvironment() }
    private lazy var sidebarCreate = ActionButton(title: "新建环境") { [weak self] in self?.model.addEnvironment() }
    private var listSnapshot: [EnvironmentListItem] = []
    private var editorID: UUID?
    private var variableIDs: [UUID] = []
    private var nameField: ActionTextField?
    private var variableFields: [UUID: (name: ActionTextField, value: ActionTextField)] = [:]
    private var useButton: ActionButton?
    private var editorControls: [NSControl] = []
    private var syncingSelection = false

    init(model: WorkspaceModel) {
        self.model = model
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        emptyState = makeEmptyState("还没有环境", detail: "创建 dev、staging 等环境，集中管理 API Key、Cookie 和目标地址。", action: create)
        NativeUI.pin(emptyState, to: view)
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        let sidebar = NSViewController()
        sidebar.view = NSView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("environment")))
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("环境列表")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        sidebarCreate.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        sidebarCreate.imagePosition = .imageLeading
        let footer = NativeUI.stack([sidebarCreate, NSView()], vertical: false)
        let sidebarStack = NativeUI.stack([scroll, footer], spacing: 0)
        sidebarStack.alignment = .leading
        NativeUI.pin(sidebarStack, to: sidebar.view)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: sidebarStack.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: sidebarStack.trailingAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 52)
        ])
        editor.view = NSView()
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        sidebarItem.preferredThicknessFraction = 0.25
        sidebarItem.canCollapse = false
        let detailItem = NSSplitViewItem(viewController: editor)
        detailItem.minimumThickness = 420
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        addChild(split)
        NativeUI.pin(split.view, to: view)
    }

    override func refresh() {
        let environments = model.document.environments
        let isEmpty = environments.isEmpty
        emptyState.isHidden = !isEmpty
        split.view.isHidden = isEmpty
        create.isEnabled = model.loaded
        sidebarCreate.isEnabled = model.loaded
        table.isEnabled = model.loaded
        let snapshot = environments.map { EnvironmentListItem(id: $0.id, name: $0.name, active: $0.id == model.document.selectedEnvironmentID) }
        if snapshot != listSnapshot {
            listSnapshot = snapshot
            syncingSelection = true
            table.reloadData()
            syncingSelection = false
        }
        let selectedRow = environments.firstIndex { $0.id == model.selectedEnvironmentID } ?? -1
        if table.selectedRow != selectedRow {
            syncingSelection = true
            if selectedRow >= 0 { table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false) }
            else { table.deselectAll(nil) }
            syncingSelection = false
        }
        guard let environment = environments.first(where: { $0.id == model.selectedEnvironmentID }) else {
            if editorID != nil || editor.view.subviews.isEmpty {
                editor.view.subviews.forEach { $0.removeFromSuperview() }
                NativeUI.pin(makeEmptyState("选择一个环境", detail: "从左侧选择环境以编辑变量。"), to: editor.view)
                editorID = nil
                variableIDs = []
                variableFields = [:]
                editorControls = []
                nameField = nil
                useButton = nil
            }
            return
        }
        if editorID != environment.id || variableIDs != environment.variables.map(\.id) {
            rebuildEditor(environment)
        }
        if let nameField { SettingsUI.sync(nameField, environment.name) }
        for variable in environment.variables {
            guard let fields = variableFields[variable.id] else { continue }
            SettingsUI.sync(fields.name, variable.name)
            SettingsUI.sync(fields.value, variable.value)
        }
        editorControls.forEach { $0.isEnabled = model.loaded }
        let active = environment.id == model.document.selectedEnvironmentID
        useButton?.title = active ? "正在使用" : "切换到此环境"
        useButton?.isEnabled = model.loaded && !active
    }

    func numberOfRows(in tableView: NSTableView) -> Int { listSnapshot.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard listSnapshot.indices.contains(row) else { return nil }
        let item = listSnapshot[row]
        let cell = NSTableCellView()
        let label = NativeUI.label(item.name)
        cell.textField = label
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "正在使用") ?? NSImage())
        check.isHidden = !item.active
        check.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let content = NativeUI.stack([label, NSView(), check], vertical: false, spacing: 6)
        NativeUI.pin(content, to: cell, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, model.loaded, listSnapshot.indices.contains(table.selectedRow) else { return }
        model.selectedEnvironmentID = listSnapshot[table.selectedRow].id
    }

    private func rebuildEditor(_ environment: WorkspaceEnvironment) {
        editor.view.subviews.forEach { $0.removeFromSuperview() }
        editorID = environment.id
        variableIDs = environment.variables.map(\.id)
        variableFields = [:]
        editorControls = []
        let environmentID = environment.id
        let name = ActionTextField(environment.name, placeholder: "名称") { [weak self] value in
            guard let self, let index = self.index(of: environmentID) else { return }
            self.model.document.environments[index].name = value
        }
        name.setAccessibilityLabel("环境名称")
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true
        nameField = name
        let use = ActionButton(title: "切换到此环境") { [weak self] in self?.model.document.selectedEnvironmentID = environmentID }
        useButton = use
        editorControls += [name, use]
        let useRow = NativeUI.stack([use, NSView()], vertical: false)
        var rows: [NSView] = []
        for variable in environment.variables {
            let id = variable.id
            let variableName = ActionTextField(variable.name, placeholder: "变量名称") { [weak self] value in
                guard let self, let index = self.index(of: environmentID), let variableIndex = self.model.document.environments[index].variables.firstIndex(where: { $0.id == id }) else { return }
                self.model.document.environments[index].variables[variableIndex].name = value
            }
            let variableValue = ActionTextField(variable.value, placeholder: "值") { [weak self] value in
                guard let self, let index = self.index(of: environmentID), let variableIndex = self.model.document.environments[index].variables.firstIndex(where: { $0.id == id }) else { return }
                self.model.document.environments[index].variables[variableIndex].value = value
            }
            variableName.setAccessibilityLabel("变量名称")
            variableValue.setAccessibilityLabel("变量值")
            let remove = ActionButton(title: "") { [weak self] in
                guard let self, let index = self.index(of: environmentID) else { return }
                self.model.document.environments[index].variables.removeAll { $0.id == id }
            }
            remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "删除变量")
            remove.imagePosition = .imageOnly
            remove.toolTip = "删除变量"
            remove.setAccessibilityLabel("删除变量")
            rows.append(NativeUI.stack([variableName, variableValue, remove], vertical: false, spacing: 8))
            variableName.widthAnchor.constraint(equalTo: variableValue.widthAnchor).isActive = true
            variableFields[id] = (variableName, variableValue)
            editorControls += [variableName, variableValue, remove]
        }
        let add = ActionButton(title: "添加变量") { [weak self] in
            guard let self, let index = self.index(of: environmentID) else { return }
            self.model.document.environments[index].variables.append(NamedValue())
        }
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        rows.append(NativeUI.stack([add, NSView()], vertical: false))
        let delete = ActionButton(title: "删除环境") { [weak self] in
            guard let self, let index = self.index(of: environmentID) else { return }
            self.model.document.environments.remove(at: index)
            if self.model.document.selectedEnvironmentID == environmentID { self.model.document.selectedEnvironmentID = nil }
            self.model.selectedEnvironmentID = self.model.document.environments.first?.id
        }
        delete.hasDestructiveAction = true
        editorControls += [add, delete]
        let sections = [
            SettingsUI.section("环境", rows: [SettingsUI.row("名称", name), useRow]),
            SettingsUI.section("变量", rows: rows, footer: "使用 {{env.变量名}} 引用。切换环境仅影响新请求；进行中的请求保留原环境快照。"),
            SettingsUI.section("", rows: [NativeUI.stack([delete, NSView()], vertical: false)], footer: "环境保存在本机工作区文件中。变量名称应唯一；同名时使用最后一个值。")
        ]
        let content = NativeUI.stack(sections, spacing: 20)
        content.alignment = .leading
        sections.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        SettingsUI.scroll(content, into: editor.view)
        // This form is created after the window's initial key-view loop. Keep
        // each variable's name and value adjacent, including newly added rows.
        editor.view.layoutSubtreeIfNeeded()
        view.window?.recalculateKeyViewLoop()
        for (current, next) in zip(editorControls, editorControls.dropFirst()) {
            current.nextKeyView = next
        }
    }

    private func index(of id: UUID) -> Int? { model.document.environments.firstIndex { $0.id == id } }

    private func makeEmptyState(_ title: String, detail: String, action: NSButton? = nil) -> NSView {
        let container = NSView()
        let icon = NSImageView(image: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let description = SettingsUI.note(detail)
        description.alignment = .center
        let stack = NativeUI.stack([icon, NativeUI.label(title, size: 20, weight: .semibold), description] + (action.map { [$0] } ?? []), spacing: 12)
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            description.widthAnchor.constraint(lessThanOrEqualToConstant: 380)
        ])
        return container
    }
}

private struct EnvironmentListItem: Equatable {
    let id: UUID
    let name: String
    let active: Bool
}
