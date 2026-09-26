import AppKit
import RequestmanCore

extension ModificationKind {
    var symbolName: String {
        switch self {
        case .setHeader: "text.badge.plus"
        case .removeHeader: "text.badge.minus"
        case .replaceBody: "doc.text"
        case .rewriteURL: "link"
        case .setQueryParameter: "slider.horizontal.3"
        case .replaceURLString: "arrow.triangle.2.circlepath"
        case .setMethod: "arrow.left.arrow.right"
        case .setStatus: "number.circle"
        case .mock: "doc.on.doc"
        case .redirect: "arrow.turn.up.right"
        case .script: "chevron.left.forwardslash.chevron.right"
        }
    }
}

@MainActor final class FlowEditorViewController: ObservedViewController {
    let model: WorkspaceModel
    private let project = NativeUI.label("", size: 12, secondary: true)
    private lazy var name = ActionTextField(placeholder: "请求修改名称") { [weak self] value in self?.modify { $0.name = value } }
    private lazy var enabled = RulesSwitch { [weak self] value in self?.modify { $0.enabled = value } }
    private lazy var target = ActionPopUpButton(items: WorkflowMatchTarget.allCases.map(\.title)) { [weak self] index in self?.modify { $0.matchTarget = WorkflowMatchTarget.allCases[index] } }
    private lazy var rule = ActionPopUpButton(items: WorkflowMatchRule.allCases.map(\.title)) { [weak self] index in self?.modify { $0.matchRule = WorkflowMatchRule.allCases[index] } }
    private let methods = ["*", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    private lazy var method = ActionPopUpButton(items: methods.map { $0 == "*" ? "全部" : $0 }) { [weak self] index in guard let self else { return }; modify { $0.method = methods[index] } }
    private lazy var pattern = ActionTextField(placeholder: "匹配值") { [weak self] value in self?.modify { $0.matchPattern = value } }
    private lazy var headerName = HeaderNameField { [weak self] value in self?.modify { $0.matchHeaderName = value } }
    private let headerEnabled = NSButton(checkboxWithTitle: "Header", target: nil, action: nil)
    private lazy var headerRule = ActionPopUpButton(items: WorkflowMatchRule.allCases.map(\.title)) { [weak self] index in self?.modify { $0.matchHeaderRule = WorkflowMatchRule.allCases[index] } }
    private lazy var headerPattern = ActionTextField(placeholder: "Header 匹配值") { [weak self] value in self?.modify { $0.matchHeaderPattern = value } }
    private var headerFields: NSStackView!
    private let headerExplanation = NativeUI.label("", size: 11, secondary: true)
    private let explanation = NativeUI.label("", size: 11, secondary: true)
    private lazy var requestLane = RulesStepLane(model: model, response: false)
    private lazy var responseLane = RulesStepLane(model: model, response: true)
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        name.isBezeled = false; name.drawsBackground = false; name.font = .systemFont(ofSize: 22, weight: .bold)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let title = NativeUI.stack([name, NativeUI.label("已启用"), enabled], vertical: false)
        method.setAccessibilityLabel("请求方法匹配")
        target.setAccessibilityLabel("地址匹配目标")
        rule.setAccessibilityLabel("地址匹配规则")
        pattern.setAccessibilityLabel("匹配值")
        headerName.setAccessibilityLabel("匹配 Header 名称")
        headerName.placeholderString = "Header 名称"
        headerEnabled.target = self; headerEnabled.action = #selector(toggleHeaderMatching)
        headerEnabled.setAccessibilityLabel("同时匹配 Header")
        headerRule.setAccessibilityLabel("Header 匹配规则")
        headerPattern.setAccessibilityLabel("Header 匹配值")
        for field in [pattern, headerPattern] {
            field.cell?.usesSingleLineMode = true
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.lineBreakMode = .byClipping
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let targetWidth: CGFloat = 130
        target.widthAnchor.constraint(equalToConstant: targetWidth).isActive = true
        for picker in [rule, headerRule] { picker.widthAnchor.constraint(equalToConstant: 90).isActive = true }
        method.widthAnchor.constraint(equalToConstant: 105).isActive = true
        headerName.widthAnchor.constraint(equalToConstant: 240).isActive = true
        headerEnabled.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let methodLabel = NativeUI.label("请求方法")
        methodLabel.widthAnchor.constraint(equalToConstant: targetWidth).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let methodRow = NativeUI.stack([methodLabel, method, spacer], vertical: false, spacing: 8)
        methodRow.identifier = .init("rules.matchMethodRow")
        let addressRow = NativeUI.stack([target, rule, pattern], vertical: false, spacing: 8)
        addressRow.identifier = .init("rules.matchAddressRow")
        let addressGroup = NativeUI.stack([addressRow, explanation], spacing: 6)
        addressRow.widthAnchor.constraint(equalTo: addressGroup.widthAnchor).isActive = true
        explanation.widthAnchor.constraint(equalTo: addressGroup.widthAnchor).isActive = true
        let headerInputs = HeaderMatchInputRow(name: headerName, rule: headerRule, pattern: headerPattern)
        headerFields = NativeUI.stack([headerInputs, headerExplanation], spacing: 6)
        for child in [headerInputs, headerExplanation] { child.widthAnchor.constraint(equalTo: headerFields.widthAnchor).isActive = true }
        let headerRow = NativeUI.stack([headerEnabled, headerFields], vertical: false, spacing: 8)
        headerRow.identifier = .init("rules.matchHeaderRow")
        headerRow.alignment = .top; headerRow.distribution = .fill
        // Keep the hidden fields in layout so the fixed-width checkbox cannot shrink the row.
        headerRow.detachesHiddenViews = false
        headerFields.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for note in [explanation, headerExplanation] {
            note.maximumNumberOfLines = 0; note.lineBreakMode = .byWordWrapping
            note.textColor = .systemRed
        }
        let conditionRows: [NSView] = [methodRow, NativeUI.separator(), addressGroup, NativeUI.separator(), headerRow]
        let conditions = NativeUI.stack(conditionRows, spacing: 10)
        conditions.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for row in conditionRows { row.widthAnchor.constraint(equalTo: conditions.widthAnchor, constant: -24).isActive = true }
        let box = NSBox(); box.titlePosition = .noTitle; box.contentViewMargins = .zero
        box.contentView = NSView(); NativeUI.pin(conditions, to: box.contentView!)
        let matching = NativeUI.stack([NativeUI.label("满足以下所有条件", weight: .medium), box], spacing: 8)
        box.widthAnchor.constraint(equalTo: matching.widthAnchor).isActive = true
        let lanes = NativeUI.stack([requestLane, responseLane], vertical: false, spacing: 20)
        lanes.alignment = .top; lanes.distribution = .fillEqually
        let preview = ActionButton(title: "预览流程") { [weak self] in
            guard let self, let workflow = model.workflow else { return }
            presentAsSheet(WorkflowPreviewViewController(workflow: workflow, environment: model.document.environment))
        }
        preview.image = NSImage(systemSymbolName: "play", accessibilityDescription: nil); preview.imagePosition = .imageLeading
        let stack = NativeUI.stack([project, title, matching, lanes, preview], spacing: 22)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24))
        for wide in [title, matching, lanes] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        lanes.setContentHuggingPriority(.defaultLow, for: .vertical)
        lanes.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    func focusName() { name.selectText(nil) }
    func canPerform(_ command: WorkspaceCommand) -> Bool {
        requestLane.canPerform(command) || responseLane.canPerform(command)
    }
    func perform(_ command: WorkspaceCommand) {
        if requestLane.canPerform(command) { requestLane.perform(command) }
        else { responseLane.perform(command) }
    }
    override func refresh() {
        guard let workflow = model.workflow else { return }
        project.stringValue = model.projectName
        if name.stringValue != workflow.name { name.stringValue = workflow.name }
        enabled.state = workflow.enabled ? .on : .off
        target.selectItem(at: WorkflowMatchTarget.allCases.firstIndex(of: workflow.matchTarget) ?? 0)
        rule.selectItem(at: WorkflowMatchRule.allCases.firstIndex(of: workflow.matchRule) ?? 0)
        method.selectItem(at: methods.firstIndex(of: workflow.method) ?? 0)
        if pattern.stringValue != workflow.matchPattern { pattern.stringValue = workflow.matchPattern }
        if headerName.stringValue != workflow.matchHeaderName { headerName.stringValue = workflow.matchHeaderName }
        headerEnabled.state = workflow.matchHeaderEnabled ? .on : .off
        headerFields.isHidden = !workflow.matchHeaderEnabled
        headerRule.selectItem(at: WorkflowMatchRule.allCases.firstIndex(of: workflow.matchHeaderRule) ?? 0)
        if headerPattern.stringValue != workflow.matchHeaderPattern { headerPattern.stringValue = workflow.matchHeaderPattern }
        let headerError = WorkflowMatcher.headerValidationError(name: workflow.matchHeaderName, rule: workflow.matchHeaderRule,
                                                               pattern: workflow.matchHeaderPattern)
        headerExplanation.stringValue = headerError ?? ""
        headerExplanation.isHidden = headerError == nil
        headerEnabled.toolTip = "与地址和请求方法同时满足才命中"
        headerName.toolTip = "Header 名称不区分大小写，值区分大小写；同名任一项满足即可"
        let help: String
        switch workflow.matchTarget {
        case .url:
            pattern.placeholderString = "https://api.example.com/orders/*"
            help = "匹配完整 URL，区分大小写。"
        case .host:
            pattern.placeholderString = "*.example.com"
            help = "仅匹配域名，不包含协议、端口和路径；不区分大小写。"
        }
        let error = WorkflowMatcher.validationError(rule: workflow.matchRule, pattern: workflow.matchPattern)
        explanation.stringValue = error ?? ""
        explanation.isHidden = error == nil
        target.toolTip = help; pattern.toolTip = help
        requestLane.refresh(); responseLane.refresh()
        for control in [name, enabled, target, rule, method, pattern, headerName, headerEnabled, headerRule, headerPattern] as [NSControl] { control.isEnabled = model.loaded }
    }
    @objc private func toggleHeaderMatching() { modify { $0.matchHeaderEnabled = headerEnabled.state == .on } }
    private func modify(_ update: (inout RequestWorkflow) -> Void) { guard model.loaded, var workflow = model.workflow else { return }; update(&workflow); model.updateWorkflow(workflow) }
}

