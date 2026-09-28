import AppKit
import RequestmanCore

typealias RecordColumn = RequestLogStandardColumn
extension RequestLogStandardColumn {
    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
}

@MainActor
final class RequestLogDisplayOptionsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var options: RequestLogDisplayOptions
    private var allowLAN: Bool
    private let onChange: (RequestLogDisplayOptions) -> Void
    private let editColumn: (RequestLogExtraColumn?) -> Void
    private var checkboxes: [RecordColumn: NSButton] = [:]
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var listHeight: NSLayoutConstraint!
    private lazy var edit = ActionButton(title: "编辑…") { [weak self] in
        guard let self, let column = selectedColumn else { return }; editColumn(column)
    }
    private lazy var remove = ActionButton(title: "删除") { [weak self] in self?.removeSelected() }
    private var selectedColumn: RequestLogExtraColumn? {
        options.extraColumns.indices.contains(table.selectedRow) ? options.extraColumns[table.selectedRow] : nil
    }

    init(options: RequestLogDisplayOptions, allowLAN: Bool, onChange: @escaping (RequestLogDisplayOptions) -> Void,
         editColumn: @escaping (RequestLogExtraColumn?) -> Void) {
        self.options = options; self.allowLAN = allowLAN; self.onChange = onChange; self.editColumn = editColumn
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        var rows: [NSView] = [NativeUI.label("显示选项", size: 14, weight: .semibold)]
        for column in RecordColumn.allCases {
            let button = NSButton(checkboxWithTitle: column == .request ? "请求（URL）" : column.title,
                                  target: self, action: #selector(toggleColumn(_:)))
            button.identifier = column.identifier
            checkboxes[column] = button; rows.append(button)
        }
        let enabled = NSTableColumn(identifier: .init("enabled")); enabled.width = 28
        let title = NSTableColumn(identifier: .init("title")); title.width = 272
        table.addTableColumn(enabled); table.addTableColumn(title)
        table.headerView = nil; table.rowHeight = 36
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(editSelected)
        table.setAccessibilityLabel("额外列")
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 320).isActive = true
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 40); listHeight.isActive = true
        let add = ActionButton(title: "添加额外列…") { [weak self] in self?.editColumn(nil) }
        let actions = NativeUI.stack([add, edit, remove], vertical: false, spacing: 8)
        let separator = NativeUI.separator()
        separator.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        rows += [separator, NativeUI.label("额外列", size: 12, weight: .semibold), scroll, actions,
                 NativeUI.label("拖动日志表头可调整列顺序", size: 11, secondary: true)]
        let stack = NativeUI.stack(rows, spacing: 8)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        update(options: options, allowLAN: allowLAN)
    }

    func update(options: RequestLogDisplayOptions, allowLAN: Bool) {
        let oldID = isViewLoaded ? selectedColumn?.id : nil
        let extrasChanged = self.options.extraColumns != options.extraColumns
        self.options = options; self.allowLAN = allowLAN
        guard isViewLoaded else { return }
        let available = options.columns.subtracting([.device])
        for (column, button) in checkboxes {
            button.state = options.columns.contains(column) ? .on : .off
            button.isEnabled = column == .device ? allowLAN : !(available.count == 1 && available.contains(column))
            button.toolTip = column == .device && !allowLAN ? "开启允许局域网设备连接后可显示" : nil
        }
        if extrasChanged || table.numberOfRows != options.extraColumns.count {
            table.reloadData()
            if let oldID, let index = options.extraColumns.firstIndex(where: { $0.id == oldID }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        listHeight.constant = CGFloat(max(1, min(4, options.extraColumns.count))) * 38 + 2
        edit.isEnabled = selectedColumn != nil; remove.isEnabled = selectedColumn != nil
        preferredContentSize = view.fittingSize
    }

    func numberOfRows(in tableView: NSTableView) -> Int { options.extraColumns.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard options.extraColumns.indices.contains(row) else { return nil }
        let column = options.extraColumns[row]
        if tableColumn?.identifier.rawValue == "enabled" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleExtra(_:)))
            button.tag = row; button.state = column.isEnabled ? .on : .off
            button.setAccessibilityLabel("显示 " + column.displayTitle)
            return button
        }
        let title = column.displayTitle.isEmpty ? column.field.title : column.displayTitle
        let label = NativeUI.label(title + " · " + column.stage.title)
        label.toolTip = column.summary
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        edit.isEnabled = selectedColumn != nil; remove.isEnabled = selectedColumn != nil
    }
    private func changed(_ next: RequestLogDisplayOptions) {
        update(options: next, allowLAN: allowLAN); onChange(next)
    }
    @objc private func toggleColumn(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let column = RecordColumn(rawValue: value) else { return }
        var next = options
        if sender.state == .on { next.columns.insert(column) } else { next.columns.remove(column) }
        changed(next)
    }
    @objc private func toggleExtra(_ sender: NSButton) {
        guard options.extraColumns.indices.contains(sender.tag) else { return }
        var next = options; next.extraColumns[sender.tag].isEnabled = sender.state == .on; changed(next)
    }
    @objc private func editSelected() { if let column = selectedColumn { editColumn(column) } }
    private func removeSelected() {
        guard let id = selectedColumn?.id else { return }
        var next = options; next.extraColumns.removeAll { $0.id == id }
        next.columnOrder = next.orderedColumnIDs
        changed(next)
    }
}

