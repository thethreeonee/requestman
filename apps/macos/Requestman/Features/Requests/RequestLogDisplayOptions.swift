import AppKit
import RequestmanCore

/// A draft sheet: preview changes immediately; only Apply updates the live log and preferences.
@MainActor
final class RequestLogDisplayOptionsEditor: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                           NSTextFieldDelegate, NSComboBoxDelegate {
    private var draft: RequestLogDisplayOptions
    private let allowLAN: Bool
    private let previewRecords: [CaptureRecord]
    private let workflowNames: [UUID: String]
    private let deviceAliases: [String: String]
    private let onApply: (RequestLogDisplayOptions) -> Void
    private let dragOwner = UUID().uuidString
    private var selectedColumnID: String?
    private var selectedLineID: UUID?
    private var selectedContentID: UUID?
    private var updatingSelection = false
    private var updatingInputs = false
    private let columns = NSTableView()
    private let lines = RequestLogLayoutTableView()
    private weak var contentDropCell: RequestLogLayoutLineCell?
    private let preview = RequestRecordsTable(isPreview: true)
    private let columnHeading = NativeUI.label("", size: 15, weight: .semibold)
    private let columnTitle = NSTextField(string: "")
    private let field = NSPopUpButton(frame: .zero, pullsDown: false)
    private let source = NSPopUpButton(frame: .zero, pullsDown: false)
    private let name = NSComboBox(frame: .zero)
    private let emptyMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let replacement = NSTextField(string: "")
    private let horizontal = NSSegmentedControl()
    private let vertical = NSSegmentedControl()
    private let appearanceEditor = RequestLogContentAppearanceEditor()
    private let validation = NativeUI.label("", size: 12, secondary: true)
    private let nameLabel = NativeUI.label("名称", size: 13)
    private var sourceRow: NSStackView!
    private var nameRow: NSStackView!
    private var replacementRow: NSStackView!
    private var inspector: NSStackView!
    private lazy var removeColumn = iconButton("minus", label: "删除所选列") { [weak self] in self?.deleteColumn() }
    private lazy var addLineButton = ActionButton(title: "添加行") { [weak self] in self?.addLine() }
    private lazy var apply = ActionButton(title: "应用") { [weak self] in self?.submit() }

