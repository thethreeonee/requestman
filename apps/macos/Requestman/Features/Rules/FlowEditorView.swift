import AppKit
import RequestmanCore

@MainActor final class FlowEditorViewController: ObservedViewController {
    let model: WorkspaceModel
    private lazy var name = WorkflowNameTextField(placeholder: "请求修改名称") { [weak self] value in self?.modify { $0.name = value } }
    private lazy var enabled = RulesSwitch { [weak self] value in self?.modify { $0.enabled = value } }
    private let enabledLabel = NativeUI.label("已启用")
    private lazy var matching = WorkflowMatchingView(model: model)
    private lazy var requestLane = RulesStepLane(model: model, response: false)
    private lazy var responseLane = RulesStepLane(model: model, response: true)
    private let footerHost: NSView?
    init(model: WorkspaceModel, footerHost: NSView? = nil) {
        self.model = model; self.footerHost = footerHost; super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        name.bezelStyle = .roundedBezel; name.controlSize = .large
        name.font = .systemFont(ofSize: 22, weight: .bold)
        name.appearance = nil; name.textColor = .labelColor
        name.backgroundColor = .textBackgroundColor
        name.isBezeled = false; name.drawsBackground = false
        name.isEditable = false; name.isSelectable = false
        name.cell?.usesSingleLineMode = true; name.cell?.wraps = false; name.cell?.isScrollable = true
        let nameLayout = WorkflowNameLayout(field: name)
        let nameWidth = nameLayout.widthAnchor.constraint(equalToConstant: 450)
        nameWidth.priority = .init(249)
        NSLayoutConstraint.activate([nameWidth, nameLayout.widthAnchor.constraint(lessThanOrEqualToConstant: 450),
                                     nameLayout.heightAnchor.constraint(equalToConstant: 32)])
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        enabledLabel.identifier = .init("rules.enabledLabel")
        enabled.identifier = .init("rules.enabled")
        enabled.setAccessibilityLabel("启用请求修改")
        let title = NativeUI.stack([nameLayout, titleSpacer, enabledLabel, enabled], vertical: false)
        let lanes = NativeUI.stack([requestLane, responseLane], vertical: false, spacing: 20)
        lanes.alignment = .top; lanes.distribution = .fillEqually
        let preview = ActionButton(title: "预览流程") { [weak self] in
            guard let self, let workflow = model.workflow else { return }
            presentAsSheet(WorkflowPreviewViewController(workflow: workflow, environment: model.document.environment))
        }
        MatchingControls.glass(preview)
        preview.controlSize = .large
        preview.identifier = .init("rules.previewFlow")
        preview.image = NSImage(systemSymbolName: "play", accessibilityDescription: nil); preview.imagePosition = .imageLeading
        let footer = NativeUI.stack([preview, MatchingControls.spacer()], vertical: false)
        let stack = NativeUI.stack([title, matching, lanes], spacing: 22)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.identifier = .init("rules.editorScroll")
        let document = FlippedView(); scroll.documentView = document
        footer.heightAnchor.constraint(equalToConstant: 36).isActive = true
        if let footerHost {
            // AppKit insets the document while allowing it to scroll behind both bars.
            NativeUI.pin(scroll, to: view)
            NativeUI.pin(footer, to: footerHost, insets: NSEdgeInsets(top: 16, left: 24, bottom: 8, right: 24))
        } else {
            for child in [scroll, footer] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: view.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
                footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
            ])
        }
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        NativeUI.pin(stack, to: document, insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24))
        for wide in [title, matching, lanes] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        lanes.setContentHuggingPriority(.defaultLow, for: .vertical)
        lanes.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    func focusName() { name.beginRenaming() }
    func canPerform(_ command: WorkspaceCommand) -> Bool {
        requestLane.canPerform(command) || responseLane.canPerform(command)
    }
    func perform(_ command: WorkspaceCommand) {
        if requestLane.canPerform(command) { requestLane.perform(command) }
        else { responseLane.perform(command) }
    }
    override func refresh() {
        guard let workflow = model.workflow else { return }
        if name.stringValue != workflow.name { name.stringValue = workflow.name }
        enabledLabel.stringValue = workflow.enabled ? "已启用" : "已关闭"
        enabled.state = workflow.enabled ? .on : .off
        matching.refresh()
        requestLane.refresh(); responseLane.refresh()
        for control in [name, enabled] as [NSControl] { control.isEnabled = model.loaded }
    }
    private func modify(_ update: (inout RequestWorkflow) -> Void) { guard model.loaded, var workflow = model.workflow else { return }; update(&workflow); model.updateWorkflow(workflow) }
}

