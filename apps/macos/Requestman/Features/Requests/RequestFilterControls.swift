import AppKit
import QuartzCore
import RequestmanCore

@MainActor
final class RequestFilterControls: NSView {
    var onFilterChange: (CaptureRecordFilter) -> Void = { _ in }
    var onSaveFilterChange: (Bool) -> Void = { _ in }
    var toggleRecording: () -> Void = {}
    var clear: () -> Void = {}
    var showDisplayOptions: (NSView) -> Void = { _ in }
    private var filter = CaptureRecordFilter()
    private let pause = RequestFilterActionButton(symbol: "pause", label: "暂停记录")
    private let clearButton = RequestFilterActionButton(symbol: "trash", label: "清空")
    private let separator = NSBox()
    private let primary = NSSegmentedControl(labels: CaptureResourceType.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let displayButton = RequestFilterActionButton(symbol: "gauge.with.dots.needle.67percent", label: "显示选项")
    private var customColumnCount = -1
    var isExpanded: Bool { formAccessory.isExpanded }
    private let toolbar = NSView()
    private let formAccessory = RequestFilterFormAccessory()
    private var geometryUpdateScheduled = false

    override var isFlipped: Bool { true }
    private let primaryTypes = CaptureResourceType.allCases
    private var heightConstraint: NSLayoutConstraint!
    private var usesSecondRow = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        formAccessory.onFilterChange = { [weak self] value in
            guard let self else { return }
            filter = value; onFilterChange(value)
        }
        formAccessory.onSaveFilterChange = { [weak self] in self?.onSaveFilterChange($0) }
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
        displayButton.toolTip = "显示选项"
        displayButton.handler = { [weak self] in
            guard let self else { return }; showDisplayOptions(displayButton)
        }
        for child in [pause, clearButton, separator, primary, displayButton] { toolbar.addSubview(child) }
        addSubview(toolbar)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: barHeight)
        heightConstraint.isActive = true
        setAccessibilityLabel("请求日志筛选")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    private var controlHeight: CGFloat { primary.intrinsicContentSize.height }
    var minimumContentWidth: CGFloat { primary.intrinsicContentSize.width + 20 }
    private var barHeight: CGFloat { usesSecondRow ? controlHeight * 2 + 24 : controlHeight + 16 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: barHeight) }

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
        guard rowChanged else { return }
        guard !geometryUpdateScheduled else { return }
        // Defer width-dependent sizing until the current parent layout has finished.
        geometryUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            geometryUpdateScheduled = false
            heightConstraint.constant = barHeight
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    func update(filter: CaptureRecordFilter, records: [CaptureRecord], paused: Bool, viewingFile: Bool = false,
                customColumnCount: Int = 0, savesFilter: Bool = false) {
        self.filter = filter
        pause.image = NSImage(systemSymbolName: paused ? "play" : "pause", accessibilityDescription: nil)
        pause.setAccessibilityLabel(paused ? "继续记录" : "暂停记录")
        pause.toolTip = (paused ? "继续记录" : "暂停记录（代理继续工作）") + "（⌘⇧R）"
        pause.isEnabled = !viewingFile
        clearButton.isEnabled = !viewingFile && !records.isEmpty
        clearButton.toolTip = "清空全部请求日志（⌘K）"
        primary.selectedSegment = primaryTypes.firstIndex(of: filter.resource) ?? -1
        updateDisplayButton(customColumnCount: customColumnCount)
        formAccessory.update(filter: filter, records: records, savesFilter: savesFilter)
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
        displayButton.frame = NSRect(x: bounds.width - 12 - height, y: actionY, width: height, height: height)
        let origin: CGFloat = usesSecondRow ? 10 : 43 + height * 2
        // Keep the native drawing scale so labels and the bezel retain their proportions.
        primary.frame = NSRect(origin: NSPoint(x: origin, y: 8), size: size)
    }
    private func changeResource(_ resource: CaptureResourceType) {
        filter.resource = resource; onFilterChange(filter)
    }
    private func updateDisplayButton(customColumnCount count: Int) {
        guard customColumnCount != count else { return }
        customColumnCount = count
        let active = count > 0
        displayButton.updateSymbol("gauge.with.dots.needle.67percent",
                                   activeSymbol: "gauge.with.dots.needle.67percent", active: active,
                                   pointSize: 20)
        displayButton.toolTip = active ? "显示选项（\(count) 列）" : "显示选项"
        displayButton.setAccessibilityValue(active ? "\(count) 列" : "默认列布局")
    }
    @objc private func selectPrimary() {
        guard primaryTypes.indices.contains(primary.selectedSegment) else { return }
        changeResource(primaryTypes[primary.selectedSegment])
    }
    func installFormAccessory(on window: NSWindow) { formAccessory.install(on: window) }
    func removeFormAccessory() { formAccessory.uninstall() }
    @objc func showFilters() {
        if let window { formAccessory.install(on: window) }
        formAccessory.toggle()
    }
}