    init(options: RequestLogDisplayOptions, allowLAN: Bool, records: [CaptureRecord],
         workflowNames: [UUID: String], deviceAliases: [String: String],
         onApply: @escaping (RequestLogDisplayOptions) -> Void) {
        draft = options
        draft.layoutColumns = options.layoutColumns
        self.allowLAN = allowLAN
        previewRecords = records.isEmpty ? Self.sampleRecords() : Array(records.prefix(3))
        self.workflowNames = workflowNames
        self.deviceAliases = deviceAliases
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
        selectedColumnID = draft.layoutColumns.first?.id
        preferredContentSize = NSSize(width: 1320, height: 780)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = FlippedView(frame: NSRect(origin: .zero, size: preferredContentSize))
        configureTables()
        configureInputs()
        configureActionButton(addLineButton)
        configureActionButton(apply)
        let header = NativeUI.stack([
            NativeUI.label("显示选项", size: 20, weight: .semibold),
            NativeUI.label("按列组织内容，按行安排布局", size: 12, secondary: true)
        ], spacing: 4)
        let previewHeading = NativeUI.stack([
            NativeUI.label("整体预览", size: 14, weight: .semibold),
            NativeUI.label("随下方配置更新", size: 12, secondary: true)
        ], vertical: false, spacing: 12)
        preview.heightAnchor.constraint(equalToConstant: 148).isActive = true

        let columnPane = makeColumnPane()
        let layoutPane = makeLayoutPane()
        let inspectorPane = makeInspectorPane()
        let firstDivider = NativeUI.separator(), secondDivider = NativeUI.separator()
        let body = NativeUI.stack([columnPane, firstDivider, layoutPane, secondDivider, inspectorPane], vertical: false, spacing: 16)
        body.distribution = .fill
        columnPane.widthAnchor.constraint(equalToConstant: 188).isActive = true
        inspectorPane.widthAnchor.constraint(equalToConstant: 310).isActive = true
        layoutPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 540).isActive = true
        layoutPane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        layoutPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for divider in [firstDivider, secondDivider] { divider.widthAnchor.constraint(equalToConstant: 1).isActive = true }
        for pane in [columnPane, firstDivider, layoutPane, secondDivider, inspectorPane] {
            pane.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        }
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)

        let restore = ActionButton(title: "恢复默认") { [weak self] in self?.restoreDefaults() }
        let cancel = ActionButton(title: "取消") { [weak self] in self?.dismiss(nil) }
        configureActionButton(restore)
        configureActionButton(cancel)
        cancel.keyEquivalent = "\u{1b}"; apply.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NativeUI.stack([restore, spacer, cancel, apply], vertical: false, spacing: 10)
        let outer = NativeUI.stack([header, previewHeading, preview, NativeUI.separator(), body, validation,
                                    NativeUI.separator(), actions], spacing: 12)
        NativeUI.pin(outer, to: view, insets: NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20))
        for item in [header, previewHeading, preview, body, validation, actions] {
            item.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        }
        for item in outer.arrangedSubviews where item is NSBox {
            item.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    private var selectedColumnIndex: Int? { draft.layoutColumns.firstIndex { $0.id == selectedColumnID } }
    private var selectedColumn: RequestLogLayoutColumn? { selectedColumnIndex.map { draft.layoutColumns[$0] } }
    private var selectedContent: RequestLogLayoutContent? {
        selectedColumn?.lines.first { $0.id == selectedLineID }?.contents.first { $0.id == selectedContentID }
    }

    private func configureTables() {
        for (table, identifier) in [(columns, "columns"), (lines, "lines")] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.minWidth = 0
            table.addTableColumn(column)
            table.headerView = nil
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.allowsMultipleSelection = false
            table.allowsEmptySelection = true
            table.intercellSpacing = .zero
            table.dataSource = self; table.delegate = self
            table.setDraggingSourceOperationMask(.move, forLocal: true)
        }
        columns.rowHeight = 48; columns.style = .plain
        columns.selectionHighlightStyle = .none
        columns.backgroundColor = .white
        columns.registerForDraggedTypes([.requestLogColumn])
        columns.setAccessibilityLabel("日志显示列")
        lines.style = .plain
        lines.backgroundColor = .white
        lines.selectionHighlightStyle = .none
        lines.registerForDraggedTypes([.requestLogLine, .requestLogContent])
        lines.setAccessibilityLabel("列内行及内容")
        lines.clearDropFeedback = { [weak self] in self?.clearContentDropFeedback() }
    }

    private func configureInputs() {
        for input in [columnTitle, replacement] { input.delegate = self }
        columnTitle.placeholderString = "列标题"; columnTitle.setAccessibilityLabel("列标题")
        replacement.placeholderString = "输入无值时显示的文字"; replacement.setAccessibilityLabel("替代文本")
        name.isEditable = true; name.usesSingleLineMode = true; name.delegate = self
        name.numberOfVisibleItems = 10
        field.addItems(withTitles: RequestLogContentField.allCases.map(\.title))
        field.target = self; field.action = #selector(changeField)
        field.setAccessibilityLabel("内容类型")
        if !allowLAN, let index = RequestLogContentField.allCases.firstIndex(of: .device) {
            field.item(at: index)?.isEnabled = false
        }
        field.autoenablesItems = false
        source.target = self; source.action = #selector(changeSource); source.setAccessibilityLabel("字段来源")
        emptyMode.addItems(withTitles: ["不显示", "自定义文本"])
        emptyMode.target = self; emptyMode.action = #selector(changeEmptyMode)
        emptyMode.setAccessibilityLabel("无值时")
        if #available(macOS 26.0, *) {
            for control in [field, source, emptyMode] { control.borderShape = .capsule }
        }
        configureAlignment(horizontal, symbols: ["text.alignleft", "text.aligncenter", "text.alignright"],
                           labels: ["左对齐", "居中对齐", "右对齐"], action: #selector(changeHorizontal))
        configureAlignment(vertical, symbols: ["align.vertical.top", "align.vertical.center", "align.vertical.bottom"],
                           labels: ["顶部对齐", "垂直居中", "底部对齐"], action: #selector(changeVertical))
        horizontal.setAccessibilityLabel("水平对齐"); vertical.setAccessibilityLabel("垂直对齐")
    }

    private func configureAlignment(_ control: NSSegmentedControl, symbols: [String], labels: [String], action: Selector) {
        control.segmentCount = symbols.count; control.trackingMode = .selectOne
        control.segmentStyle = .automatic; control.target = self; control.action = action
        control.segmentDistribution = .fillEqually
        if #available(macOS 26.0, *) { control.borderShape = .capsule }
        if #available(macOS 27.0, *) { control.role = .tabs }
        for index in symbols.indices {
            control.setImage(NSImage(systemSymbolName: symbols[index], accessibilityDescription: labels[index]), forSegment: index)
            control.setToolTip(labels[index], forSegment: index)
        }
    }

    private func makeColumnPane() -> NSStackView {
        let scroll = tableBox(columns)
        let add = iconButton("plus", label: "添加列") { [weak self] in self?.addColumn() }
        let tools = NativeUI.stack([add, removeColumn], vertical: false, spacing: 6)
        let pane = NativeUI.stack([NativeUI.label("列", size: 15, weight: .semibold), scroll, tools], spacing: 8)
        scroll.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        return pane
    }

    private func makeLayoutPane() -> NSStackView {
        let scroll = tableBox(lines)
        addLineButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        let pane = NativeUI.stack([
            columnHeading, formRow("列标题", columnTitle), NativeUI.separator(),
            NativeUI.label("内容布局", size: 14, weight: .semibold),
            scroll, addLineButton
        ], spacing: 10)
        for item in pane.arrangedSubviews where item !== columnHeading && item !== addLineButton {
            item.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        }
        return pane
    }

    private func makeInspectorPane() -> NSScrollView {
        sourceRow = formRow("来源", source)
        nameRow = formRow(nameLabel, name)
        replacementRow = formRow("替代文本", replacement)
        appearanceEditor.onChange = { [weak self] appearance in
            self?.updateSelectedContent { $0.appearance = appearance }
        }
        appearanceEditor.onValidationChange = { [weak self] in self?.validate() }
        inspector = NativeUI.stack([
            NativeUI.label("内容设置", size: 15, weight: .semibold),
            formRow("内容", field), sourceRow, nameRow, NativeUI.separator(),
            NativeUI.label("对齐", size: 14, weight: .semibold),
            NativeUI.label("仅作用于当前内容的行内位置。", size: 11, secondary: true),
            formRow("水平对齐", horizontal), formRow("垂直对齐", vertical), NativeUI.separator(),
            NativeUI.label("空值", size: 14, weight: .semibold),
            formRow("无值时", emptyMode), replacementRow, appearanceEditor
        ], spacing: 12)
        for item in inspector.arrangedSubviews where item is NSStackView || item is NSBox {
            item.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        }
        return RequestLogFormScrollView(content: inspector)
    }

    private func formRow(_ title: String, _ control: NSView) -> NSStackView { formRow(NativeUI.label(title), control) }
    private func formRow(_ label: NSTextField, _ control: NSView) -> NSStackView {
        label.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let row = NativeUI.stack([label, control], vertical: false, spacing: 8)
        row.distribution = .fill
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        return row
    }
    private func tableBox(_ table: NSTableView) -> NSBox {
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .white
        let box = NSBox()
        // The requested white surface needs native foreground colors resolved for a light appearance.
        box.appearance = NSAppearance(named: .aqua)
        box.boxType = .custom; box.titlePosition = .noTitle
        box.fillColor = .white; box.borderColor = .separatorColor
        box.borderWidth = 1; box.cornerRadius = 8
        box.contentViewMargins = NSSize(width: 6, height: 6)
        box.contentView = scroll
        box.setContentHuggingPriority(.defaultLow, for: .vertical)
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return box
    }
    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title: "", action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly; button.toolTip = label; button.setAccessibilityLabel(label)
        configureActionButton(button, iconOnly: true)
        return button
    }
    private func configureActionButton(_ button: NSButton, iconOnly: Bool = false) {
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = iconOnly ? .circle : .capsule
        } else {
            button.bezelStyle = iconOnly ? .circular : .automatic
        }
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    private func normalizeSelection() {
        let all = draft.layoutColumns
        if !all.contains(where: { $0.id == selectedColumnID }) { selectedColumnID = all.first?.id }
        let column = selectedColumn
        if column?.lines.contains(where: { $0.id == selectedLineID }) != true { selectedLineID = column?.lines.first?.id }
        let line = column?.lines.first { $0.id == selectedLineID }
        if line?.contents.contains(where: { $0.id == selectedContentID }) != true { selectedContentID = line?.contents.first?.id }
    }
    private func refresh() {
        clearContentDropFeedback()
        normalizeSelection()
        updatingSelection = true
        columns.reloadData(); lines.reloadData()
        columns.selectRowIndexes(selectedColumnIndex.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        updatingSelection = false
        columnHeading.stringValue = selectedColumnIndex.map { "第 \($0 + 1) 列" } ?? "添加列以开始配置"
        columnTitle.stringValue = selectedColumn?.title ?? ""
        columnTitle.isEnabled = selectedColumn != nil
        removeColumn.isEnabled = selectedColumn != nil
        addLineButton.isEnabled = selectedColumn != nil
        updateInspector()
        refreshPreview()
        validate()
    }
    private func refreshPreview() {
        preview.update(records: previewRecords, selectedID: nil, workflowNames: workflowNames,
                       deviceAliases: deviceAliases, showsDeviceSource: allowLAN, displayOptions: draft)
    }
    private func updateInspector() {
        updatingInputs = true
        defer { updatingInputs = false }
        let content = selectedContent
        for control in [field, source, name, horizontal, vertical, emptyMode, replacement] { control.isEnabled = content != nil }
        field.selectItem(at: content.flatMap { RequestLogContentField.allCases.firstIndex(of: $0.field) } ?? -1)
        source.removeAllItems()
        if let content {
            source.addItems(withTitles: content.field.stages.map(\.title))
            source.selectItem(at: content.field.stages.firstIndex(of: content.stage) ?? -1)
        }
        sourceRow.isHidden = content?.field.stages.isEmpty != false
        nameRow.isHidden = content?.field.needsName != true
        nameLabel.stringValue = content?.field == .header ? "Header 名称" : "参数名"
        name.setAccessibilityLabel(nameLabel.stringValue)
        name.removeAllItems()
        if content?.field == .header { name.addItems(withObjectValues: HeaderNameField.suggestions) }
        name.placeholderString = content?.field == .header ? "选择或输入 Header" : "例如 page、keyword"
        name.stringValue = content?.name ?? ""
        horizontal.selectedSegment = content.flatMap { RequestLogHorizontalAlignment.allCases.firstIndex(of: $0.horizontalAlignment) } ?? -1
        vertical.selectedSegment = content.flatMap { RequestLogVerticalAlignment.allCases.firstIndex(of: $0.verticalAlignment) } ?? -1
        emptyMode.selectItem(at: content?.emptyBehavior == .customText ? 1 : 0)
        replacement.stringValue = content?.emptyText ?? ""
        replacementRow.isHidden = content?.emptyBehavior != .customText
        appearanceEditor.configure(content: content)
    }
    private func validate() {
        let invalid = draft.layoutColumns.lazy.flatMap(\.lines).flatMap(\.contents).first { $0.validationError != nil }
        let message = invalid.map { $0.displayTitle + "：" + ($0.validationError ?? "") }
            ?? appearanceEditor.validationError
        validation.stringValue = message ?? ""
        validation.textColor = .systemRed
        validation.isHidden = message == nil
        apply.isEnabled = message == nil
    }

    private func updateSelectedContent(_ change: (inout RequestLogLayoutContent) -> Void, rebuildInspector: Bool = false) {
        guard let column = selectedColumnIndex else { return }
        var all = draft.layoutColumns
        guard let line = all[column].lines.firstIndex(where: { $0.id == selectedLineID }),
              let content = all[column].lines[line].contents.firstIndex(where: { $0.id == selectedContentID }) else { return }
        change(&all[column].lines[line].contents[content])
        draft.layoutColumns = all
        columns.reloadData(); lines.reloadData()
        if rebuildInspector { updateInspector() }
        refreshPreview(); validate()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let control = notification.object as? NSControl else { return }
        if control === columnTitle, let index = selectedColumnIndex {
            var all = draft.layoutColumns; all[index].title = columnTitle.stringValue
            draft.layoutColumns = all; columns.reloadData(); refreshPreview()
        } else if control === name { updateSelectedContent { $0.name = name.stringValue } }
        else if control === replacement { updateSelectedContent { $0.emptyText = replacement.stringValue } }
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !updatingInputs, let value = name.objectValueOfSelectedItem as? String else { return }
        name.stringValue = value; updateSelectedContent { $0.name = value }
    }
    @objc private func changeField() {
        guard RequestLogContentField.allCases.indices.contains(field.indexOfSelectedItem) else { return }
        let next = RequestLogContentField.allCases[field.indexOfSelectedItem]
        updateSelectedContent({ content in
            content.field = next
            if !next.stages.contains(content.stage), let stage = next.stages.first { content.stage = stage }
        }, rebuildInspector: true)
    }
    @objc private func changeSource() {
        guard let content = selectedContent, content.field.stages.indices.contains(source.indexOfSelectedItem) else { return }
        let next = content.field.stages[source.indexOfSelectedItem]
        updateSelectedContent { $0.stage = next }
    }
    @objc private func changeHorizontal() {
        guard RequestLogHorizontalAlignment.allCases.indices.contains(horizontal.selectedSegment) else { return }
        updateSelectedContent { $0.horizontalAlignment = RequestLogHorizontalAlignment.allCases[horizontal.selectedSegment] }
    }
    @objc private func changeVertical() {
        guard RequestLogVerticalAlignment.allCases.indices.contains(vertical.selectedSegment) else { return }
        updateSelectedContent { $0.verticalAlignment = RequestLogVerticalAlignment.allCases[vertical.selectedSegment] }
    }
    @objc private func changeEmptyMode() {
        updateSelectedContent({ $0.emptyBehavior = emptyMode.indexOfSelectedItem == 1 ? .customText : .hide }, rebuildInspector: true)
    }

    private func addColumn() {
        view.window?.makeFirstResponder(nil)
        let column = RequestLogLayoutColumn(title: "新列", lines: [.init(contents: [.init(field: .url)])])
        var all = draft.layoutColumns; all.append(column); draft.layoutColumns = all
        selectedColumnID = column.id; selectedLineID = nil; selectedContentID = nil; refresh()
    }
    private func deleteColumn() {
        guard let index = selectedColumnIndex else { return }
        view.window?.makeFirstResponder(nil)
        var all = draft.layoutColumns; all.remove(at: index); draft.layoutColumns = all
        selectedColumnID = all.indices.contains(index) ? all[index].id : all.last?.id
        selectedLineID = nil; selectedContentID = nil; refresh()
    }
    private func addLine() {
        guard let column = selectedColumnIndex else { return }
        view.window?.makeFirstResponder(nil)
        let line = RequestLogLayoutLine()
        var all = draft.layoutColumns; all[column].lines.append(line); draft.layoutColumns = all
        selectedLineID = line.id; selectedContentID = nil; refresh()
    }
    private func restoreDefaults() {
        view.window?.makeFirstResponder(nil)
        draft = RequestLogDisplayOptions(); draft.layoutColumns = draft.layoutColumns
        selectedColumnID = nil; selectedLineID = nil; selectedContentID = nil; refresh()
    }
    private func submit() {
        guard view.window?.makeFirstResponder(nil) == true else { return }
        validate(); guard apply.isEnabled else { return }
        onApply(draft); dismiss(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === columns ? draft.layoutColumns.count : selectedColumn?.lines.count ?? 0 }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === lines, let column = selectedColumn, column.lines.indices.contains(row) else {
            return tableView.rowHeight
        }
        let cell = RequestLogLayoutLineCell(line: column.lines[row], index: row,
                                          selectedID: selectedContentID, owner: dragOwner)
        return ceil(cell.intrinsicContentSize.height)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === columns {
            let all = draft.layoutColumns
            guard all.indices.contains(row) else { return nil }
            let cell = RequestLogColumnListCell()
            cell.configure(title: "\(row + 1)  " + all[row].title,
                           summary: all[row].lines.flatMap(\.contents).map(\.displayTitle).joined(separator: " · "))
            cell.setSelected(all[row].id == selectedColumnID)
            return cell
        }
        guard let column = selectedColumn, column.lines.indices.contains(row) else { return nil }
        let line = column.lines[row]
        let cell = RequestLogLayoutLineCell(line: line, index: row, selectedID: selectedContentID, owner: dragOwner)
        cell.selectContent = { [weak self] id in
            guard let self else { return }
            view.window?.makeFirstResponder(nil)
            selectedLineID = line.id; selectedContentID = id; refresh()
        }
        cell.addContent = { [weak self] button in self?.showAddContent(lineID: line.id, anchor: button) }
        cell.showActions = { [weak self] button in self?.showLineActions(lineID: line.id, anchor: button) }
        cell.contentActions = { [weak self] id, button in self?.showContentActions(lineID: line.id, contentID: id, anchor: button) }
        cell.dragEnded = { [weak self] in self?.clearContentDropFeedback() }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, notification.object as? NSTableView === columns,
              draft.layoutColumns.indices.contains(columns.selectedRow) else { return }
        view.window?.makeFirstResponder(nil)
        selectedColumnID = draft.layoutColumns[columns.selectedRow].id
        selectedLineID = nil; selectedContentID = nil; refresh()
    }

    private static func sampleRecords() -> [CaptureRecord] {
        var success = CaptureRecord(method: "GET", url: "https://api.example.com/v1/orders")
        success.status = 200; success.originalStatus = 200; success.duration = 0.128
        success.project = "商城项目"; success.workflow = "订单列表"; success.matchedWorkflowID = UUID()
        success.requestHeaders = [.init("Accept", "application/json")]
        success.responseHeaders = [.init("Content-Type", "application/json")]
        success.deviceSource = "local"
        var pending = CaptureRecord(method: "POST", url: "https://api.example.com/v1/login")
        pending.startedAt = success.startedAt.addingTimeInterval(-1)
        pending.connectionState = .connecting
        pending.deviceSource = "local"
        return [success, pending]
    }
}

