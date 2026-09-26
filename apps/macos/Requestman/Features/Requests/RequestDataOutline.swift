import AppKit

enum RequestDataChange: Sendable, Equatable {
    case unchanged, added, removed, modified
}

enum RequestDataValueKind: Sendable, Equatable {
    case plain, string, number, boolean, null
}

struct RequestDataNode: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let value: String
    let typeName: String
    let copyValue: String
    let children: [RequestDataNode]
    let change: RequestDataChange
    let valueKind: RequestDataValueKind
    let originalValue: String?
    let highlightsChange: Bool
    let jsonStringValue: String?

    init(
        id: String,
        name: String,
        value: String,
        typeName: String = "",
        copyValue: String,
        children: [RequestDataNode] = [],
        change: RequestDataChange = .unchanged,
        valueKind: RequestDataValueKind = .plain,
        originalValue: String? = nil,
        highlightsChange: Bool = true,
        jsonStringValue: String? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.typeName = typeName
        self.copyValue = copyValue
        self.children = children
        self.change = change
        self.valueKind = valueKind
        self.originalValue = originalValue
        self.highlightsChange = highlightsChange
        self.jsonStringValue = jsonStringValue
    }
}

/// A native field table and JSON outline. The owner supplies a complete copy
/// payload for each node, including the entire JSON subtree for containers.
@MainActor
final class RequestDataOutline: NSView {
    var onSelectPath: (String) -> Void = { _ in }
    private let coordinator = Coordinator(onSelectPath: { _ in })
    private let scrollView = RequestDataScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    private func configure() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder

        let outline = RequestDataOutlineView()
        outline.rowHeight = 30
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 12
        outline.indentationMarkerFollowsCell = true
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnSelection = false
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.setAccessibilityLabel("请求与响应数据")
        outline.target = outline
        outline.doubleAction = #selector(RequestDataOutlineView.toggleClickedItemExpansion(_:))