@MainActor
private final class RequestFilterFormAccessory: NSTitlebarAccessoryViewController {
    var onFilterChange: (CaptureRecordFilter) -> Void = { _ in }
    var onSaveFilterChange: (Bool) -> Void = { _ in }
    private var filter = CaptureRecordFilter()
    private var records: [CaptureRecord] = []
    private var savesFilter = false
    private var panel: RequestFilterPanel?
    private(set) var isExpanded = false
    private var revealedHeight: CGFloat = 0
    private var targetHeight: CGFloat = 0
    private var transition: Task<Void, Never>?
    private var geometryUpdateScheduled = false
    private weak var installedWindow: NSWindow?

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        automaticallyAdjustsSize = false
        if #available(macOS 26.1, *) { preferredScrollEdgeEffectStyle = .soft }
    }
    required init?(coder: NSCoder) { nil }
    deinit { transition?.cancel(); NotificationCenter.default.removeObserver(self) }

    override func loadView() {
        let clip = RequestFilterFormView(frame: .zero)
        clip.wantsLayer = true; clip.layer?.masksToBounds = true
        clip.isHidden = true
        clip.setAccessibilityLabel("筛选配置")
        clip.onWidthChange = { [weak self] in self?.scheduleGeometryUpdate() }
        view = clip
    }

    func install(on window: NSWindow) {
        guard installedWindow !== window else { return }
        uninstall()
        installedWindow = window
        view.setFrameSize(NSSize(width: window.contentView?.bounds.width ?? 600, height: revealedHeight))
        window.addTitlebarAccessoryViewController(self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize(_:)),
                                               name: NSWindow.didResizeNotification, object: window)
        resizeForm(animated: false)
        applyRevealedHeight(isExpanded ? panelHeight : 0)
    }

    func uninstall() {
        transition?.cancel(); transition = nil
        guard let window = installedWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: window)
        targetHeight = isExpanded ? panelHeight : 0
        applyRevealedHeight(targetHeight)
        installedWindow = nil
        if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === self }) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    func update(filter: CaptureRecordFilter, records: [CaptureRecord], savesFilter: Bool) {
        self.filter = filter; self.records = records; self.savesFilter = savesFilter
        panel?.update(filter: filter, records: records, savesFilter: savesFilter)
    }

    func toggle() {
        installedWindow?.makeFirstResponder(nil)
        if panel == nil {
            let panel = RequestFilterPanel(filter: filter, records: records) { [weak self] value in
                guard let self else { return }; filter = value
                onFilterChange(value)
            }
            panel.onSaveFilterChange = { [weak self] value in
                guard let self else { return }; savesFilter = value
                onSaveFilterChange(value)
            }
            panel.update(filter: filter, records: records, savesFilter: savesFilter)
            self.panel = panel
            view.addSubview(panel.view)
            (view as? RequestFilterFormView)?.content = panel.view
            panel.onHeightChange = { [weak self] in self?.resizeForm(animated: false) }
        }
        isExpanded.toggle()
        view.isHidden = false
        resizeForm(animated: true)
    }

    private var panelHeight: CGFloat {
        guard let panel else { return 0 }
        return min(panel.formHeight, max(0, (installedWindow?.contentView?.bounds.height ?? 720) * 0.45))
    }

    private func scheduleGeometryUpdate() {
        guard !geometryUpdateScheduled else { return }
        geometryUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            geometryUpdateScheduled = false
            guard installedWindow != nil else { return }
            resizeForm(animated: false)
        }
    }

    @objc private func windowDidResize(_ notification: Notification) { scheduleGeometryUpdate() }

    private func resizeForm(animated: Bool) {
        (view as? RequestFilterFormView)?.contentHeight = panelHeight
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let destination = isExpanded ? panelHeight : 0
        // Log refreshes must not interrupt an in-flight transition to the same height.
        if abs(targetHeight - destination) < 0.5, transition != nil { return }
        if transition == nil, abs(revealedHeight - destination) < 0.5 { return }
        transition?.cancel()
        transition = nil
        targetHeight = destination
        let startHeight = revealedHeight
        guard animated, installedWindow != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(startHeight - destination) > 0.5 else {
            applyRevealedHeight(destination)
            return
        }
        // Animate the accessory viewport height; AppKit owns the titlebar and its insets.
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
            view.isHidden = height == 0
            view.setFrameSize(NSSize(width: view.frame.width, height: height))
            fullScreenMinHeight = height
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            installedWindow?.contentView?.layoutSubtreeIfNeeded()
        }
        CATransaction.commit()
    }
}

