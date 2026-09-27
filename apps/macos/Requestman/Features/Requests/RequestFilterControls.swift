import AppKit
import QuartzCore
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
    private let primary = NSSegmentedControl(labels: CaptureResourceType.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let filterButton = RequestFilterActionButton(symbol: "line.3.horizontal.decrease", label: "筛选")
    private(set) var isExpanded = false
    private let toolbar = NSView()
    private let panelClip = FlippedView()
    private var revealedHeight: CGFloat = 0
    private var targetHeight: CGFloat = 0
    private var transition: Task<Void, Never>?
    private var geometryUpdateScheduled = false

    override var isFlipped: Bool { true }
    private var panel: RequestFilterPanel?
    private let primaryTypes = CaptureResourceType.allCases
    private var heightConstraint: NSLayoutConstraint!
    private var usesSecondRow = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        pause.handler = { [weak self] in self?.toggleRecording() }
        clearButton.handler = { [weak self] in self?.clear() }
        separator.boxType = .separator
        primary.target = self; primary.action = #selector(selectPrimary)
        for (index, type) in primaryTypes.enumerated() { primary.setLabel(type.rawValue, forSegment: index) }
        primary.setAccessibilityLabel("资源类型")
        primary.segmentStyle = .automatic
        primary.segmentDistribution = .fit
        primary.controlSize = .large
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        primary.font = font
        for (index, type) in primaryTypes.enumerated() {
            let labelWidth = (type.rawValue as NSString).size(withAttributes: [.font: font]).width
            primary.setWidth(ceil(labelWidth) + 16, forSegment: index)
        }
        if #available(macOS 26.0, *) {
            primary.controlSize = .extraLarge
            primary.borderShape = .capsule
        }
        if #available(macOS 27.0, *) { primary.role = .tabs }
        filterButton.handler = { [weak self] in self?.showFilters() }
        updateFilterButton()
        for child in [pause, clearButton, separator, primary, filterButton] { toolbar.addSubview(child) }
        addSubview(toolbar)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: toolbarHeight)
        heightConstraint.isActive = true
        panelClip.wantsLayer = true; panelClip.layer?.masksToBounds = true
        addSubview(panelClip); panelClip.isHidden = true
        setAccessibilityLabel("请求日志筛选")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    private var controlHeight: CGFloat { primary.intrinsicContentSize.height }
    var minimumContentWidth: CGFloat { primary.intrinsicContentSize.width + 20 }
    private var barHeight: CGFloat { usesSecondRow ? controlHeight * 2 + 24 : controlHeight + 16 }
    private var panelHeight: CGFloat {
        guard let panel else { return 0 }
        return min(panel.formHeight, max(0, (window?.contentView?.bounds.height ?? 720) * 0.45))
    }
    private var toolbarHeight: CGFloat { barHeight + revealedHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: toolbarHeight) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRowPlacement()
    }

    private func updateRowPlacement() {
        guard heightConstraint != nil, bounds.width > 0 else { return }
        let width = primary.intrinsicContentSize.width
        let nextUsesSecondRow = bounds.width < width + controlHeight * 3 + 73
        let rowChanged = usesSecondRow != nextUsesSecondRow
        usesSecondRow = nextUsesSecondRow
        let desiredHeight = isExpanded ? panelHeight : 0
        guard rowChanged || abs(targetHeight - desiredHeight) > 0.5 else { return }
        guard !geometryUpdateScheduled else { return }
        // Defer width-dependent sizing until the current parent layout has finished.
        geometryUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            geometryUpdateScheduled = false
            resizeForm(animated: false)
        }
    }

    func update(filter: CaptureRecordFilter, records: [CaptureRecord], paused: Bool) {
        self.filter = filter; self.records = records
        pause.image = NSImage(systemSymbolName: paused ? "play" : "pause", accessibilityDescription: nil)
        pause.setAccessibilityLabel(paused ? "继续记录" : "暂停记录")
        pause.toolTip = (paused ? "继续记录" : "暂停记录（代理继续工作）") + "（⌘⇧R）"
        clearButton.isEnabled = !records.isEmpty
        clearButton.toolTip = "清空全部请求日志（⌘K）"
        primary.selectedSegment = primaryTypes.firstIndex(of: filter.resource) ?? -1
        updateFilterButton()
        panel?.update(filter: filter, records: records)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        updateRowPlacement()
        let size = primary.intrinsicContentSize
        let height = size.height
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let actionY: CGFloat = usesSecondRow ? height + 16 : 8
        pause.frame = NSRect(x: 12, y: actionY, width: height, height: height)
        clearButton.frame = NSRect(x: 22 + height, y: actionY, width: height, height: height)
        separator.isHidden = usesSecondRow
        separator.frame = NSRect(x: 32 + height * 2, y: 8 + (height - 20) / 2, width: 1, height: 20)
        filterButton.frame = NSRect(x: bounds.width - 12 - height, y: actionY, width: height, height: height)
        let origin: CGFloat = usesSecondRow ? 10 : 43 + height * 2
        // Keep the native drawing scale so labels and the bezel retain their proportions.
        primary.frame = NSRect(origin: NSPoint(x: origin, y: 8), size: size)
        panelClip.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: revealedHeight)
        if let panel {
            // Keep the form at its full size; only its viewport reveals or clips it.
            panel.view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: panelHeight)
        }
    }
    private func changeResource(_ resource: CaptureResourceType) {
        filter.resource = resource; updateFilterButton(); onFilterChange(filter)
    }
    private func updateFilterButton() {
        let active = filter.hasCriteria
        let count = filter.activeConditionCount + (filter.search.isEmpty ? 0 : 1) + (filter.resource == .all ? 0 : 1)
        // Color the SF Symbol's disc, leaving the native glass bezel untouched.
        let symbol = active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
        // At 28 pt the circular symbol fits the 36 pt bezel and renders centered.
        let configuration = NSImage.SymbolConfiguration(pointSize: active ? 28 : 16, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: active ? [.white, .systemBlue] : [.labelColor]))
        filterButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        filterButton.setAccessibilityValue((isExpanded ? "已展开，" : "已收起，") + (active ? "\(count) 个筛选条件" : "无筛选条件"))
        filterButton.toolTip = (active ? "筛选（\(count) 个条件）" : "筛选状态码、URL、域名、请求方法、环境和请求 Header") + "（⌘⌥F）"
    }
    @objc private func selectPrimary() {
        guard primaryTypes.indices.contains(primary.selectedSegment) else { return }
        changeResource(primaryTypes[primary.selectedSegment])
    }
    @objc func showFilters() {
        window?.makeFirstResponder(nil)
        if panel == nil {
            let panel = RequestFilterPanel(filter: filter, records: records) { [weak self] value in
                guard let self else { return }
                filter = value
                updateFilterButton()
                onFilterChange(value)
            }
            self.panel = panel
            panelClip.addSubview(panel.view)
            panel.onHeightChange = { [weak self] in self?.resizeForm(animated: false) }
        }
        isExpanded.toggle()
        panelClip.isHidden = false
        updateFilterButton()
        resizeForm(animated: true)
    }
    private func resizeForm(animated: Bool) {
        let destination = isExpanded ? panelHeight : 0
        // Log refreshes must not interrupt an in-flight transition to the same height.
        if abs(targetHeight - destination) < 0.5, transition != nil { return }
        if transition == nil, abs(revealedHeight - destination) < 0.5,
           abs(heightConstraint.constant - toolbarHeight) < 0.5 { return }
        transition?.cancel()
        transition = nil
        targetHeight = destination
        let startHeight = revealedHeight
        guard animated, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(startHeight - destination) > 0.5 else {
            applyRevealedHeight(destination)
            return
        }
        // Animate only the reveal height. An implicit animation on the accessory's
        // ancestor also animates native toolbar geometry and scroll-edge insets.
        let startTime = CACurrentMediaTime()
        transition = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let progress = min(1, (CACurrentMediaTime() - startTime) / 0.2)
                let eased = progress * progress * (3 - 2 * progress)
                self?.applyRevealedHeight(startHeight + (destination - startHeight) * eased)
                if progress >= 1 {
                    self?.transition = nil
                    return
                }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
        }
    }

    private func applyRevealedHeight(_ height: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            revealedHeight = height
            panelClip.isHidden = height == 0
            heightConstraint.constant = toolbarHeight
            invalidateIntrinsicContentSize()
            needsLayout = true
            (window?.contentView ?? superview)?.layoutSubtreeIfNeeded()
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            transition?.cancel()
            transition = nil
            targetHeight = isExpanded ? panelHeight : 0
            applyRevealedHeight(targetHeight)
        }
    }
}

