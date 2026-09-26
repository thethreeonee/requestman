import AppKit
import RequestmanCore

@MainActor
final class RequestFilterControls: NSView {
    var onFilterChange: (CaptureRecordFilter) -> Void = { _ in }
    var toggleRecording: () -> Void = {}
    var clear: () -> Void = {}
    private var filter = CaptureRecordFilter()
    private var records: [CaptureRecord] = []
    private let pause = RequestFilterActionButton(symbol: "pause", label: "暂停记录")
    private let clearButton = RequestFilterActionButton(symbol: "trash", label: "清空")
    private let separator = NSBox()
    private let primary = NSSegmentedControl(labels: ["全部", "JSON", "文档", "CSS", "JS", "图片"], trackingMode: .selectOne, target: nil, action: nil)
    private let more = NSPopUpButton()
    private let compact = NSPopUpButton()
    private let filterButton = NSButton(title: "筛选", target: nil, action: nil)
    private var popover: NSPopover?
    private var panel: RequestFilterPanel?
    private let primaryTypes: [CaptureResourceType] = [.all, .json, .document, .css, .script, .image]
    private let extraTypes: [CaptureResourceType] = [.font, .media, .other]

    override init(frame: NSRect) {
        super.init(frame: frame)
        pause.handler = { [weak self] in self?.toggleRecording() }
        clearButton.handler = { [weak self] in self?.clear() }
        separator.boxType = .separator
        primary.target = self; primary.action = #selector(selectPrimary)
        for (index, type) in primaryTypes.enumerated() { primary.setLabel(type.rawValue, forSegment: index) }
        primary.setAccessibilityLabel("资源类型")
        more.addItems(withTitles: ["更多"] + extraTypes.map(\.rawValue))
        more.target = self; more.action = #selector(selectMore)
        compact.addItems(withTitles: CaptureResourceType.allCases.map(\.rawValue))
        compact.target = self; compact.action = #selector(selectCompact)
        compact.setAccessibilityLabel("资源类型")
        filterButton.bezelStyle = .rounded
        filterButton.target = self; filterButton.action = #selector(showFilters)
        filterButton.toolTip = "筛选项目、环境、结果、方法和请求 Header"
        for child in [pause, clearButton, separator, primary, more, compact, filterButton] { addSubview(child) }
        setAccessibilityLabel("请求日志筛选")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 48) }

    func update(filter: CaptureRecordFilter, records: [CaptureRecord], paused: Bool) {
        self.filter = filter; self.records = records
        pause.image = NSImage(systemSymbolName: paused ? "play" : "pause", accessibilityDescription: nil)
        pause.setAccessibilityLabel(paused ? "继续记录" : "暂停记录")
        pause.toolTip = paused ? "继续记录" : "暂停记录（代理继续工作）"
        clearButton.isEnabled = !records.isEmpty
        clearButton.toolTip = "清空全部请求日志"
        primary.selectedSegment = primaryTypes.firstIndex(of: filter.resource) ?? -1
        more.selectItem(at: extraTypes.firstIndex(of: filter.resource).map { $0 + 1 } ?? 0)
        compact.selectItem(at: CaptureResourceType.allCases.firstIndex(of: filter.resource) ?? 0)
        filterButton.title = filter.activeConditionCount == 0 ? "筛选 ⌄" : "筛选 \(filter.activeConditionCount) ⌄"
        panel?.update(filter: filter, records: records)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        pause.frame = NSRect(x: 12, y: 8, width: 32, height: 32)
        clearButton.frame = NSRect(x: 54, y: 8, width: 32, height: 32)
        separator.frame = NSRect(x: 96, y: 14, width: 1, height: 20)
        let filterWidth = max(64, filterButton.intrinsicContentSize.width)
        filterButton.frame = NSRect(x: bounds.width - 12 - filterWidth, y: (48 - filterButton.intrinsicContentSize.height) / 2,
                                    width: filterWidth, height: filterButton.intrinsicContentSize.height)
        let available = max(0, filterButton.frame.minX - 117)
        let primaryWidth = primary.intrinsicContentSize.width
        let moreWidth = more.intrinsicContentSize.width
        let expanded = available >= primaryWidth + moreWidth + 6
        primary.isHidden = !expanded; more.isHidden = !expanded; compact.isHidden = expanded
        for (control, x, width) in [(primary as NSControl, CGFloat(107), primaryWidth),
                                    (more, 113 + primaryWidth, moreWidth), (compact, 107, min(96, available))] {
            let height = control.intrinsicContentSize.height
            control.frame = NSRect(x: x, y: (48 - height) / 2, width: width, height: height)
        }
    }
    private func changeResource(_ resource: CaptureResourceType) {
        filter.resource = resource; onFilterChange(filter)
    }
    @objc private func selectPrimary() {
        guard primaryTypes.indices.contains(primary.selectedSegment) else { return }
        changeResource(primaryTypes[primary.selectedSegment])
    }
    @objc private func selectMore() {
        guard more.indexOfSelectedItem > 0 else { return }
        changeResource(extraTypes[more.indexOfSelectedItem - 1])
    }
    @objc private func selectCompact() { changeResource(CaptureResourceType.allCases[compact.indexOfSelectedItem]) }
    @objc private func showFilters() {
        if let popover, popover.isShown { popover.close(); return }
        let panel = RequestFilterPanel(filter: filter, records: records) { [weak self] in self?.onFilterChange($0) }
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = panel
        popover.contentSize = panel.preferredContentSize
        self.panel = panel; self.popover = popover
        popover.show(relativeTo: filterButton.bounds, of: filterButton, preferredEdge: .minY)
    }
}