@MainActor
final class RequestLogExtraColumnEditor: NSViewController {
    private var draft: RequestLogExtraColumn
    private let isNew: Bool
    private let onSave: (RequestLogExtraColumn) -> Void
    private let field = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stage = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var name = ActionComboBox(draft.name, placeholder: "字段名", onChange: { [weak self] in
        self?.draft.name = $0; self?.validate()
    })
    private lazy var customTitle = ActionTextField(draft.title, placeholder: "留空使用字段名") { [weak self] in self?.draft.title = $0 }
    private let nameLabel = NativeUI.label("名称", size: 12, secondary: true)
    private let error = NativeUI.label("", size: 12, secondary: true)
    private lazy var save = ActionButton(title: isNew ? "添加" : "保存") { [weak self] in self?.submit() }

    init(column: RequestLogExtraColumn?, onSave: @escaping (RequestLogExtraColumn) -> Void) {
        draft = column ?? .init(); isNew = column == nil; self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        field.addItems(withTitles: RequestLogExtraColumn.Field.allCases.map(\.title))
        field.selectItem(at: RequestLogExtraColumn.Field.allCases.firstIndex(of: draft.field) ?? 0)
        field.target = self; field.action = #selector(changeField)
        stage.target = self; stage.action = #selector(changeStage)
        field.setAccessibilityLabel("字段类型"); stage.setAccessibilityLabel("阶段")
        customTitle.setAccessibilityLabel("列标题")
        customTitle.onSubmit = { [weak self] in self?.submit() }
        let cancel = ActionButton(title: "取消") { [weak self] in self?.dismiss(nil) }
        cancel.keyEquivalent = "\u{1b}"
        let actions = NativeUI.stack([cancel, save], vertical: false)
        let stack = NativeUI.stack([
            NativeUI.label(isNew ? "添加额外列" : "编辑额外列", size: 18, weight: .semibold),
            NativeUI.label("字段类型", size: 12, secondary: true), field,
            NativeUI.label("阶段", size: 12, secondary: true), stage,
            nameLabel, name, NativeUI.label("列标题（可选）", size: 12, secondary: true), customTitle, error, actions
        ], spacing: 8)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for control in [field, stage, name, customTitle, error] {
            control.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        updateFields()
    }
    private func updateFields() {
        if !draft.field.stages.contains(draft.stage) { draft.stage = draft.field.stages[0] }
        stage.removeAllItems(); stage.addItems(withTitles: draft.field.stages.map(\.title))
        stage.selectItem(at: draft.field.stages.firstIndex(of: draft.stage) ?? 0)
        nameLabel.isHidden = !draft.field.needsName; name.isHidden = !draft.field.needsName
        nameLabel.stringValue = draft.field == .header ? "Header 名称" : "查询参数名"
        name.setAccessibilityLabel(nameLabel.stringValue)
        name.placeholderString = draft.field == .header ? "选择或输入 Header" : "例如 page、keyword"
        name.setSuggestions(draft.field == .header ? HeaderNameField.suggestions : [])
        validate()
        preferredContentSize = view.fittingSize
    }
    private func validate() { error.stringValue = draft.validationError ?? " "; save.isEnabled = draft.validationError == nil }
    @objc private func changeField() {
        guard RequestLogExtraColumn.Field.allCases.indices.contains(field.indexOfSelectedItem) else { return }
        draft.field = RequestLogExtraColumn.Field.allCases[field.indexOfSelectedItem]; updateFields()
    }
    @objc private func changeStage() {
        guard draft.field.stages.indices.contains(stage.indexOfSelectedItem) else { return }
        draft.stage = draft.field.stages[stage.indexOfSelectedItem]; validate()
    }
    private func submit() {
        guard view.window?.makeFirstResponder(nil) == true, draft.validationError == nil else { return }
        onSave(draft); dismiss(nil)
    }
}