        for column in RequestDataColumn.allCases {
            let item = NSTableColumn(identifier: column.identifier)
            item.title = column.title
            item.minWidth = 0
            item.maxWidth = .greatestFiniteMagnitude
            item.resizingMask = []
            item.isEditable = false
            outline.addTableColumn(item)
            if column == .name { outline.outlineTableColumn = item }
        }
        outline.dataSource = coordinator
        outline.delegate = coordinator
        scrollView.documentView = outline
        coordinator.outline = outline
        scrollView.contentWidthChanged = { [weak coordinator = coordinator] width in
            coordinator?.fitColumns(to: width)
        }
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    func update(nodes: [RequestDataNode], showsTypes: Bool, isVisible: Bool,
                stateKey: String = "default", expandsMatches: Bool = false) {
        if scrollView.isHidden == isVisible {
            if !isVisible, let outline = coordinator.outline, outline.window?.firstResponder === outline {
                outline.window?.makeFirstResponder(nil)
            }
            scrollView.isHidden = !isVisible
            if let outline = coordinator.outline {
                outline.contentVisibilityDidChange(isVisible)
                outline.window?.invalidateCursorRects(for: outline)
            }
        }
        coordinator.onSelectPath = onSelectPath
        coordinator.update(nodes: nodes, showsTypes: showsTypes, stateKey: stateKey, expandsMatches: expandsMatches)
        coordinator.fitColumns(to: scrollView.contentView.bounds.width)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var onSelectPath: (String) -> Void
        fileprivate weak var outline: RequestDataOutlineView?
        private var nodes: [RequestDataNode] = []
        private var roots: [RequestDataItem] = []
        private var itemsByID: [String: RequestDataItem] = [:]
        private var showsTypes = false
        private var expandsMatches = false
        private var stateKey: String?
        private var states: [String: OutlineState] = [:]
        private var stateOrder: [String] = []
        private var updating = false

        init(onSelectPath: @escaping (String) -> Void) { self.onSelectPath = onSelectPath }

        func update(nodes: [RequestDataNode], showsTypes: Bool, stateKey: String, expandsMatches: Bool) {
            guard let outline else { return }
            let nodesChanged = self.nodes != nodes
            guard nodesChanged || self.showsTypes != showsTypes || self.stateKey != stateKey
                    || self.expandsMatches != expandsMatches else { return }
            saveState()
            self.nodes = nodes
            self.showsTypes = showsTypes
            self.stateKey = stateKey
            self.expandsMatches = expandsMatches
            updating = true
            defer { updating = false }

            itemsByID = [:]
            roots = nodes.map(makeItem)
            outline.tableColumn(withIdentifier: RequestDataColumn.type.identifier)?.isHidden = !showsTypes
            outline.reloadData()

            let state = states[stateKey] ?? OutlineState(
                expandedIDs: Set(roots.filter { !$0.children.isEmpty }.map { $0.node.id })
            )
            if expandsMatches {
                // Filtering keeps the ancestors of matches; open every retained
                // path so a matching descendant cannot remain hidden.
                for root in roots { outline.expandItem(root, expandChildren: true) }
            } else {
                restoreExpansion(roots, expandedIDs: state.expandedIDs)
            }
            if let selectedID = state.selectedID, let item = itemsByID[selectedID] {
                let row = outline.row(forItem: item)
                outline.selectRowIndexes(row >= 0 ? IndexSet(integer: row) : [], byExtendingSelection: false)
            } else {
                outline.deselectAll(nil)
            }
            outline.layoutSubtreeIfNeeded()
            if let scrollView = outline.enclosingScrollView {
                let clipView = scrollView.contentView
                let origin = expandsMatches && nodesChanged ? .zero : state.scrollOrigin
                let proposed = NSRect(origin: origin, size: clipView.bounds.size)
                clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
                scrollView.reflectScrolledClipView(clipView)
            }
        }

        func fitColumns(to availableWidth: CGFloat) {
            guard let outline, availableWidth > 0 else { return }
            let actionWidth = min(60, availableWidth)
            let typeWidth: CGFloat = showsTypes ? min(54, availableWidth * 0.14) : 0
            let remaining = max(0, availableWidth - actionWidth - typeWidth)
            let nameWidth = min(190, remaining * 0.42)
            let widths = [nameWidth, remaining - nameWidth, typeWidth, actionWidth]
            for (column, width) in zip(outline.tableColumns, widths) where abs(column.width - width) > 0.1 {
                column.width = width
            }
            if abs(outline.frame.width - availableWidth) > 0.1 {
                outline.setFrameSize(NSSize(width: availableWidth, height: outline.frame.height))
            }
        }

        private func makeItem(_ node: RequestDataNode) -> RequestDataItem {
            let item = RequestDataItem(node: node)
            itemsByID[node.id] = item
            item.children = node.children.map(makeItem)
            return item
        }

        private func restoreExpansion(_ items: [RequestDataItem], expandedIDs: Set<String>) {
            guard let outline else { return }
            for item in items {
                if expandedIDs.contains(item.node.id) { outline.expandItem(item) }
                restoreExpansion(item.children, expandedIDs: expandedIDs)
            }
        }

        private func saveState() {
            guard let outline, let stateKey else { return }
            let expandedIDs = Set(itemsByID.values.filter { outline.isItemExpanded($0) }.map { $0.node.id })
            states[stateKey] = OutlineState(
                expandedIDs: expandedIDs,
                selectedID: (outline.item(atRow: outline.selectedRow) as? RequestDataItem)?.node.id,
                scrollOrigin: outline.enclosingScrollView?.contentView.bounds.origin ?? .zero
            )
            stateOrder.removeAll { $0 == stateKey }
            stateOrder.append(stateKey)
            // Bound retained view state even when the owner includes a request ID.
            while stateOrder.count > 24 { states.removeValue(forKey: stateOrder.removeFirst()) }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? RequestDataItem)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? RequestDataItem)?.children ?? roots)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? RequestDataItem else { return false }
            return !item.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? RequestDataItem)?.node.originalValue == nil ? 30 : 48
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? RequestDataItem,
                  let identifier = tableColumn?.identifier,
                  let column = RequestDataColumn(rawValue: identifier.rawValue) else { return nil }
            // The trailing column reserves room for the row's native copy button.
            guard column != .action else { return nil }
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? RequestDataCell)
                ?? RequestDataCell(column: column)
            cell.configure(item.node)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            guard let item = item as? RequestDataItem else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("RequestDataRow")
            let row = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? RequestDataRowView)
                ?? RequestDataRowView()
            row.identifier = identifier
            row.configure(item.node)
            return row
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline,
                  let item = outline.item(atRow: outline.selectedRow) as? RequestDataItem else { return }
            onSelectPath(item.node.id)
        }
    }
}