@MainActor
private extension RequestLogDisplayOptionsEditor {
    func showAddContent(lineID: UUID, anchor: NSButton) {
        let menu = NSMenu(); menu.autoenablesItems = false
        for field in RequestLogContentField.allCases {
            menu.addItem(RequestActionsMenu.item(field.title,
                reason: field == .device && !allowLAN ? "开启允许局域网设备连接后可显示" : nil) { [weak self] in
                guard let self, let column = selectedColumnIndex else { return }
                view.window?.makeFirstResponder(nil)
                var all = draft.layoutColumns
                guard let line = all[column].lines.firstIndex(where: { $0.id == lineID }) else { return }
                let content = RequestLogLayoutContent(field: field, stage: field.stages.first ?? .originalRequest)
                all[column].lines[line].contents.append(content); draft.layoutColumns = all
                selectedLineID = lineID; selectedContentID = content.id; refresh()
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 3), in: anchor)
    }

    func showLineActions(lineID: UUID, anchor: NSButton) {
        guard let column = selectedColumn, let index = column.lines.firstIndex(where: { $0.id == lineID }) else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(RequestActionsMenu.item("上移", reason: index == 0 ? "已在第一行" : nil) { [weak self] in
            self?.moveLine(lineID, to: index - 1)
        })
        menu.addItem(RequestActionsMenu.item("下移", reason: index == column.lines.count - 1 ? "已在最后一行" : nil) { [weak self] in
            self?.moveLine(lineID, to: index + 2)
        })
        menu.addItem(.separator())
        menu.addItem(RequestActionsMenu.item("删除行") { [weak self] in
            guard let self, let column = selectedColumnIndex else { return }
            view.window?.makeFirstResponder(nil)
            var all = draft.layoutColumns
            all[column].lines.removeAll { $0.id == lineID }; draft.layoutColumns = all
            refresh()
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 3), in: anchor)
    }

    func showContentActions(lineID: UUID, contentID: UUID, anchor: NSButton) {
        guard let column = selectedColumn, let line = column.lines.firstIndex(where: { $0.id == lineID }),
              let index = column.lines[line].contents.firstIndex(where: { $0.id == contentID }) else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(RequestActionsMenu.item("左移", reason: index == 0 ? "已在最左侧" : nil) { [weak self] in
            self?.moveContent(contentID, toColumn: column.id, line: lineID, position: index - 1)
        })
        menu.addItem(RequestActionsMenu.item("右移", reason: index == column.lines[line].contents.count - 1 ? "已在最右侧" : nil) { [weak self] in
            self?.moveContent(contentID, toColumn: column.id, line: lineID, position: index + 2)
        })
        let move = NSMenuItem(title: "移动到", action: nil, keyEquivalent: "")
        let destinations = NSMenu(); destinations.autoenablesItems = false
        for destination in draft.layoutColumns {
            let item = NSMenuItem(title: destination.title.isEmpty ? "未命名列" : destination.title, action: nil, keyEquivalent: "")
            let targetLines = NSMenu(); targetLines.autoenablesItems = false
            for (number, target) in destination.lines.enumerated() {
                targetLines.addItem(RequestActionsMenu.item("第 \(number + 1) 行",
                    reason: destination.id == column.id && target.id == lineID ? "当前所在行" : nil) { [weak self] in
                    self?.moveContent(contentID, toColumn: destination.id, line: target.id, position: target.contents.count)
                })
            }
            targetLines.addItem(RequestActionsMenu.item("新行") { [weak self] in
                guard let self else { return }
                var all = draft.layoutColumns
                guard let index = all.firstIndex(where: { $0.id == destination.id }) else { return }
                let target = RequestLogLayoutLine(); all[index].lines.append(target); draft.layoutColumns = all
                moveContent(contentID, toColumn: destination.id, line: target.id, position: 0)
            })
            item.submenu = targetLines; destinations.addItem(item)
        }
        move.submenu = destinations; menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(RequestActionsMenu.item("删除内容") { [weak self] in
            guard let self, let column = selectedColumnIndex else { return }
            view.window?.makeFirstResponder(nil)
            var all = draft.layoutColumns
            guard let line = all[column].lines.firstIndex(where: { $0.id == lineID }) else { return }
            all[column].lines[line].contents.removeAll { $0.id == contentID }
            draft.layoutColumns = all; refresh()
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 3), in: anchor)
    }

    @discardableResult
    func moveLine(_ lineID: UUID, to position: Int) -> Bool {
        view.window?.makeFirstResponder(nil)
        guard let column = selectedColumnIndex else { return false }
        var all = draft.layoutColumns
        guard let source = all[column].lines.firstIndex(where: { $0.id == lineID }),
              (0...all[column].lines.count).contains(position) else { return false }
        let destination = position > source ? position - 1 : position
        guard destination != source else { return false }
        let line = all[column].lines.remove(at: source); all[column].lines.insert(line, at: destination)
        draft.layoutColumns = all; selectedLineID = lineID; refresh()
        return true
    }

    @discardableResult
    func moveContent(_ contentID: UUID, toColumn columnID: String, line lineID: UUID, position: Int) -> Bool {
        view.window?.makeFirstResponder(nil)
        var all = draft.layoutColumns
        var origin: (column: Int, line: Int, content: Int)?
        for column in all.indices {
            for line in all[column].lines.indices {
                if let content = all[column].lines[line].contents.firstIndex(where: { $0.id == contentID }) {
                    origin = (column, line, content)
                }
            }
        }
        guard let origin, let targetColumn = all.firstIndex(where: { $0.id == columnID }),
              let targetLine = all[targetColumn].lines.firstIndex(where: { $0.id == lineID }),
              (0...all[targetColumn].lines[targetLine].contents.count).contains(position) else { return false }
        let sameLine = origin.column == targetColumn && origin.line == targetLine
        let destination = sameLine && position > origin.content ? position - 1 : position
        guard !sameLine || destination != origin.content else { return false }
        let content = all[origin.column].lines[origin.line].contents.remove(at: origin.content)
        all[targetColumn].lines[targetLine].contents.insert(content, at: destination)
        draft.layoutColumns = all
        selectedColumnID = columnID; selectedLineID = lineID; selectedContentID = contentID; refresh()
        return true
    }

    func drag(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> RequestLogLayoutDrag? {
        guard let text = pasteboard.string(forType: type), let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(RequestLogLayoutDrag.self, from: data), value.owner == dragOwner else { return nil }
        return value
    }

    func clearContentDropFeedback() {
        contentDropCell?.showInsertion(at: nil)
        contentDropCell = nil
    }

    func rowInsertionIndex(in table: NSTableView, at location: NSPoint) -> Int {
        let point = table.convert(location, from: nil)
        let row = table.row(at: point)
        guard row >= 0 else { return point.y < 0 ? 0 : table.numberOfRows }
        return point.y < table.rect(ofRow: row).midY ? row : row + 1
    }

    /// Resolve both hover and release from the actual pointer, not an AppKit row insertion proposal.
    func contentDropTarget(_ info: any NSDraggingInfo, autoscroll: Bool) -> (row: Int, position: Int)? {
        guard let column = selectedColumn, !column.lines.isEmpty,
              let value = drag(from: info.draggingPasteboard, type: .requestLogContent),
              let contentID = value.contentID else { return nil }
        let point = lines.convert(info.draggingLocation, from: nil)
        var row = lines.row(at: point)
        let belowLastRow = row == -1 && point.y >= lines.rect(ofRow: column.lines.count - 1).maxY
        if belowLastRow { row = column.lines.count - 1 }
        guard column.lines.indices.contains(row),
              let cell = lines.view(atColumn: 0, row: row, makeIfNecessary: true) as? RequestLogLayoutLineCell else { return nil }
        cell.layoutSubtreeIfNeeded()
        let local = cell.convert(info.draggingLocation, from: nil)
        if autoscroll && !belowLastRow { cell.autoscrollContents(at: local) }
        let position = belowLastRow ? column.lines[row].contents.count : cell.contentInsertionIndex(at: local)
        var origin: (column: String, line: UUID, index: Int)?
        for sourceColumn in draft.layoutColumns {
            for sourceLine in sourceColumn.lines {
                if let index = sourceLine.contents.firstIndex(where: { $0.id == contentID }) {
                    origin = (sourceColumn.id, sourceLine.id, index)
                }
            }
        }
        guard let origin else { return nil }
        if origin.column == column.id && origin.line == column.lines[row].id {
            let destination = position > origin.index ? position - 1 : position
            guard destination != origin.index else { return nil }
        }
        return (row, position)
    }
}

extension RequestLogDisplayOptionsEditor {
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let value: RequestLogLayoutDrag
        let type: NSPasteboard.PasteboardType
        if tableView === columns {
            guard draft.layoutColumns.indices.contains(row) else { return nil }
            value = .init(owner: dragOwner, columnID: draft.layoutColumns[row].id)
            type = .requestLogColumn
        } else {
            guard let column = selectedColumn, column.lines.indices.contains(row) else { return nil }
            value = .init(owner: dragOwner, columnID: column.id, lineID: column.lines[row].id)
            type = .requestLogLine
        }
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return nil }
        let item = NSPasteboardItem(); item.setString(text, forType: type)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if tableView === columns {
            let position = rowInsertionIndex(in: tableView, at: info.draggingLocation)
            guard let value = drag(from: info.draggingPasteboard, type: .requestLogColumn),
                  let source = draft.layoutColumns.firstIndex(where: { $0.id == value.columnID }),
                  (0...draft.layoutColumns.count).contains(position) else { return [] }
            guard (position > source ? position - 1 : position) != source else { return [] }
            tableView.setDropRow(position, dropOperation: .above)
            return .move
        }
        clearContentDropFeedback()
        guard let column = selectedColumn else { return [] }
        let position = rowInsertionIndex(in: tableView, at: info.draggingLocation)
        if let value = drag(from: info.draggingPasteboard, type: .requestLogLine),
           value.columnID == column.id, let source = column.lines.firstIndex(where: { $0.id == value.lineID }),
           (0...column.lines.count).contains(position) {
            guard (position > source ? position - 1 : position) != source else { return [] }
            tableView.setDropRow(position, dropOperation: .above)
            return .move
        }
        if let target = contentDropTarget(info, autoscroll: true),
           let cell = lines.view(atColumn: 0, row: target.row, makeIfNecessary: true) as? RequestLogLayoutLineCell {
            contentDropCell = cell
            cell.showInsertion(at: target.position)
            tableView.setDropRow(target.row, dropOperation: .on)
            return .move
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        view.window?.makeFirstResponder(nil)
        defer { clearContentDropFeedback() }
        if tableView === columns {
            var all = draft.layoutColumns
            guard let value = drag(from: info.draggingPasteboard, type: .requestLogColumn),
                  let source = all.firstIndex(where: { $0.id == value.columnID }),
                  (0...all.count).contains(row) else { return false }
            let destination = row > source ? row - 1 : row
            guard source != destination else { return false }
            let column = all.remove(at: source); all.insert(column, at: destination)
            draft.layoutColumns = all; refresh()
            return true
        }
        guard let column = selectedColumn else { return false }
        if let value = drag(from: info.draggingPasteboard, type: .requestLogLine),
           value.columnID == column.id, let line = value.lineID {
            return moveLine(line, to: row)
        }
        guard let target = contentDropTarget(info, autoscroll: false),
              let value = drag(from: info.draggingPasteboard, type: .requestLogContent),
              let content = value.contentID else { return false }
        return moveContent(content, toColumn: column.id, line: column.lines[target.row].id, position: target.position)
    }
}