/// Keeps the title's text aligned with the form while AppKit adds its editing bezel outside it.
@MainActor private final class WorkflowNameTextField: ActionTextField {
    private var titleInsets = NSEdgeInsetsZero
    private var isRenaming = false

    override class var cellClass: AnyClass? {
        get { WorkflowNameTextFieldCell.self }
        set {}
    }

    var contentInsets: NSEdgeInsets {
        var insets = isBezeled ? titleInsets : super.alignmentRectInsets
        if isBezeled, let cell = cell as? WorkflowNameTextFieldCell {
            // Measure at the editing size, not the smaller title frame during focus changes.
            let editingBounds = NSRect(x: 0, y: 0, width: 450, height: 40)
            let content = cell.bezelDrawingRect(forBounds: editingBounds)
            insets.top += editingBounds.maxY - content.maxY
            insets.left += content.minX
            insets.bottom += content.minY
            insets.right += editingBounds.maxX - content.maxX
        }
        return insets
    }

    override var acceptsFirstResponder: Bool { isRenaming && super.acceptsFirstResponder }

    func beginRenaming() {
        guard isEnabled, window != nil else { return }
        setEditingAppearance(true)
        selectText(nil)
    }

    override func becomeFirstResponder() -> Bool {
        guard isRenaming, isEnabled else { return false }
        setEditingAppearance(true)
        let accepted = super.becomeFirstResponder()
        if !accepted { setEditingAppearance(false) }
        return accepted
    }

    override func selectText(_ sender: Any?) {
        guard isRenaming, isEnabled else { return }
        setEditingAppearance(true)
        super.selectText(sender)
        if currentEditor() == nil { setEditingAppearance(false) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isRenaming else {
            if event.clickCount == 2 { beginRenaming() }
            return
        }
        setEditingAppearance(true)
        super.mouseDown(with: event)
        if currentEditor() == nil { setEditingAppearance(false) }
    }

    override func controlTextDidEndEditing(_ notification: Notification) {
        super.controlTextDidEndEditing(notification)
        setEditingAppearance(false)
    }

    private func setEditingAppearance(_ editing: Bool) {
        isRenaming = editing
        isEditable = editing
        isSelectable = editing
        guard isBezeled != editing else { return }
        if editing { titleInsets = super.alignmentRectInsets }
        isBezeled = editing
        drawsBackground = editing
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
        needsDisplay = true
    }
}

/// Centers the native single-line text area without changing AppKit's bezel or focus ring.
@MainActor private final class WorkflowNameTextFieldCell: NSTextFieldCell {
    func bezelDrawingRect(forBounds bounds: NSRect) -> NSRect {
        super.drawingRect(forBounds: bounds)
    }

    override func drawingRect(forBounds bounds: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: bounds)
        guard let font else { return rect }
        let lineHeight = min(rect.height, NSLayoutManager().defaultLineHeight(for: font))
        rect.origin.y += (rect.height - lineHeight) / 2
        rect.size.height = lineHeight
        return rect
    }
}

/// A stable text slot keeps native bezel metrics from moving the title or the rows below it.
@MainActor private final class WorkflowNameLayout: NSView {
    private let field: WorkflowNameTextField

    init(field: WorkflowNameTextField) {
        self.field = field
        super.init(frame: .zero)
        clipsToBounds = false
        addSubview(field)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let insets = field.contentInsets
        field.frame = NSRect(x: -insets.left, y: -insets.bottom,
                             width: bounds.width + insets.left + insets.right,
                             height: bounds.height + insets.top + insets.bottom)
    }
}