private struct OutlineState {
    var expandedIDs: Set<String>
    var selectedID: String? = nil
    var scrollOrigin: NSPoint = .zero
}

@MainActor
private final class RequestDataItem: NSObject {
    let node: RequestDataNode
    var children: [RequestDataItem] = []

    init(node: RequestDataNode) { self.node = node }
}

private enum RequestDataColumn: String, CaseIterable {
    case name, value, type, action

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    var title: String {
        switch self {
        case .name: "字段"
        case .value: "值"
        case .type: "类型"
        case .action: ""
        }
    }
}

@MainActor
private final class RequestDataScrollView: NSScrollView {
    var contentWidthChanged: ((CGFloat) -> Void)?
    private var previousWidth: CGFloat = -1

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        if abs(width - previousWidth) > 0.1 {
            previousWidth = width
            contentWidthChanged?(width)
        }
    }
}

@MainActor
private final class RequestDataOutlineView: NSOutlineView {
    func contentVisibilityDidChange(_ visible: Bool) {
        enumerateAvailableRowViews { row, _ in
            (row as? RequestDataRowView)?.contentVisibilityDidChange(visible)
        }
    }

    @objc func toggleClickedItemExpansion(_ sender: Any?) {
        guard !isHiddenOrHasHiddenAncestor,
              clickedRow >= 0, clickedRow < numberOfRows,
              tableColumns.indices.contains(clickedColumn),
              tableColumns[clickedColumn].identifier != RequestDataColumn.action.identifier,
              let item = item(atRow: clickedRow) as? RequestDataItem,
              !item.children.isEmpty else { return }
        if isItemExpanded(item) {
            collapseItem(item)
        } else {
            expandItem(item)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHiddenOrHasHiddenAncestor else { return }
        addCursorRect(visibleRect, cursor: .arrow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let targetRow = row(at: location)
        guard targetRow >= 0, let item = item(atRow: targetRow) as? RequestDataItem else { return nil }
        selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: item.children.isEmpty ? "复制字段" : "复制子树", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c", selectedRow >= 0 {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let item = item(atRow: selectedRow) as? RequestDataItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.node.copyValue, forType: .string)
    }
}

@MainActor
private final class RequestDataRowView: NSTableRowView, NSPopoverDelegate {
    private let copyButton = RequestRowActionButton(symbol: "doc.on.doc", label: "复制字段")
    private let previewButton = RequestRowActionButton(symbol: "curlybraces", label: "预览 JSON")
    private var trackingArea: NSTrackingArea?
    private var copyValue = ""
    private var fieldName = ""
    private var jsonStringValue: String?
    private var change: RequestDataChange = .unchanged
    private var copyFeedbackTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration: UInt = 0
    private var previewAttempted = false
    private var previewNodes: [RequestDataNode]?
    private var previewPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        copyButton.target = self
        copyButton.action = #selector(copyField)
        previewButton.target = self
        previewButton.action = #selector(showStringPreview)
        previewButton.toolTip = "以树形结构预览字符串中的 JSON"
        addSubview(copyButton)
        addSubview(previewButton)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(_ node: RequestDataNode) {
        resetPreview()
        setActionsVisible(false, animated: false)
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        copyValue = node.copyValue
        fieldName = node.name
        jsonStringValue = node.jsonStringValue
        change = node.highlightsChange ? node.change : .unchanged
        let label = node.children.isEmpty ? "复制字段" : "复制子树"
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: label)
        copyButton.toolTip = label
        copyButton.setAccessibilityLabel("\(label)：\(node.name)")
        previewButton.setAccessibilityLabel("预览 JSON：\(node.name)")
        updateBackgroundColor()
        updateActionVisibility()
    }

    func contentVisibilityDidChange(_ visible: Bool) {
        if visible {
            updateActionVisibility()
        } else {
            resetPreview()
            setActionsVisible(false, animated: false)
        }
    }

    override func layout() {
        super.layout()
        let actionWidth = min(60, bounds.width)
        let buttonWidth = min(26, max(0, (actionWidth - 6) / 2))
        let y = (bounds.height - 24) / 2
        copyButton.frame = NSRect(x: max(0, bounds.width - 3 - buttonWidth), y: y, width: buttonWidth, height: 24)
        previewButton.frame = NSRect(x: max(0, copyButton.frame.minX - 2 - buttonWidth), y: y, width: buttonWidth, height: 24)
        // Cell reuse may occur while the pointer stays still.
        updateActionVisibility()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
        updateActionVisibility()
    }

    override func mouseEntered(with event: NSEvent) { updateActionVisibility() }
    override func mouseExited(with event: NSEvent) {
        setActionsVisible(false, animated: window?.isKeyWindow == true)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            resetPreview()
            setActionsVisible(false, animated: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            resetPreview()
            setActionsVisible(false, animated: false)
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            center.addObserver(self, selector: #selector(keyWindowChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(keyWindowChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        }
        updateActionVisibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    private func updateActionVisibility() {
        guard let window, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else {
            resetPreview()
            setActionsVisible(false, animated: false)
            return
        }
        // A popover can become key; losing key status must not dismiss it or
        // discard its parsed data while the user is inspecting the tree.
        guard window.isKeyWindow else {
            setActionsVisible(false, animated: false)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let hovered = visibleRect.contains(point)
        setActionsVisible(hovered)
        if hovered { prepareStringPreviewIfNeeded() }
    }

    private func setActionsVisible(_ visible: Bool, animated: Bool = true) {
        copyButton.setVisible(visible, animated: animated)
        previewButton.setVisible(visible && previewNodes != nil, animated: animated)
    }

    private func prepareStringPreviewIfNeeded() {
        guard !previewAttempted, previewTask == nil, let source = jsonStringValue else { return }
        previewAttempted = true
        let generation = previewGeneration
        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return [RequestDataNode]?.none }
            return RequestInspectionData.stringJSONPreview(source)
        }
        previewTask = Task { @MainActor [weak self] in
            let nodes = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.previewGeneration == generation,
                  self.jsonStringValue == source, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
            self.previewTask = nil
            self.previewNodes = nodes
            self.updateActionVisibility()
        }
    }

    private func resetPreview() {
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        previewAttempted = false
        previewNodes = nil
        previewButton.setVisible(false, animated: false)
        if let popover = previewPopover {
            previewPopover = nil
            popover.close()
            popover.contentViewController = nil
        }
    }

    @objc private func showStringPreview() {
        guard previewButton.acceptsVisibleAction, let nodes = previewNodes,
              window != nil, !isHiddenOrHasHiddenAncestor else { return }
        if let previewPopover, previewPopover.isShown {
            previewPopover.performClose(nil)
            return
        }
        let popover = NSPopover()
        // The SDK forbids nested semi-transient popovers, but not transient
        // popovers. Keep AppKit's outside-click dismissal and nested behavior.
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = RequestStringJSONPreview(
            fieldName: fieldName, nodes: nodes, onClose: { [weak popover] in popover?.performClose(nil) }
        )
        popover.contentSize = NSSize(width: 520, height: 380)
        previewPopover = popover
        // The button fades when the popover becomes key. Anchor to the stable
        // row instead so that hiding the button cannot invalidate the anchor.
        popover.show(relativeTo: previewButton.frame, of: self, preferredEdge: .minX)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === previewPopover else { return }
        previewPopover = nil
        popover.contentViewController = nil
        updateActionVisibility()
    }

    @objc private func keyWindowChanged(_ notification: Notification) {
        if notification.name == NSWindow.didResignKeyNotification {
            setActionsVisible(false, animated: false)
        } else {
            updateActionVisibility()
        }
    }

    private func updateBackgroundColor() {
        switch change {
        case .unchanged: backgroundColor = .clear
        case .added: backgroundColor = .systemGreen.withAlphaComponent(0.08)
        case .removed: backgroundColor = .systemRed.withAlphaComponent(0.07)
        case .modified: backgroundColor = .systemOrange.withAlphaComponent(0.10)
        }
    }

    @objc private func copyField() {
        guard copyButton.acceptsVisibleAction else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyValue, forType: .string)
        copyFeedbackTask?.cancel()
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
        copyFeedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            guard let self else { return }
            self.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: self.copyButton.toolTip)
        }
    }
}