@MainActor
final class RequestFilterPanel: NSViewController {
    private var filter: CaptureRecordFilter
    private var records: [CaptureRecord]
    private let onChange: (CaptureRecordFilter) -> Void
    private let projects = NSPopUpButton(), environments = NSPopUpButton(), outcomes = NSPopUpButton(), methods = NSPopUpButton()
    private let sources = NSPopUpButton(), combinations = NSPopUpButton()
    private let inverse = NSButton(checkboxWithTitle: "反向匹配", target: nil, action: nil)
    private let reset = NSButton(title: "重置", target: nil, action: nil)
    private let add = NSButton(title: "添加条件", target: nil, action: nil)
    private let rowsScroll = NSScrollView()
    private let rowsView = FlippedView()
    private var rows: [HeaderConditionRow] = []
    private var stack: NSStackView!
    private var rowsHeight: NSLayoutConstraint!

    init(filter: CaptureRecordFilter, records: [CaptureRecord], onChange: @escaping (CaptureRecordFilter) -> Void) {
        self.filter = filter; self.records = records; self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 560, height: 360)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        for control in [projects, environments, outcomes, methods, sources, combinations] {
            control.target = self; control.action = #selector(selectionChanged(_:))
        }
        let grid = NSGridView(views: [[NativeUI.label("项目"), projects, NativeUI.label("环境"), environments],
                                    [NativeUI.label("结果"), outcomes, NativeUI.label("方法"), methods]])
        grid.columnSpacing = 14; grid.rowSpacing = 12
        grid.column(at: 1).width = 190; grid.column(at: 3).width = 190
        rowsScroll.drawsBackground = false; rowsScroll.hasVerticalScroller = true; rowsScroll.autohidesScrollers = true
        rowsScroll.documentView = rowsView
        rowsScroll.translatesAutoresizingMaskIntoConstraints = false
        rowsHeight = rowsScroll.heightAnchor.constraint(equalToConstant: 0); rowsHeight.isActive = true
        inverse.target = self; inverse.action = #selector(invert)
        inverse.toolTip = "反向匹配全部当前条件；不可判断的 Header 值不会被纳入"
        reset.target = self; reset.action = #selector(resetFilter); reset.bezelStyle = .rounded
        add.target = self; add.action = #selector(addCondition); add.bezelStyle = .rounded
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil); add.imagePosition = .imageLeading
        let bottom = NativeUI.stack([inverse, NSView(), reset], vertical: false)
        stack = NativeUI.stack([NativeUI.label("筛选", weight: .semibold), grid, divider(),
            NativeUI.label("请求 Header", weight: .semibold), NativeUI.stack([sources, combinations], vertical: false),
            rowsScroll, add, divider(), bottom], spacing: 14)
        stack.alignment = .leading
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for child in [grid, rowsScroll, bottom] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refreshControls()
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        rowsView.frame = NSRect(x: 0, y: 0, width: rowsScroll.contentSize.width, height: CGFloat(rows.count) * 40 + 16)
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 8, y: 8 + CGFloat(index) * 40, width: max(0, rowsView.bounds.width - 16), height: 32) }
    }
    func update(filter: CaptureRecordFilter, records: [CaptureRecord]) {
        self.filter = filter; self.records = records
        if isViewLoaded { refreshControls() }
    }
    private func divider() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func options(_ control: NSPopUpButton, values: [String], selected: String) {
        if control.itemTitles != values { control.removeAllItems(); control.addItems(withTitles: values) }
        control.selectItem(withTitle: selected)
    }
    private func refreshControls() {
        options(projects, values: ["全部项目"] + Array(Set(records.map(\.project)).union(filter.project.isEmpty ? [] : [filter.project])).sorted(), selected: filter.project.isEmpty ? "全部项目" : filter.project)
        options(environments, values: ["全部环境"] + Array(Set(records.map(\.environment)).union(filter.environment.isEmpty ? [] : [filter.environment])).sorted(), selected: filter.environment.isEmpty ? "全部环境" : filter.environment)
        options(methods, values: ["全部方法"] + Array(Set(records.map(\.method)).union(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]).union(filter.method.isEmpty ? [] : [filter.method])).sorted(), selected: filter.method.isEmpty ? "全部方法" : filter.method)
        options(outcomes, values: ["全部结果"] + CaptureRecord.Outcome.allCases.map(\.rawValue), selected: filter.outcome?.rawValue ?? "全部结果")
        options(sources, values: CaptureHeaderSource.allCases.map(\.rawValue), selected: filter.headerSource.rawValue)
        options(combinations, values: CaptureHeaderCombination.allCases.map(\.rawValue), selected: filter.headerCombination.rawValue)
        inverse.state = filter.inverted ? .on : .off; reset.isEnabled = filter != CaptureRecordFilter()
        add.isEnabled = filter.headers.count < 16
        if rows.map(\.conditionID) != filter.headers.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = filter.headers.map { condition in
                HeaderConditionRow(condition: condition, onChange: { [weak self] condition in
                    guard let self, let index = self.filter.headers.firstIndex(where: { $0.id == condition.id }) else { return }
                    self.filter.headers[index] = condition; self.changed()
                }, remove: { [weak self] in self?.filter.headers.removeAll { $0.id == condition.id }; self?.changed() })
            }
            rows.forEach { rowsView.addSubview($0) }
        }
        let captured = records.flatMap { filter.headerSource == .original ? $0.requestHeaders : $0.sentHeaders }
        let names = Array(Set(captured.map { $0.name.lowercased() }).union(["content-type", "accept", "user-agent", "origin", "referer", "authorization", "cookie"])).sorted()
        for (row, condition) in zip(rows, filter.headers) { row.update(condition, suggestions: names) }
        rowsHeight.constant = rows.isEmpty ? 0 : min(240, CGFloat(rows.count) * 40 + 16)
        rowsScroll.isHidden = rows.isEmpty
        preferredContentSize = NSSize(width: 560, height: 310 + rowsHeight.constant)
        view.needsLayout = true
    }
    private func changed() { onChange(filter); refreshControls() }
    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        switch sender {
        case projects: filter.project = sender.indexOfSelectedItem == 0 ? "" : sender.titleOfSelectedItem ?? ""
        case environments: filter.environment = sender.indexOfSelectedItem == 0 ? "" : sender.titleOfSelectedItem ?? ""
        case methods: filter.method = sender.indexOfSelectedItem == 0 ? "" : sender.titleOfSelectedItem ?? ""
        case outcomes: filter.outcome = CaptureRecord.Outcome(rawValue: sender.titleOfSelectedItem ?? "")
        case sources: filter.headerSource = CaptureHeaderSource.allCases[sender.indexOfSelectedItem]
        case combinations: filter.headerCombination = CaptureHeaderCombination.allCases[sender.indexOfSelectedItem]
        default: break
        }
        changed()
    }
    @objc private func invert() { filter.inverted = inverse.state == .on; changed() }
    @objc private func resetFilter() { filter = CaptureRecordFilter(); changed() }
    @objc private func addCondition() { guard filter.headers.count < 16 else { return }; filter.headers.append(.init()); changed() }
}