/// Only changes native control layout; fields retain their identity and editing state.
@MainActor private final class HeaderMatchInputRow: NSStackView {
    private let valueRow: NSStackView
    private var valueWidth: NSLayoutConstraint!
    private var isCompact = false

    init(name: NSView, rule: NSView, pattern: NSView) {
        valueRow = NativeUI.stack([rule, pattern], vertical: false, spacing: 8)
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 8; distribution = .fill
        valueRow.distribution = .fill
        addArrangedSubview(name); addArrangedSubview(valueRow)
        valueRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueWidth = valueRow.widthAnchor.constraint(equalTo: widthAnchor)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let compact = newSize.width < 446
        guard newSize.width > 0, compact != isCompact else { return }
        isCompact = compact
        Task { @MainActor [weak self] in
            guard let self else { return }
            valueWidth.isActive = false
            orientation = isCompact ? .vertical : .horizontal
            alignment = isCompact ? .leading : .centerY
            valueWidth.isActive = isCompact
            superview?.needsLayout = true
        }
    }
}

@MainActor private final class RulesStepLane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let model: WorkspaceModel
    let response: Bool
    let table = NSTableView()
    private var steps: [ModificationStep] = []
    // Accessibility may request offscreen rows repeatedly. Keep the same cell for
    // unchanged steps instead of rebuilding its NSBox view hierarchy each time.
    private var stepCells: [UUID: (step: ModificationStep, cell: RulesStepCell)] = [:]
    private var updating = false
    private var tableHeight: NSLayoutConstraint!
    private let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private static let dragType = NSPasteboard.PasteboardType("app.requestman.rule-step")
    init(model: WorkspaceModel, response: Bool) {
        self.model = model; self.response = response; super.init(frame: .zero)
        let heading = NativeUI.label(response ? "←  响应阶段" : "→  请求阶段", weight: .semibold)
        let subtitle = NativeUI.label(response ? "服务器 → 客户端" : "客户端 → 服务器", size: 11, secondary: true)
        let column = NSTableColumn(identifier: .init("step")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 64; table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .fullWidth; table.selectionHighlightStyle = .none; table.backgroundColor = .clear; table.dataSource = self; table.delegate = self
        table.allowsEmptySelection = true; table.setAccessibilityLabel(response ? "响应步骤" : "请求步骤")
        table.target = self; table.action = #selector(activateStep(_:))
        table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: 64); tableHeight.isActive = true
        addButton.identifier = .init("rules.addStep")
        addButton.bezelStyle = .rounded; addButton.autoenablesItems = false
        addButton.addItem(withTitle: "添加步骤")
        addButton.item(at: 0)?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.setAccessibilityLabel(response ? "添加响应步骤" : "添加请求步骤")
        for kind in ModificationKind.allCases where kind.supports(response: response) {
            let item = RulesMenuItem(kind.title, symbol: kind.symbolName) { [weak self] in
                guard let self, self.model.loaded else { return }; self.model.addStep(kind, response: self.response)
            }
            // macOS 27 hides menu images by default, even when an image is assigned.
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            addButton.menu?.addItem(item)
        }
        let contents = NativeUI.stack([scroll, addButton], spacing: 10)
        scroll.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
        let box = NSBox(); box.identifier = .init("rules.laneBorder")
        box.boxType = .custom; box.titlePosition = .noTitle
        box.borderWidth = 1; box.borderColor = .separatorColor; box.fillColor = .clear; box.cornerRadius = 10
        box.contentViewMargins = NSSize(width: 10, height: 10)
        box.contentView = NSView(); NativeUI.pin(contents, to: box.contentView!)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = NativeUI.stack([heading, subtitle, box, spacer], spacing: 12)
        NativeUI.pin(stack, to: self)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let current = response ? model.workflow?.responseSteps ?? [] : model.workflow?.requestSteps ?? []
        updating = true; defer { updating = false }
        if current != steps {
            steps = current
            let currentSteps = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            stepCells = stepCells.filter { currentSteps[$0.key] == $0.value.step }
            table.reloadData()
        }
        let rowCount = max(model.workflow?.requestSteps.count ?? 0, model.workflow?.responseSteps.count ?? 0, 1)
        tableHeight.constant = min(CGFloat(rowCount) * 64, 400)
        if model.editingResponse == response, let row = steps.firstIndex(where: { $0.id == model.selectedStepID }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        addButton.isEnabled = model.loaded
        for row in 0..<table.numberOfRows {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RulesStepCell {
                cell.setSelected(model.editingResponse == response && steps[row].id == model.selectedStepID)
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { steps.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard steps.indices.contains(row) else { return nil }
        let step = steps[row]
        let cell: RulesStepCell
        if let cached = stepCells[step.id], cached.cell.number == row + 1 { cell = cached.cell }
        else {
            cell = RulesStepCell(step: step, number: row + 1)
            stepCells[step.id] = (step, cell)
        }
        cell.setSelected(model.editingResponse == response && steps[row].id == model.selectedStepID)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView(); view.selectionHighlightStyle = .none; return view
    }
    @objc private func activateStep(_ sender: NSTableView) {
        guard !updating, model.loaded, steps.indices.contains(sender.selectedRow) else { return }
        model.editingResponse = response; model.selectedStepID = steps[sender.selectedRow].id
        // Start in this table's responder chain so the request stays in its workspace window.
        _ = sender.tryToPerform(#selector(StepInspectorPresenting.showStepInspector(_:)), with: sender)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, model.loaded, steps.indices.contains(table.selectedRow) else { return }
        model.editingResponse = response; model.selectedStepID = steps[table.selectedRow].id
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems(); guard model.loaded, steps.indices.contains(table.clickedRow) else { return }; let step = steps[table.clickedRow]
        menu.addItem(RulesMenuItem(step.enabled ? "停用" : "启用") { [weak self] in self?.modify(step.id, remove: false) })
        menu.addItem(RulesMenuItem("删除步骤") { [weak self] in self?.modify(step.id, remove: true) })
    }
    func canPerform(_ command: WorkspaceCommand) -> Bool {
        guard model.loaded, model.selection == .rules, !table.isHiddenOrHasHiddenAncestor, window?.firstResponder === table,
              steps.indices.contains(table.selectedRow),
              let workflow = model.workflow else { return false }
        let current = response ? workflow.responseSteps : workflow.requestSteps
        return [.delete, .toggleEnabled].contains(command) && current.contains { $0.id == steps[table.selectedRow].id }
    }
    func perform(_ command: WorkspaceCommand) {
        guard canPerform(command) else { return }
        modify(steps[table.selectedRow].id, remove: command == .delete)
        refresh()
    }
    private func modify(_ id: UUID, remove: Bool) {
        guard var workflow = model.workflow else { return }
        var items = response ? workflow.responseSteps : workflow.requestSteps
        if remove { items.removeAll { $0.id == id }; if model.selectedStepID == id { model.selectedStepID = nil } }
        else if let index = items.firstIndex(where: { $0.id == id }) { items[index].enabled.toggle() }
        if response { workflow.responseSteps = items } else { workflow.requestSteps = items }; model.updateWorkflow(workflow)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard model.loaded else { return nil }; let item = NSPasteboardItem(); item.setString(steps[row].id.uuidString, forType: Self.dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, model.loaded else { return [] }
        table.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard var workflow = model.workflow, let text = info.draggingPasteboard.string(forType: Self.dragType), let id = UUID(uuidString: text), let from = steps.firstIndex(where: { $0.id == id }) else { return false }
        var current = response ? workflow.responseSteps : workflow.requestSteps
        let moved = current.remove(at: from); current.insert(moved, at: min(max(0, row - (row > from ? 1 : 0)), current.count))
        if response { workflow.responseSteps = current } else { workflow.requestSteps = current }; model.updateWorkflow(workflow); return true
    }
}

/// Keeps the existing workflow-card content while NSTableView owns selection, keyboard and drag behavior.
@MainActor private final class RulesStepCell: NSTableCellView {
    private let card = NSBox()
    private let accent = NSBox()
    let number: Int
    private var selected: Bool?
    init(step: ModificationStep, number: Int) {
        self.number = number
        super.init(frame: .zero)
        card.identifier = .init("rules.stepCard")
        card.boxType = .custom; card.titlePosition = .noTitle
        card.borderWidth = 1; card.cornerRadius = 8; card.contentViewMargins = .zero
        card.wantsLayer = true; card.layer?.cornerRadius = card.cornerRadius; card.layer?.masksToBounds = true
        NativeUI.pin(card, to: self, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
        let badge = NSBox(); badge.identifier = .init("rules.stepNumber")
        badge.boxType = .custom; badge.titlePosition = .noTitle; badge.borderWidth = 0; badge.borderColor = .clear
        badge.fillColor = NSColor.labelColor.withAlphaComponent(0.045); badge.cornerRadius = 6
        badge.contentViewMargins = .zero
        let numberLabel = NativeUI.label(String(number)); numberLabel.alignment = .center
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        badge.contentView!.addSubview(numberLabel); numberLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 26), badge.heightAnchor.constraint(equalToConstant: 28),
            numberLabel.centerXAnchor.constraint(equalTo: badge.contentView!.centerXAnchor), numberLabel.centerYAnchor.constraint(equalTo: badge.contentView!.centerYAnchor)])
        let title = NativeUI.label(step.kind.title); title.toolTip = step.kind.title
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: step.kind.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = step.enabled ? .labelColor : .secondaryLabelColor
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
        let heading = NativeUI.stack([icon, title], vertical: false, spacing: 6)
        var summary = step.kind == .script ? (step.name.isEmpty ? "JavaScript" : step.name) : step.kind == .setStatus ? String(step.status) : (step.name.isEmpty ? (step.value.isEmpty ? "点击配置" : step.value) : step.name)
        if step.kind == .setHeader {
            summary = step.headerEntries.isEmpty ? "点击添加 Header" : step.headerEntries.map { $0.name.isEmpty ? "未命名 Header" : $0.name }.joined(separator: ", ")
        }
        if !step.name.isEmpty {
            if step.kind == .setQueryParameter { summary = "\(step.name) = \(step.value)" }
            if step.kind == .replaceURLString { summary = "\(step.name) → \(step.value.isEmpty ? "（空）" : step.value)" }
        }
        let detail = NativeUI.label(summary, size: 11, secondary: true); detail.toolTip = summary
        let texts = NativeUI.stack([heading, detail], spacing: 5)
        heading.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NativeUI.stack([badge, texts], vertical: false, spacing: 10)
        if !step.enabled {
            let pause = NSImageView(image: NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "已停用")!)
            pause.contentTintColor = .secondaryLabelColor; row.addArrangedSubview(pause)
        }
        NativeUI.pin(row, to: card.contentView!, insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
        accent.identifier = .init("rules.stepAccent")
        accent.boxType = .custom; accent.titlePosition = .noTitle; accent.borderWidth = 0; accent.borderColor = .clear
        accent.fillColor = .systemBlue; accent.cornerRadius = 2
        accent.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(accent)
        NSLayoutConstraint.activate([accent.leadingAnchor.constraint(equalTo: card.leadingAnchor), accent.widthAnchor.constraint(equalToConstant: 3),
            accent.topAnchor.constraint(equalTo: card.topAnchor), accent.bottomAnchor.constraint(equalTo: card.bottomAnchor)])
        setAccessibilityElement(true); setAccessibilityLabel("第 \(number) 步，\(step.kind.title)，\(summary)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        card.fillColor = selected ? NSColor.systemBlue.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.045)
        card.borderColor = selected ? NSColor.systemBlue.withAlphaComponent(0.55) : .clear
        accent.isHidden = !selected
        setAccessibilitySelected(selected)
    }
}