@MainActor
private final class RequestFilterActionButton: NSButton {
    var handler: () -> Void = {}
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageOnly
        setAccessibilityLabel(label); controlSize = .regular
        if #available(macOS 26.0, *) { bezelStyle = .glass; borderShape = .circle } else { bezelStyle = .circular }
        target = self; action = #selector(performAction(_:))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func performAction(_ sender: NSButton) { guard isEnabled else { return }; handler() }
}

@MainActor
final class RequestFilterPanel: NSViewController {
    private var filter: CaptureRecordFilter
    private var records: [CaptureRecord]
    private let onChange: (CaptureRecordFilter) -> Void
    var onHeightChange: () -> Void = {}
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let inverse = NSButton(checkboxWithTitle: "反向匹配", target: nil, action: nil)
    private lazy var reset = ActionButton(title: "重置") { [weak self] in
        guard let self else { return }
        filter = CaptureRecordFilter(); changed()
    }
    private var groupView: FilterGroupView!
    private var draft = CaptureFilterGroup()
    private let divider = NativeUI.separator()
    private var footer: NSStackView?
    var formHeight: CGFloat {
        guard let footer else { return 0 }
        return min(320, ceil(document.fittingSize.height + footer.fittingSize.height + divider.fittingSize.height))
    }

    init(filter: CaptureRecordFilter, records: [CaptureRecord], onChange: @escaping (CaptureRecordFilter) -> Void) {
        self.filter = filter; self.records = records; self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = FlippedView()
        groupView = FilterGroupView(group: filter.conditionGroup ?? draft, depth: 0) { [weak self] group in
            guard let self else { return }; filter.conditionGroup = group; changed()
        }
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        NativeUI.pin(groupView, to: document, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        inverse.target = self; inverse.action = #selector(invert)
        inverse.toolTip = "反向匹配搜索、资源类型和全部筛选条件；未知的 Header 不会因此纳入"
        let hint = NativeUI.label("URL 等多值字段：空格或逗号分隔，-值 排除", size: 11, secondary: true)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NativeUI.stack([inverse, hint, NSView(), reset], vertical: false, spacing: 12)
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        self.footer = footer
        let stack = NativeUI.stack([divider, scroll, footer], spacing: 0)
        NativeUI.pin(stack, to: view)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        refreshControls()
    }
    func update(filter: CaptureRecordFilter, records: [CaptureRecord]) {
        self.filter = filter; self.records = records
        if isViewLoaded { refreshControls() }
    }
    private func refreshControls() {
        groupView.update(filter.conditionGroup ?? draft, records: records)
        inverse.state = filter.inverted ? .on : .off
        reset.isEnabled = filter != CaptureRecordFilter()
        onHeightChange()
    }
    private func changed() { refreshControls(); onChange(filter) }
    @objc private func invert() { filter.inverted = inverse.state == .on; changed() }
}

@MainActor
private final class FilterGroupView: NSView {
    private var group: CaptureFilterGroup
    private let depth: Int
    private let onChange: (CaptureFilterGroup) -> Void
    private let combination = NSPopUpButton()
    private let children = NativeUI.stack([], spacing: 6)
    private var rows: [FilterConditionRow] = []
    private var subgroups: [FilterGroupView] = []
    private var records: [CaptureRecord] = []
    private lazy var addCondition = ActionButton(title: "添加条件") { [weak self] in
        guard let self else { return }; group.conditions.append(.init()); changed()
    }
    private lazy var addGroup = ActionButton(title: "添加条件组") { [weak self] in
        guard let self else { return }; group.groups.append(.init(conditions: [.init()])); changed()
    }
    init(group: CaptureFilterGroup, depth: Int, onChange: @escaping (CaptureFilterGroup) -> Void) {
        self.group = group; self.depth = depth; self.onChange = onChange
        super.init(frame: .zero)
        combination.addItems(withTitles: ["全部满足（和）", "任一满足（或）"])
        combination.target = self; combination.action = #selector(selectCombination)
        combination.setAccessibilityLabel(depth == 0 ? "筛选组合" : "条件组组合")
        let header = NativeUI.stack([NativeUI.label(depth == 0 ? "筛选条件" : "条件组", weight: .semibold),
                                     combination, NSView(), addCondition, addGroup], vertical: false, spacing: 8)
        // Keep nesting bounded so controls remain usable at the minimum pane width.
        addGroup.isHidden = depth >= 2
        let stack = NativeUI.stack([header, children], spacing: 6)
        NativeUI.pin(stack, to: self)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        children.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        update(group, records: [])
    }
    required init?(coder: NSCoder) { nil }
    func update(_ group: CaptureFilterGroup, records: [CaptureRecord]) {
        self.group = group; self.records = records
        combination.selectItem(at: group.combination == .all ? 0 : 1)
        if rows.map(\.conditionID) != group.conditions.map(\.id) || subgroups.map({ $0.group.id }) != group.groups.map(\.id) {
            children.arrangedSubviews.forEach { children.removeArrangedSubview($0); $0.removeFromSuperview() }
            rows = group.conditions.map { condition in
                FilterConditionRow(condition: condition, onChange: { [weak self] value in
                    guard let self, let index = self.group.conditions.firstIndex(where: { $0.id == value.id }) else { return }
                    self.group.conditions[index] = value; changed()
                }, remove: { [weak self] in
                    guard let self else { return }; self.group.conditions.removeAll { $0.id == condition.id }; changed()
                })
            }
            subgroups = group.groups.map { child in
                FilterGroupView(group: child, depth: depth + 1) { [weak self] value in
                    guard let self, let index = self.group.groups.firstIndex(where: { $0.id == value.id }) else { return }
                    self.group.groups[index] = value; changed()
                }
            }
            for row in rows { append(row) }
            for subgroup in subgroups {
                let remove = filterRemoveButton(label: "移除条件组") { [weak self, weak subgroup] in
                    guard let self, let subgroup else { return }
                    self.group.groups.removeAll { $0.id == subgroup.group.id }; changed()
                }
                let content = NativeUI.stack([subgroup, remove], vertical: false, spacing: 6)
                content.alignment = .top
                let box = NSBox(); box.titlePosition = .noTitle; box.boxType = .primary
                box.contentViewMargins = .zero
                NativeUI.pin(content, to: box.contentView!, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 8))
                append(box)
            }
        }
        for (row, condition) in zip(rows, group.conditions) { row.update(condition, records: records) }
        for (view, child) in zip(subgroups, group.groups) { view.update(child, records: records) }
        children.isHidden = rows.isEmpty && subgroups.isEmpty
    }
    private func append(_ view: NSView) {
        children.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: children.widthAnchor).isActive = true
    }
    private func changed() { update(group, records: records); onChange(group) }
    @objc private func selectCombination() { group.combination = combination.indexOfSelectedItem == 0 ? .all : .any; changed() }
}