@MainActor
private final class HeaderConditionRow: NSView, NSComboBoxDelegate, NSTextFieldDelegate {
    let conditionID: UUID
    private var condition: CaptureHeaderCondition
    private let onChange: (CaptureHeaderCondition) -> Void
    private let remove: () -> Void
    private let name = NSComboBox(), operation = NSPopUpButton(), value = NSTextField()
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    init(condition: CaptureHeaderCondition, onChange: @escaping (CaptureHeaderCondition) -> Void, remove: @escaping () -> Void) {
        conditionID = condition.id; self.condition = condition; self.onChange = onChange; self.remove = remove
        super.init(frame: .zero)
        name.placeholderString = "Header 名称"; name.setAccessibilityLabel("Header 名称"); name.completes = true
        name.numberOfVisibleItems = 8; name.delegate = self
        value.placeholderString = "值"; value.setAccessibilityLabel("Header 值"); value.bezelStyle = .roundedBezel; value.delegate = self
        operation.addItems(withTitles: CaptureHeaderOperator.allCases.map(\.rawValue)); operation.target = self; operation.action = #selector(selectOperation)
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)
        removeButton.imagePosition = .imageOnly; removeButton.target = self; removeButton.action = #selector(removeCondition(_:))
        removeButton.toolTip = "移除 Header 条件"; removeButton.setAccessibilityLabel("移除 Header 条件")
        if #available(macOS 26.0, *) { removeButton.bezelStyle = .glass; removeButton.borderShape = .circle }
        else { removeButton.bezelStyle = .circular }
        [name, operation, value, removeButton].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { nil }
    func update(_ condition: CaptureHeaderCondition, suggestions: [String]) {
        self.condition = condition
        if name.objectValues.compactMap({ $0 as? String }) != suggestions { name.removeAllItems(); name.addItems(withObjectValues: suggestions) }
        if name.stringValue != condition.name { name.stringValue = condition.name }
        if value.stringValue != condition.value { value.stringValue = condition.value }
        operation.selectItem(withTitle: condition.operation.rawValue); value.isEnabled = condition.operation.needsValue
    }
    override func layout() {
        super.layout()
        let controls: [(NSControl, CGFloat, CGFloat)] = [(name, 0, 160), (operation, 168, 82), (value, 258, max(0, bounds.width - 298)), (removeButton, bounds.width - 32, 32)]
        for (control, x, width) in controls {
            let height = control === removeButton ? 32 : control.intrinsicContentSize.height
            control.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSControl === name { condition.name = name.stringValue } else { condition.value = value.stringValue }
        onChange(condition)
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let selected = name.objectValueOfSelectedItem as? String else { return }; condition.name = selected; onChange(condition)
    }
    @objc private func selectOperation() { condition.operation = CaptureHeaderOperator.allCases[operation.indexOfSelectedItem]; onChange(condition) }
    @objc private func removeCondition(_ sender: NSButton) { remove() }
}

@MainActor
private final class RequestFilterActionButton: NSButton {
    var handler: () -> Void = {}
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageOnly
        setAccessibilityLabel(label); controlSize = .regular
        if #available(macOS 26.0, *) { bezelStyle = .glass; borderShape = .circle } else { bezelStyle = .circular }
        target = self; action = #selector(performAction(_:))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func performAction(_ sender: NSButton) { guard isEnabled else { return }; handler() }
}