/// Native buttons share the same interruptible hover fade and pointer behavior.
@MainActor
private final class RequestRowActionButton: NSButton {
    private var visibilityTarget = false
    private var animationGeneration: UInt = 0

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        controlSize = .small
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        alphaValue = 0
        isEnabled = false
        isHidden = true
    }

    required init?(coder: NSCoder) { return nil }

    var acceptsVisibleAction: Bool { visibilityTarget && isEnabled && !isHiddenOrHasHiddenAncestor }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsVisibleAction, displayedAlpha > 0.01 else { return nil }
        return super.hitTest(point)
    }

    private var displayedAlpha: CGFloat {
        if let presentation = layer?.presentation() { return CGFloat(presentation.opacity) }
        return alphaValue
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        let animates = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard visibilityTarget != visible || !animates else { return }
        visibilityTarget = visible
        animationGeneration &+= 1
        let generation = animationGeneration
        let currentAlpha = displayedAlpha
        layer?.removeAllAnimations()
        isEnabled = visible
        guard animates else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            return
        }
        alphaValue = currentAlpha
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationGeneration == generation else { return }
                self.isHidden = !self.visibilityTarget
            }
        }
    }
}

@MainActor
private final class RequestStringJSONPreview: NSViewController {
    private let fieldName: String
    private let nodes: [RequestDataNode]
    private let onClose: () -> Void
    init(fieldName: String, nodes: [RequestDataNode], onClose: @escaping () -> Void) {
        self.fieldName = fieldName; self.nodes = nodes; self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        let title = NSTextField(labelWithString: "JSON 预览")
        title.font = .boldSystemFont(ofSize: 13)
        let field = NSTextField(labelWithString: fieldName)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭预览")!, target: self, action: #selector(closePreview))
        close.isBordered = false
        close.keyEquivalent = "\u{1b}"
        let header = NSStackView(views: [title, field, close])
        header.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let outline = RequestDataOutline()
        for child in [header, outline] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            outline.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            outline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outline.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        outline.update(nodes: nodes, showsTypes: true, isVisible: true)
    }
    @objc private func closePreview() { onClose() }
}