@MainActor
private func filterRemoveButton(label: String, action: @escaping () -> Void) -> ActionButton {
    let button = ActionButton(title: "", action: action)
    button.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil); button.imagePosition = .imageOnly
    button.setAccessibilityLabel(label); button.toolTip = label
    if #available(macOS 26.0, *) { button.bezelStyle = .glass; button.borderShape = .circle }
    else { button.bezelStyle = .circular }
    button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return button
}

@MainActor
private final class FilterConditionRow: NSView, NSComboBoxDelegate {
    let conditionID: UUID
    private var condition: CaptureFilterCondition
    private let onChange: (CaptureFilterCondition) -> Void
    private let field = NSPopUpButton(), operation = NSPopUpButton(), source = NSPopUpButton()
    private let name = NSComboBox(), value = NSComboBox()
    private var headerRow: NSStackView!
    private var records: [CaptureRecord] = []
    init(condition: CaptureFilterCondition, onChange: @escaping (CaptureFilterCondition) -> Void, remove: @escaping () -> Void) {
        self.condition = condition; conditionID = condition.id; self.onChange = onChange
        super.init(frame: .zero)
        field.addItems(withTitles: CaptureFilterField.allCases.map(\.rawValue))
        field.target = self; field.action = #selector(selectField); field.setAccessibilityLabel("筛选字段")
        source.addItems(withTitles: CaptureHeaderSource.allCases.map(\.rawValue))
        source.target = self; source.action = #selector(selectSource); source.setAccessibilityLabel("Header 来源")
        operation.target = self; operation.action = #selector(selectOperation); operation.setAccessibilityLabel("匹配方式")
        name.placeholderString = "Header 名称"; name.setAccessibilityLabel("Header 名称")
        for control in [name, value] {
            control.delegate = self; control.numberOfVisibleItems = 8
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        name.completes = true
        field.widthAnchor.constraint(equalToConstant: 112).isActive = true
        operation.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let row = NativeUI.stack([field, operation, value, filterRemoveButton(label: "移除条件", action: remove)], vertical: false, spacing: 8)
        headerRow = NativeUI.stack([source, name], vertical: false, spacing: 8)
        source.widthAnchor.constraint(equalToConstant: 148).isActive = true
        let stack = NativeUI.stack([row, headerRow], spacing: 4)
        NativeUI.pin(stack, to: self, insets: NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0))
        for child in [row, headerRow!] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        update(condition, records: [])
    }
    required init?(coder: NSCoder) { nil }
    func update(_ condition: CaptureFilterCondition, records: [CaptureRecord]) {
        self.condition = condition; self.records = records
        field.selectItem(withTitle: condition.field.rawValue)
        let operations = condition.field.operations.map { item in
            condition.field == .active ? (item == .exists ? "是" : "否") : item.rawValue
        }
        if operation.itemTitles != operations { operation.removeAllItems(); operation.addItems(withTitles: operations) }
        operation.selectItem(at: condition.field.operations.firstIndex(of: condition.operation) ?? 0)
        source.selectItem(withTitle: condition.headerSource.rawValue)
        headerRow.isHidden = condition.field != .header
        value.isEnabled = condition.operation.needsValue
        value.setAccessibilityLabel(condition.field == .header ? "Header 值" : condition.field.rawValue)
        value.placeholderString = condition.field.supportsMultipleValues ? "多个值，-值 排除" : "输入或选择\(condition.field.rawValue)"
        value.toolTip = condition.field == .domain ? "原始 URL 域名精确匹配，不自动包含子域名" :
            (condition.field == .header ? "完整文本匹配，保留空格、逗号和大小写" : value.placeholderString)
        var suggestions: [String] = []
        switch condition.field {
        case .domain: suggestions = records.compactMap { URL(string: $0.url)?.host }
        case .method: suggestions = records.map(\.method) + ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
        case .status: suggestions = records.compactMap(\.status).map(String.init) + ["200", "201", "204", "301", "302", "304", "400", "401", "403", "404", "429", "500", "502", "503"]
        case .project: suggestions = records.map(\.project)
        case .workflow: suggestions = records.map(\.workflow)
        case .environment: suggestions = records.map(\.environment)
        case .outcome: suggestions = CaptureRecord.Outcome.allCases.map(\.rawValue)
        default: break
        }
        setSuggestions(value, suggestions, text: condition.value)
        if condition.field == .header {
            let headers = records.flatMap { condition.headerSource == .original ? $0.requestHeaders : $0.sentHeaders }
            setSuggestions(name, headers.map { $0.name.lowercased() } + ["content-type", "accept", "user-agent", "authorization", "cookie", "origin", "referer"], text: condition.headerName)
        }
    }
    private func setSuggestions(_ control: NSComboBox, _ values: [String], text: String) {
        let suggestions = Array(Set(values.filter { !$0.isEmpty })).sorted()
        if control.objectValues.compactMap({ $0 as? String }) != suggestions {
            control.removeAllItems(); control.addItems(withObjectValues: suggestions)
        }
        if control.stringValue != text { control.stringValue = text }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let control = notification.object as? NSComboBox else { return }
        if control === name { condition.headerName = name.stringValue } else { condition.value = value.stringValue }
        onChange(condition)
    }
    func controlTextDidEndEditing(_ notification: Notification) { controlTextDidChange(notification) }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let control = notification.object as? NSComboBox, let selected = control.objectValueOfSelectedItem as? String else { return }
        if control === name { condition.headerName = selected } else { condition.value = selected }
        onChange(condition)
    }
    @objc private func selectField() {
        condition.field = CaptureFilterField.allCases[field.indexOfSelectedItem]
        condition.operation = condition.field.operations[0]; condition.value = ""
        onChange(condition)
    }
    @objc private func selectOperation() {
        condition.operation = condition.field.operations[operation.indexOfSelectedItem]; onChange(condition)
    }
    @objc private func selectSource() { condition.headerSource = CaptureHeaderSource.allCases[source.indexOfSelectedItem]; onChange(condition) }
}