/// Only changes native control layout; fields retain their identity and editing state.
@MainActor private final class RulesStepLane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let model: WorkspaceModel
    let response: Bool
    let table = RulesStepsTableView()
    private var steps: [ModificationStep] = []
    // Accessibility may request offscreen rows repeatedly. Keep the same cell for
    // unchanged steps instead of rebuilding its NSBox view hierarchy each time.
    private var stepCells: [UUID: (step: ModificationStep, cell: RulesStepCell)] = [:]
    private var updating = false
    private var tableHeight: NSLayoutConstraint!
    private var headingRow: NSStackView!
    private lazy var addButton: ActionButton = ActionButton(title: "添加步骤") { [weak self] in
        guard let self, model.loaded else { return }
        addMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.minY - 4), in: addButton)
    }
    private let addMenu = NSMenu()
    private static let dragType = NSPasteboard.PasteboardType("app.requestman.rule-step")
    init(model: WorkspaceModel, response: Bool) {
        self.model = model; self.response = response; super.init(frame: .zero)
        let headingTitle = NativeUI.label(response ? "响应阶段" : "请求阶段", size: 16, weight: .semibold)
        let direction = NSImageView(image: NSImage(systemSymbolName: response ? "arrow.left" : "arrow.right", accessibilityDescription: nil)!)
        direction.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        direction.contentTintColor = response ? .systemGreen : .systemBlue
        direction.setAccessibilityElement(false)
        direction.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let heading = NativeUI.stack([direction, headingTitle], vertical: false, spacing: 6)
        let subtitle = NativeUI.label(response ? "服务器 → 客户端" : "客户端 → 服务器", size: 11, secondary: true)
        let column = NSTableColumn(identifier: .init("step")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 64; table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .fullWidth; table.selectionHighlightStyle = .regular; table.backgroundColor = .clear; table.dataSource = self; table.delegate = self
        table.allowsEmptySelection = true; table.setAccessibilityLabel(response ? "响应步骤" : "请求步骤")
        table.target = self; table.action = #selector(activateStep(_:))
        table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        addButton.identifier = .init("rules.addStep")
        MatchingControls.glass(addButton)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.menu = addMenu; addMenu.autoenablesItems = false
        addButton.setAccessibilityLabel(response ? "添加响应步骤" : "添加请求步骤")
        for kind in ModificationKind.allCases where kind != .removeHeader && kind.supports(response: response) {
            let item = RulesMenuItem(kind.title, symbol: kind.symbolName) { [weak self] in
                guard let self, self.model.loaded else { return }; self.model.addStep(kind, response: self.response)
            }
            // macOS 27 hides menu images by default, even when an image is assigned.
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            addMenu.addItem(item)
        }
        headingRow = NativeUI.stack([heading, MatchingControls.spacer(), addButton], vertical: false, spacing: 8)
        headingRow.identifier = .init("rules.laneHeading")
        let separator = NativeUI.separator(); separator.identifier = .init("rules.laneSeparator")
        let headingContents = NativeUI.stack([headingRow, subtitle], spacing: 10)
        for child in headingContents.arrangedSubviews { child.widthAnchor.constraint(equalTo: headingContents.widthAnchor).isActive = true }
        let contents = RulesStepsListView(table: table, heading: headingContents, separator: separator)
        tableHeight = contents.heightAnchor.constraint(equalTo: contents.header.heightAnchor, constant: 64 + RulesStepsListView.topSpacing)
        tableHeight.isActive = true
        let box = NSBox(); box.identifier = .init("rules.laneBorder")
        box.titlePosition = .noTitle; box.contentViewMargins = .zero
        box.boxType = .custom; box.borderWidth = 1; box.borderColor = .separatorColor
        box.fillColor = .clear; box.cornerRadius = 8
        box.contentView = NSView()
        NativeUI.pin(box, to: self)
        NativeUI.pin(box.contentView!, to: box)
        // The header background meets the 1 pt border; content padding belongs inside it.
        NativeUI.pin(contents, to: box.contentView!, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        let compact = bounds.width < 240
        let orientation: NSUserInterfaceLayoutOrientation = compact ? .vertical : .horizontal
        if headingRow.orientation != orientation {
            headingRow.orientation = orientation
            headingRow.alignment = compact ? .leading : .centerY
            headingRow.arrangedSubviews[1].isHidden = compact
        }
        super.layout()
    }
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
        tableHeight.constant = min(CGFloat(rowCount) * 64, 400) + RulesStepsListView.topSpacing
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
            cell = RulesStepCell(step: step, number: row + 1, response: response)
            stepCells[step.id] = (step, cell)
        }
        cell.setSelected(model.editingResponse == response && steps[row].id == model.selectedStepID)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RulesStepRowView()
    }
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView as? RulesStepRowView)?.setHovered(false, animated: false)
    }
    @objc private func activateStep(_ sender: NSTableView) {
        guard !updating, model.loaded, steps.indices.contains(sender.selectedRow) else { return }
        model.editingResponse = response; model.selectedStepID = steps[sender.selectedRow].id
        // Start in this table's responder chain so the request stays in its workspace window.
        let action = table.consumeSelectionReactivation()
            ? #selector(StepInspectorPresenting.toggleStepInspector(_:))
            : #selector(StepInspectorPresenting.showStepInspector(_:))
        _ = sender.tryToPerform(action, with: sender)
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
        guard model.loaded, !table.isHiddenOrHasHiddenAncestor, window?.firstResponder === table,
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
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        table.cancelSelectionReactivation()
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

/// Steps scroll underneath the fixed phase heading and its native header material.
@MainActor private final class RulesStepsListView: NSView {
    static let topSpacing: CGFloat = 10
    let header = RulesStepsHeaderView()
    private let scroll = NSScrollView()
    private var headerInset: CGFloat = 0

    init(table: NSTableView, heading: NSView, separator: NSView) {
        super.init(frame: .zero)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // Preserve the table's original 4 pt distance from the outer box.
        NativeUI.pin(scroll, to: self, insets: NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 3))

        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .followsWindowActiveState
        header.scrollView = scroll
        // Clip only the top corners to the inside of the existing 8 pt box border.
        header.wantsLayer = true
        header.layer?.cornerRadius = 7
        header.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        header.layer?.masksToBounds = true
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        heading.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(heading)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            heading.topAnchor.constraint(equalTo: header.topAnchor, constant: 11),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 11),
            heading.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -11),
            separator.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.bottomAnchor.constraint(equalTo: separator.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // The material ends at the separator; the clear gap belongs to the list inset.
        let height = header.frame.height + Self.topSpacing
        guard height != headerInset else { return }
        // Keep the same visible step when the narrow layout changes the heading height.
        let offset = scroll.contentView.bounds.origin.y + headerInset
        headerInset = height
        scroll.contentInsets = NSEdgeInsets(top: height, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: height, left: 0, bottom: 0, right: 0)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: offset - height))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

}