@MainActor
private final class RequestFilterFormView: NSView {
    var onWidthChange: () -> Void = {}
    weak var content: NSView?
    var contentHeight: CGFloat = 0
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange() }
    }
    override func layout() {
        super.layout()
        content?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
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
    func updateSymbol(_ symbol: String, activeSymbol: String, active: Bool, pointSize: CGFloat? = nil) {
        // Color only the SF Symbol's disc, leaving the native glass bezel untouched.
        // At 28 pt the circular symbol fits the 36 pt bezel and renders centered.
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize ?? (active ? 28 : 16), weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: active ? [.white, .systemBlue] : [.labelColor]))
        image = NSImage(systemSymbolName: active ? activeSymbol : symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
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
    var onSaveFilterChange: (Bool) -> Void = { _ in }
    private var savesFilter = false
    private let saveFilter = NSButton(checkboxWithTitle: "保存筛选项", target: nil, action: nil)
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
        saveFilter.target = self; saveFilter.action = #selector(toggleSaveFilter)
        saveFilter.toolTip = "保存当前筛选条件及后续修改，下次启动时自动应用；取消勾选会清除已保存条件"
        saveFilter.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NativeUI.stack([inverse, hint, NSView(), saveFilter, reset], vertical: false, spacing: 12)
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        self.footer = footer
        let stack = NativeUI.stack([divider, scroll, footer], spacing: 0)
        NativeUI.pin(stack, to: view)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        refreshControls()
    }
    func update(filter: CaptureRecordFilter, records: [CaptureRecord], savesFilter: Bool = false) {
        self.filter = filter; self.records = records; self.savesFilter = savesFilter
        if isViewLoaded { refreshControls() }
    }
    private func refreshControls() {
        groupView.update(filter.conditionGroup ?? draft, records: records)
        inverse.state = filter.inverted ? .on : .off
        saveFilter.state = savesFilter ? .on : .off
        reset.isEnabled = filter != CaptureRecordFilter()
        onHeightChange()
    }
    private func changed() { refreshControls(); onChange(filter) }
    @objc private func toggleSaveFilter() {
        savesFilter = saveFilter.state == .on
        onSaveFilterChange(savesFilter)
    }
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
private final class FilterConditionRow: NSView {
    let conditionID: UUID
    private var condition: CaptureFilterCondition
    private let onChange: (CaptureFilterCondition) -> Void
    private let field = NSPopUpButton(), operation = NSPopUpButton()
    private let originalRequest = NSButton(checkboxWithTitle: "原始请求", target: nil, action: nil)
    private let name = ActionComboBox(), value = ActionComboBox()
    private var headerWidths: [NSLayoutConstraint] = []
    private var records: [CaptureRecord] = []
    init(condition: CaptureFilterCondition, onChange: @escaping (CaptureFilterCondition) -> Void, remove: @escaping () -> Void) {
        self.condition = condition; conditionID = condition.id; self.onChange = onChange
        super.init(frame: .zero)
        field.addItems(withTitles: CaptureFilterField.allCases.map(\.rawValue))
        field.target = self; field.action = #selector(selectField); field.setAccessibilityLabel("筛选字段")
        originalRequest.target = self; originalRequest.action = #selector(selectSource)
        originalRequest.setAccessibilityLabel("匹配原始请求 Header")
        originalRequest.toolTip = "勾选：匹配原始请求 Header；取消勾选：匹配修改后发出的请求 Header"
        originalRequest.setContentHuggingPriority(.required, for: .horizontal)
        originalRequest.setContentCompressionResistancePriority(.required, for: .horizontal)
        operation.target = self; operation.action = #selector(selectOperation); operation.setAccessibilityLabel("匹配方式")
        name.placeholderString = "Header 名称"; name.setAccessibilityLabel("Header 名称")
        for control in [name, value] {
            control.numberOfVisibleItems = 8
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        name.completes = true
        name.onChange = { [weak self] text in
            guard let self else { return }
            self.condition.headerName = text; self.onChange(self.condition)
        }
        value.onChange = { [weak self] text in
            guard let self else { return }
            self.condition.value = text; self.onChange(self.condition)
        }
        field.widthAnchor.constraint(equalToConstant: 112).isActive = true
        operation.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let row = NativeUI.stack([field, name, operation, value, originalRequest,
                                  filterRemoveButton(label: "移除条件", action: remove)], vertical: false, spacing: 6)
        row.detachesHiddenViews = true
        NativeUI.pin(row, to: self, insets: NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0))
        // Share available input space without letting long drafts crowd out the other field.
        let balancedWidth = name.widthAnchor.constraint(equalTo: value.widthAnchor)
        balancedWidth.priority = .defaultHigh
        headerWidths = [balancedWidth]
        for control in [name, value] {
            let preferredWidth = control.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
            preferredWidth.priority = .defaultLow
            headerWidths.append(preferredWidth)
        }
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
        let isHeader = condition.field == .header
        originalRequest.state = condition.headerSource == .original ? .on : .off
        name.isHidden = !isHeader
        originalRequest.isHidden = !isHeader
        for constraint in headerWidths { constraint.isActive = isHeader }
        value.isEnabled = condition.operation.needsValue
        value.setAccessibilityLabel(condition.field == .header ? "Header 值" : condition.field.rawValue)
        value.placeholderString = isHeader ? (condition.operation.needsValue ? "Header 值" : "无需填写值") :
            condition.field.supportsMultipleValues ? "多个值，-值 排除" : "输入或选择\(condition.field.rawValue)"
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
    private func setSuggestions(_ control: ActionComboBox, _ values: [String], text: String) {
        let suggestions = Array(Set(values.filter { !$0.isEmpty })).sorted()
        control.setSuggestions(suggestions)
        if control.stringValue != text { control.stringValue = text }
    }
    @objc private func selectField() {
        condition.field = CaptureFilterField.allCases[field.indexOfSelectedItem]
        condition.operation = condition.field.operations[0]; condition.value = ""
        onChange(condition)
    }
    @objc private func selectOperation() {
        condition.operation = condition.field.operations[operation.indexOfSelectedItem]; onChange(condition)
    }
    @objc private func selectSource() {
        condition.headerSource = originalRequest.state == .on ? .original : .sent
        onChange(condition)
    }
}