@MainActor
private final class RequestDataCell: NSTableCellView {
    private let column: RequestDataColumn
    private let primary = NSTextField(labelWithString: "")
    private let original = NSTextField(labelWithString: "")
    private var primaryColor = NSColor.labelColor

    init(column: RequestDataColumn) {
        self.column = column
        super.init(frame: .zero)
        identifier = column.identifier
        for label in [primary, original] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        original.isHidden = true
        if column == .type { primary.font = .systemFont(ofSize: 10) }
        textField = primary
    }

    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func configure(_ node: RequestDataNode) {
        original.isHidden = true
        original.stringValue = ""
        primaryColor = .labelColor
        switch column {
        case .name:
            primary.stringValue = node.name
            primary.font = .monospacedSystemFont(ofSize: 11, weight: node.children.isEmpty ? .regular : .bold)
        case .value:
            primary.stringValue = node.value
            primaryColor = Self.valueColor(node.valueKind)
            if let originalValue = node.originalValue {
                original.stringValue = "原始  \(originalValue)"
                primary.stringValue = "最终  \(node.value)"
                original.isHidden = false
            }
        case .type:
            primary.stringValue = node.typeName
            primaryColor = .tertiaryLabelColor
        case .action:
            primary.stringValue = ""
        }
        primary.toolTip = primary.stringValue
        original.toolTip = original.stringValue
        toolTip = original.isHidden ? primary.stringValue : "\(original.stringValue)\n\(primary.stringValue)"
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = min(6, bounds.width / 2)
        let width = max(0, bounds.width - inset * 2)
        if original.isHidden {
            primary.frame = NSRect(x: inset, y: (bounds.height - 17) / 2, width: width, height: 17)
        } else {
            original.frame = NSRect(x: inset, y: 5, width: width, height: 17)
            primary.frame = NSRect(x: inset, y: 25, width: width, height: 17)
        }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        primary.textColor = selected ? .alternateSelectedControlTextColor : primaryColor
        original.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    private static func valueColor(_ kind: RequestDataValueKind) -> NSColor {
        switch kind {
        case .plain: .labelColor
        case .string: .systemTeal
        case .number: .systemBlue
        case .boolean: .systemPurple
        case .null: .secondaryLabelColor
        }
    }
}