@MainActor private final class RulesStepsHeaderView: NSVisualEffectView {
    weak var scrollView: NSScrollView?

    override func scrollWheel(with event: NSEvent) {
        if let scrollView { scrollView.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

/// Remove AppKit's extra cell inset so the lane controls its content alignment explicitly.
@MainActor private final class RulesStepsTableView: NSTableView {
    private var reactivatedRow: Int?

    override func mouseDown(with event: NSEvent) {
        // AppKit changes selection before sending the action, so capture it first.
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        reactivatedRow = clickedRow >= 0 && isRowSelected(clickedRow) ? clickedRow : nil
        super.mouseDown(with: event)
    }

    func consumeSelectionReactivation() -> Bool {
        defer { cancelSelectionReactivation() }
        return reactivatedRow != nil && reactivatedRow == selectedRow
    }

    func cancelSelectionReactivation() { reactivatedRow = nil }

    override func keyDown(with event: NSEvent) {
        cancelSelectionReactivation()
        super.keyDown(with: event)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.size.width += frame.minX
        frame.origin.x = 0
        return frame
    }
}

/// The table retains native selection and input behavior with the requested blue selection treatment.
@MainActor private final class RulesStepRowView: HoverTableRowView {
    override var hoverLayerPrefix: String { "step" }
    override var hoverBackgroundRect: NSRect { bounds.insetBy(dx: 2, dy: 3) }
    override var hoverCornerRadius: CGFloat { 8 }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        // The lane has 12 pt content insets and the table extends 8 pt on both sides:
        // a 2 pt drawing inset puts the border halfway to the aligned number badge.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 8, yRadius: 8)
        NSColor.systemBlue.withAlphaComponent(0.12).setFill(); path.fill()
        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}

@MainActor private final class RulesStepCell: NSTableCellView {
    let number: Int
    init(step: ModificationStep, number: Int, response: Bool) {
        self.number = number
        super.init(frame: .zero)
        let numberLabel = NativeUI.label(String(number), secondary: true)
        numberLabel.identifier = .init("rules.stepNumber")
        numberLabel.alignment = .center
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let numberColor: NSColor = response ? .systemGreen : .systemBlue
        numberLabel.textColor = numberColor
        let badge = NSBox(); badge.identifier = .init("rules.stepBadge")
        badge.boxType = .custom; badge.titlePosition = .noTitle; badge.borderWidth = 0
        badge.cornerRadius = 7; badge.fillColor = numberColor.withAlphaComponent(0.12)
        badge.contentViewMargins = .zero; badge.contentView = NSView()
        badge.contentView!.addSubview(numberLabel); numberLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: max(28, ceil(numberLabel.intrinsicContentSize.width) + 12)),
                                     badge.heightAnchor.constraint(equalToConstant: 28),
                                     numberLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                                     numberLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor)])
        let title = NativeUI.label(step.kind.title); title.toolTip = step.kind.title
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: step.kind.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = step.enabled ? .labelColor : .secondaryLabelColor
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
        let heading = NativeUI.stack([icon, title], vertical: false, spacing: 6)
        var summary = step.kind == .script ? (step.name.isEmpty ? "JavaScript" : step.name) : step.kind == .setStatus ? String(step.status) : (step.name.isEmpty ? (step.value.isEmpty ? "点击配置" : step.value) : step.name)
        if [.setHeader, .removeHeader].contains(step.kind) {
            summary = step.headerEntries.isEmpty ? "点击添加 Header" : step.headerEntries.map { $0.name.isEmpty ? "未命名 Header" : $0.name }.joined(separator: ", ")
        }
        if step.kind == .modifyJSON {
            summary = step.jsonEntries.isEmpty ? "点击添加 JSON 修改" : step.jsonEntries.map { $0.path.isEmpty ? "未配置路径" : $0.path }.joined(separator: ", ")
        }
        if !step.name.isEmpty {
            if step.kind == .setQueryParameter { summary = "\(step.name) = \(step.value)" }
        }
        if step.kind == .replaceURLString {
            summary = step.urlReplacementEntries.isEmpty ? "点击添加替换配置" : step.urlReplacementEntries.map {
                "\($0.search.isEmpty ? "未配置查找字符串" : $0.search) → \($0.replacement.isEmpty ? "（空）" : $0.replacement)"
            }.joined(separator: ", ")
        }
        if step.kind == .delay { summary = "等待 \(step.value) ms" }
        let detail = NativeUI.label(summary, size: 11, secondary: true); detail.toolTip = summary
        let texts = NativeUI.stack([heading, detail], spacing: 5)
        heading.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NativeUI.stack([badge, texts], vertical: false, spacing: 10)
        texts.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        detail.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        if !step.enabled {
            let pause = NSImageView(image: NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "已停用")!)
            pause.identifier = .init("rules.stepPaused")
            pause.symbolConfiguration = .init(pointSize: 20, weight: .regular)
            NSLayoutConstraint.activate([pause.widthAnchor.constraint(equalToConstant: 24), pause.heightAnchor.constraint(equalToConstant: 24)])
            pause.contentTintColor = .secondaryLabelColor; row.addArrangedSubview(pause)
            pause.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        } else {
            texts.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        }
        NativeUI.pin(row, to: self, insets: NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 12))
        setAccessibilityElement(true); setAccessibilityLabel("第 \(number) 步，\(step.kind.title)，\(summary)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSelected(_ selected: Bool) {
        setAccessibilitySelected(selected)
    }
}
