import AppKit
import RequestmanCore

@MainActor
final class RequestRecordsTable: NSView {
    static let columnWidthsKey = "requestLog.columnWidths.v1"
    var onDeviceAliasChange: (String, String) -> Void = { _, _ in }
    var onSelectionChange: (UUID?) -> Void = { _ in }
    var onColumnOrderChange: ([String]) -> Void = { _ in }
    var replayUnavailableReason: () -> String? = { nil }
    var onCancelReplay: (UUID) -> Void = { _ in }
    var revealSource: ((UUID) -> Void)?
    var sourceExists: (UUID) -> Bool = { _ in false }
    var onReplay: (CaptureRecord, Bool) -> Void = { _, _ in }
    var onMockRequest: (CaptureRecord) -> Void = { _ in }
    var onSaveSession: (CaptureRecord) -> Void = { _ in }
    private let coordinator: Coordinator
    private let scrollView: NSScrollView

    init(columnDefaults: UserDefaults = .standard, isPreview: Bool = false) {
        coordinator = Coordinator(defaults: columnDefaults, isPreview: isPreview)
        scrollView = RecordsScrollView()
        super.init(frame: .zero)
        coordinator.onDeviceAliasChange = { [weak self] in self?.onDeviceAliasChange($0, $1) }
        coordinator.onSelectionChange = { [weak self] in self?.onSelectionChange($0) }
        coordinator.onColumnOrderChange = { [weak self] in self?.onColumnOrderChange($0) }
        coordinator.replayUnavailableReason = { [weak self] in self?.replayUnavailableReason() }
        coordinator.onCancelReplay = { [weak self] in self?.onCancelReplay($0) }
        coordinator.revealSource = { [weak self] in self?.revealSource?($0) }
        coordinator.sourceExists = { [weak self] in self?.sourceExists($0) ?? false }
        coordinator.onReplay = { [weak self] in self?.onReplay($0, $1) }
        coordinator.onSaveSession = { [weak self] in self?.onSaveSession($0) }
        coordinator.onMockRequest = { [weak self] in self?.onMockRequest($0) }
        configure()
    }
    required init?(coder: NSCoder) { nil }

    func focusList() { window?.makeFirstResponder(scrollView.documentView) }

    private func configure() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder

        let table = RecordsTableView()
        table.isPreview = coordinator.isPreview
        table.menuForRow = { [weak coordinator = coordinator] in coordinator?.menu(forRow: $0) }
        table.rowHeight = 56
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.allowsColumnReordering = !coordinator.isPreview
        table.allowsColumnResizing = !coordinator.isPreview
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        table.setAccessibilityLabel(coordinator.isPreview ? "日志布局预览" : "请求日志")
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.action = #selector(Coordinator.activateRequest(_:))
        scrollView.documentView = table
        coordinator.table = table
        (scrollView as! RecordsScrollView).contentWidthChanged = { [weak coordinator = coordinator] width in
            coordinator?.fitColumns(to: width)
        }
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    func update(records: [CaptureRecord], selectedID: UUID?, workflowNames: [UUID: String] = [:], deviceAliases: [String: String] = [:], showsDeviceSource: Bool = false,
                displayOptions: RequestLogDisplayOptions = .init()) {
        coordinator.selection = selectedID
        coordinator.setDisplayOptions(displayOptions, allowLAN: showsDeviceSource)
        coordinator.update(records: records, workflowNames: workflowNames, deviceAliases: deviceAliases)
        coordinator.fitColumns(to: scrollView.contentView.bounds.width)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selection: UUID?
        var onDeviceAliasChange: (String, String) -> Void = { _, _ in }
        var onSelectionChange: (UUID?) -> Void = { _ in }
        var onColumnOrderChange: ([String]) -> Void = { _ in }
        var replayUnavailableReason: () -> String? = { nil }
        var onCancelReplay: (UUID) -> Void = { _ in }
        var revealSource: ((UUID) -> Void)?
        var sourceExists: (UUID) -> Bool = { _ in false }
        var onReplay: (CaptureRecord, Bool) -> Void = { _, _ in }
        var onMockRequest: (CaptureRecord) -> Void = { _ in }
        var onSaveSession: (CaptureRecord) -> Void = { _ in }
        weak var table: NSTableView?
        private var rows: [RecordRow] = []
        private var capturedRecords: [UUID: CaptureRecord] = [:]
        private var updating = false
        private let defaults: UserDefaults
        let isPreview: Bool
        private var preferredWidths: [String: CGFloat] = [:]
        private var availableWidth: CGFloat = 0
        private var rowHeights: [CGFloat] = []
        private var measuredColumnWidths: [String: CGFloat] = [:]
        private var applyingWidths = false
        private var displayOptions = RequestLogDisplayOptions()
        private var lastAllowLAN: Bool?
        private var configuringColumns = false
        private var displayOptionsChanged = false

        init(defaults: UserDefaults, isPreview: Bool = false) {
            self.defaults = defaults
            self.isPreview = isPreview
            super.init()
            if !isPreview {
                reloadPreferences()
                NotificationCenter.default.addObserver(self, selector: #selector(preferencesRestored),
                                                       name: .init("Requestman.preferencesRestored"), object: nil)
            }
        }

        @objc private func preferencesRestored() {
            reloadPreferences()
            let width = availableWidth
            availableWidth = 0
            fitColumns(to: width)
        }

        private func reloadPreferences() {
            preferredWidths = [:]
            for (key, value) in defaults.dictionary(forKey: RequestRecordsTable.columnWidthsKey) ?? [:] {
                if let width = value as? Double, width.isFinite, width > 0, width < 100_000 {
                    preferredWidths[key] = CGFloat(width)
                }
            }
            if preferredWidths["device"] == nil { preferredWidths["device"] = preferredWidths["environment"] }
            let legacyID = RequestLogExtraColumn(id: RequestLogExtraColumn.legacyHeaderID).identifier
            if preferredWidths[legacyID] == nil { preferredWidths[legacyID] = preferredWidths["header"] }
        }

        func update(records: [CaptureRecord], workflowNames: [UUID: String], deviceAliases: [String: String]) {
            guard let table else { return }
            capturedRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            let nextRows = records.map {
                RecordRow(record: $0, displayOptions: displayOptions,
                          context: .init(workflowNames: workflowNames, deviceAliases: deviceAliases))
            }
            let previousRows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let previousHeights = Dictionary(uniqueKeysWithValues: zip(rows, rowHeights).map { ($0.id, $1) })
            let widths = currentColumnWidths
            let layoutChanged = displayOptionsChanged || widths != measuredColumnWidths
            let nextHeights = nextRows.map { row in
                if !layoutChanged, previousRows[row.id] == row, let height = previousHeights[row.id] { return height }
                return measureHeight(for: row, widths: widths)
            }
            rowHeights = nextHeights
            measuredColumnWidths = widths
            updating = true
            defer { updating = false }

            if displayOptionsChanged {
                rows = nextRows
                table.reloadData()
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
                displayOptionsChanged = false
            }
            if nextRows != rows {
                let difference = nextRows.map(\.id).difference(from: rows.map(\.id))
                var removed = IndexSet()
                var inserted = IndexSet()
                for change in difference {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(offset)
                    case .insert(let offset, _, _): inserted.insert(offset)
                    }
                }
                rows = nextRows
                if !removed.isEmpty || !inserted.isEmpty {
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [])
                    table.insertRows(at: inserted, withAnimation: [])
                    table.endUpdates()
                }
                // Completed records normally only prepend. Reload retained rows only if
                // their displayed values changed, keeping native cell reuse and selection.
                let changed = IndexSet(rows.indices.filter {
                    !inserted.contains($0) && previousRows[rows[$0].id] != rows[$0]
                })
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: table.tableColumns.indices))
                }
                let changedHeights = IndexSet(rows.indices.filter {
                    !inserted.contains($0) && previousHeights[rows[$0].id] != rowHeights[$0]
                })
                if !changedHeights.isEmpty { table.noteHeightOfRows(withIndexesChanged: changedHeights) }
            }

            let selectedRow = isPreview ? nil : selection.flatMap { id in rows.firstIndex { $0.id == id } }
            let indexes = selectedRow.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                if let selectedRow { table.scrollRowToVisible(selectedRow) }
            }
        }

        func setDisplayOptions(_ options: RequestLogDisplayOptions, allowLAN: Bool) {
            guard options != displayOptions || lastAllowLAN != allowLAN else { return }
            displayOptions = options; lastAllowLAN = allowLAN
            displayOptionsChanged = true
            guard let table else { return }
            configuringColumns = true; applyingWidths = true
            defer { configuringColumns = false; applyingWidths = false }
            let identifiers = options.orderedColumnIDs
            let valid = Set(identifiers)
            for item in table.tableColumns where !valid.contains(item.identifier.rawValue) { table.removeTableColumn(item) }
            for id in identifiers where table.tableColumn(withIdentifier: .init(id)) == nil {
                let item = RecordsTableColumn(identifier: .init(id))
                item.headerCell = NSTableHeaderCell(textCell: options.title(forColumnID: id))
                item.minWidth = 0; item.maxWidth = .greatestFiniteMagnitude
                item.resizingMask = isPreview ? [] : .userResizingMask; item.isEditable = false
                item.widthChanged = { [weak self] in self?.resizeColumn($0) }
                table.addTableColumn(item)
            }
            for (index, id) in identifiers.enumerated() {
                let current = table.column(withIdentifier: .init(id))
                if current >= 0 && current != index { table.moveColumn(current, toColumn: index) }
            }
            for item in table.tableColumns {
                let id = item.identifier.rawValue
                item.title = options.title(forColumnID: id)
                item.isHidden = !isPreview && !options.isColumnVisible(id, allowLAN: allowLAN)
                let contents = options.layoutColumns.first(where: { $0.id == id })?.lines.flatMap(\.contents) ?? []
                item.headerToolTip = contents.map(\.displayTitle).joined(separator: " · ")
                switch contents.first?.horizontalAlignment {
                case .center: item.headerCell.alignment = .center
                case .right: item.headerCell.alignment = .right
                default: item.headerCell.alignment = .left
                }
            }
            availableWidth = 0
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard !isPreview, !configuringColumns, let table else { return }
            let order = table.tableColumns.map { $0.identifier.rawValue }
            displayOptions.columnOrder = order
            onColumnOrderChange(order)
        }

        private var visibleColumnIndexes: [Int] {
            guard let table else { return [] }
            return table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        }

        private var currentColumnWidths: [String: CGFloat] {
            guard let table else { return [:] }
            return Dictionary(uniqueKeysWithValues: table.tableColumns.filter { !$0.isHidden }
                .map { ($0.identifier.rawValue, $0.width) })
        }

        private func measureHeight(for row: RecordRow, widths: [String: CGFloat]) -> CGFloat {
            displayOptions.layoutColumns.compactMap { column -> CGFloat? in
                guard let width = widths[column.id] else { return nil }
                return RecordCell.height(for: row.renderedLines(in: column, allowLAN: lastAllowLAN ?? false),
                                         row: row, columnWidth: width)
            }.max() ?? 56
        }

        private func refreshRowHeights() {
            guard let table else { return }
            let widths = currentColumnWidths
            guard widths != measuredColumnWidths else { return }
            let next = rows.map { measureHeight(for: $0, widths: widths) }
            let changed = IndexSet(next.indices.filter { !rowHeights.indices.contains($0) || abs(next[$0] - rowHeights[$0]) > 0.1 })
            rowHeights = next
            measuredColumnWidths = widths
            if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
            table.needsLayout = true
        }

        func fitColumns(to width: CGFloat) {
            guard let table, !configuringColumns, width > 0,
                  abs(width - availableWidth) > 0.1 else { return }
            availableWidth = width
            // Record updates never overwrite a manual resize. Only viewport changes
            // adapt the saved proportions, without persisting the temporary layout.
            let weights = table.tableColumns.map { column -> CGFloat in
                if let preferred = preferredWidths[column.identifier.rawValue] { return preferred }
                return layoutWidth(for: column.identifier.rawValue, minimum: false)
            }
            let minimums = minimumWidths
            var widths = Array(repeating: CGFloat.zero, count: weights.count)
            var remaining = visibleColumnIndexes
            var space = width
            // Clamp small columns first, then distribute the remaining space by
            // the saved proportions. Opening and closing Inspector is reversible.
            while !remaining.isEmpty {
                let total = remaining.reduce(CGFloat.zero) { $0 + weights[$1] }
                let clamped = remaining.filter { space * weights[$0] / total < minimums[$0] }
                if clamped.isEmpty {
                    for index in remaining { widths[index] = space * weights[index] / total }
                    break
                }
                for index in clamped { widths[index] = minimums[index]; space -= minimums[index] }
                remaining.removeAll { clamped.contains($0) }
            }
            apply(widths)
        }

        private var minimumWidths: [CGFloat] {
            guard let table else { return [] }
            let widths = table.tableColumns.map { column -> CGFloat in
                guard !column.isHidden else { return 0 }
                return layoutWidth(for: column.identifier.rawValue, minimum: true)
            }
            let scale = min(1, availableWidth / max(1, widths.reduce(0, +) * 1.5))
            return widths.map { $0 * scale }
        }

        private func layoutWidth(for id: String, minimum: Bool) -> CGFloat {
            guard let column = displayOptions.layoutColumns.first(where: { $0.id == id }) else { return 80 }
            let widths = column.lines.map { line in
                let contents = line.contents.filter { $0.field != .device || lastAllowLAN == true }
                let width = contents.reduce(CGFloat.zero) { total, content in
                    let value: CGFloat
                    switch content.field {
                    case .time: value = minimum ? 60 : 104
                    case .status: value = minimum ? 34 : 56
                    case .method: value = minimum ? 36 : 64
                    case .duration: value = minimum ? 56 : 92
                    case .device: value = minimum ? 48 : 120
                    case .url: value = minimum ? 80 : 340
                    case .rule, .ruleGroup, .rules: value = minimum ? 72 : 190
                    case .host, .path, .detail, .header, .queryParameter: value = minimum ? 72 : 220
                    }
                    return total + value
                }
                return width + CGFloat(max(0, contents.count - 1)) * 8 + 24
            }
            return max(minimum ? 24 : 80, widths.max() ?? 0)
        }

        private func apply(_ widths: [CGFloat]) {
            guard let table else { return }
            applyingWidths = true
            defer { applyingWidths = false }
            let minimums = minimumWidths
            let minimumTotal = minimums.reduce(0, +)
            for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
                column.minWidth = minimums[index]
                column.maxWidth = availableWidth - minimumTotal + minimums[index]
                column.width = widths[index]
            }
            table.setFrameSize(NSSize(width: availableWidth, height: table.frame.height))
            refreshRowHeights()
        }

        func resizeColumn(_ column: NSTableColumn) {
            guard !isPreview, !applyingWidths, !column.isHidden, availableWidth > 0, let table,
                  let index = table.tableColumns.firstIndex(of: column) else { return }
            var widths = table.tableColumns.map { $0.isHidden ? 0 : $0.width }
            let minimums = minimumWidths
            // Borrow space from the next columns, then the preceding columns.
            // The dragged column keeps its width and the table remains viewport-wide.
            let visible = visibleColumnIndexes
            let neighbors = visible.filter { $0 > index } + visible.filter { $0 < index }.reversed()
            if neighbors.isEmpty { widths[index] = availableWidth }
            var excess = widths.reduce(0, +) - availableWidth
            for neighbor in neighbors where excess > 0 {
                let reduction = min(excess, max(0, widths[neighbor] - minimums[neighbor]))
                widths[neighbor] -= reduction
                excess -= reduction
            }
            if excess < 0, let neighbor = neighbors.first { widths[neighbor] -= excess }
            apply(widths)
            // Widths are keyed by stable identity, never by the current drag order.
            for column in table.tableColumns where !column.isHidden {
                preferredWidths[column.identifier.rawValue] = column.width
            }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !isPreview, !applyingWidths, !configuringColumns, let table else { return }
            for column in table.tableColumns where !column.isHidden {
                preferredWidths[column.identifier.rawValue] = column.width
            }
            defaults.set(preferredWidths.mapValues(Double.init), forKey: RequestRecordsTable.columnWidthsKey)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rowHeights.indices.contains(row) ? rowHeights[row] : 56
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !isPreview }

        func menu(forRow row: Int) -> NSMenu? {
            guard !isPreview, rows.indices.contains(row) else { return nil }
            guard let record = capturedRecords[rows[row].id] else { return nil }
            let menu = NSMenu(); menu.autoenablesItems = false
            let item = NSMenuItem(title: "Mock 当前请求", action: #selector(mockRequest(_:)), keyEquivalent: "")
            item.target = self
            // Freeze the entire clicked capture while rows arrive, disappear, or are cleared.
            item.representedObject = record
            item.toolTip = CapturedMockWorkflow.unavailableReason(for: record)
            item.isEnabled = item.toolTip == nil
            RequestActionsMenu.append(to: menu, record: record, replayUnavailable: replayUnavailableReason(),
                                      cancelReplay: onCancelReplay,
                                      revealSource: record.replaySourceID.map(sourceExists) == true ? revealSource : nil, replay: onReplay)
            menu.addItem(.separator())
            menu.addItem(item)
            menu.addItem(.separator())
            let save = onSaveSession
            menu.addItem(RequestActionsMenu.item("保存当前请求会话…") { save(record) })
            return menu
        }

        @objc private func mockRequest(_ sender: NSMenuItem) {
            guard let record = sender.representedObject as? CaptureRecord,
                  CapturedMockWorkflow.unavailableReason(for: record) == nil else { return }
            onMockRequest(record)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let identifier = tableColumn?.identifier,
                  let column = displayOptions.layoutColumns.first(where: { $0.id == identifier.rawValue }) else { return nil }
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? RecordCell)
                ?? RecordCell(identifier: identifier)
            cell.onDeviceAliasChange = { [weak self] in self?.onDeviceAliasChange($0, $1) }
            cell.configure(rows[row], column: column, allowLAN: lastAllowLAN ?? false, isPreview: isPreview)
            return cell
        }

        @objc func activateRequest(_ sender: NSTableView) {
            guard !isPreview, !updating, let table = sender as? RecordsTableView,
                  rows.indices.contains(table.clickedRow), table.clickedRow == table.selectedRow,
                  table.consumeSelectionReactivation() else { return }
            // Keep the toggle in this log window's responder chain.
            _ = sender.tryToPerform(#selector(RequestInspectorPresenting.toggleRequestInspector(_:)), with: sender)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isPreview, !updating, let table else { return }
            let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            if selection != selected { selection = selected; onSelectionChange(selected) }
        }
    }
}

@MainActor
private final class RecordsTableView: NSTableView {
    var menuForRow: (Int) -> NSMenu? = { _ in nil }
    var isPreview = false
    private var reactivatedRow: Int?

    override func mouseDown(with event: NSEvent) {
        guard !isPreview else { return }
        // Capture selection before AppKit changes it and sends the table action.
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        reactivatedRow = clickedRow >= 0 && isRowSelected(clickedRow) ? clickedRow : nil
        defer { reactivatedRow = nil }
        super.mouseDown(with: event)
    }

    func consumeSelectionReactivation() -> Bool {
        defer { reactivatedRow = nil }
        return reactivatedRow != nil && reactivatedRow == selectedRow
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isPreview else { return nil }
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        return menuForRow(clickedRow)
    }
}

// Keep AppKit's native header tracking and drawing. The resize notification
// arrives on mouse-up, while this setter follows every native tracking update.
@MainActor
private final class RecordsTableColumn: NSTableColumn {
    var widthChanged: ((NSTableColumn) -> Void)?

    override var width: CGFloat {
        didSet {
            if abs(width - oldValue) > 0.01 { widthChanged?(self) }
        }
    }
}

private typealias RecordRow = RequestLogRow

@MainActor
private final class RecordsScrollView: NSScrollView {
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
private final class RecordCell: NSTableCellView {
    static let lineSpacing: CGFloat = 2
    var onDeviceAliasChange: (String, String) -> Void = { _, _ in }
    private var lineViews: [RecordContentLineView] = []

    static func height(for lines: [RequestLogRenderedLine], row: RecordRow, columnWidth: CGFloat) -> CGFloat {
        let width = contentWidth(for: columnWidth)
        let contentHeight = lines.reduce(CGFloat.zero) { total, line in
            let measurements = line.contents.map { RecordContentMeasurement(content: $0, row: row) }
            let placements = RecordLineLayout.placements(for: measurements.enumerated().map { $1.layoutItem(index: $0) }, width: width)
            let lineHeight = placements.map { measurements[$0.index].height(for: $0.width) }.max() ?? 0
            return total + lineHeight
        }
        return max(56, contentHeight + CGFloat(max(0, lines.count - 1)) * lineSpacing + 6)
    }

    private static func contentInset(for width: CGFloat) -> CGFloat { min(12, max(0, width - 1) / 2) }
    static func contentWidth(for width: CGFloat) -> CGFloat { max(1, width - contentInset(for: width) * 2) }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func configure(_ row: RecordRow, column: RequestLogLayoutColumn, allowLAN: Bool, isPreview: Bool) {
        let lines = row.renderedLines(in: column, allowLAN: allowLAN)
        while lineViews.count > lines.count { lineViews.removeLast().removeFromSuperview() }
        while lineViews.count < lines.count {
            let view = RecordContentLineView()
            lineViews.append(view); addSubview(view)
        }
        for (index, line) in lines.enumerated() {
            let view = lineViews[index]
            view.onDeviceAliasChange = { [weak self] in self?.onDeviceAliasChange($0, $1) }
            view.configure(line.contents, row: row, isPreview: isPreview)
        }
        // The extraction layer has already removed empty contents and whole empty
        // lines. Center only these actual lines, without their configured positions.
        toolTip = lines.map { $0.contents.map(\.text).joined(separator: " · ") }.joined(separator: "\n")
        setAccessibilityLabel(column.title)
        setAccessibilityValue(toolTip)
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = Self.contentInset(for: bounds.width)
        let width = Self.contentWidth(for: bounds.width)
        let height = lineViews.reduce(CGFloat.zero) { $0 + $1.contentHeight(for: width) }
            + CGFloat(max(0, lineViews.count - 1)) * Self.lineSpacing
        let top = (bounds.height - height) / 2
        var y = top
        for view in lineViews {
            let lineHeight = view.contentHeight(for: width)
            view.frame = NSRect(x: inset, y: y, width: width, height: lineHeight)
            y += lineHeight + Self.lineSpacing
        }
    }

    private func updateColors() {
        for line in lineViews { line.selected = backgroundStyle == .emphasized }
    }
}

private struct RecordLineItem {
    let index: Int
    let horizontalAlignment: RequestLogHorizontalAlignment
    let desiredWidth: CGFloat
    let minimumWidth: CGFloat
    let fillsAvailable: Bool
}

private struct RecordLinePlacement {
    let index: Int
    let x: CGFloat
    let width: CGFloat
}

/// Both row-height measurement and visible cells use this exact width allocation.
private enum RecordLineLayout {
    static func placements(for items: [RecordLineItem], width: CGFloat) -> [RecordLinePlacement] {
        var result: [RecordLinePlacement] = []
        let left = items.filter { $0.horizontalAlignment == .left }
        let center = items.filter { $0.horizontalAlignment == .center }
        let right = items.filter { $0.horizontalAlignment == .right }
        let groups = [left, center, right].filter { !$0.isEmpty }
        guard !groups.isEmpty else { return [] }
        let width = max(CGFloat(items.count), width)
        let gap = min(8, max(0, (width - CGFloat(items.count)) / CGFloat(max(1, items.count * 2))))
        if groups.count == 1 {
            let group = groups[0]
            let widths = allocatedWidths(group, in: width, gap: gap,
                                         fillsAvailable: group[0].horizontalAlignment == .left)
            let total = totalWidth(widths, gap: gap)
            let x: CGFloat
            switch group[0].horizontalAlignment {
            case .left: x = 0
            case .center: x = (width - total) / 2
            case .right: x = width - total
            }
            place(group, widths: widths, x: x, gap: gap, result: &result)
            return result
        }
        if center.isEmpty {
            let joined = left + right
            let widths = allocatedWidths(joined, in: width, gap: gap, fillsAvailable: false)
            let leftWidths = Array(widths.prefix(left.count))
            let rightWidths = Array(widths.suffix(right.count))
            place(left, widths: leftWidths, x: 0, gap: gap, result: &result)
            place(right, widths: rightWidths, x: width - totalWidth(rightWidths, gap: gap), gap: gap, result: &result)
            return result
        }
        // Keep a centered group anchored to the center whenever the adjacent
        // groups fit. Text wraps or truncates inside its remaining region.
        let leftMinimum = minimumWidth(left, gap: gap)
        let rightMinimum = minimumWidth(right, gap: gap)
        let outsideGaps = CGFloat((left.isEmpty ? 0 : 1) + (right.isEmpty ? 0 : 1)) * gap
        let desiredCenter = totalWidth(center.map(\.desiredWidth), gap: gap)
        let minimumTotal = leftMinimum + rightMinimum + minimumWidth(center, gap: gap) + outsideGaps
        if minimumTotal > width {
            let joined = left + center + right
            let widths = allocatedWidths(joined, in: width, gap: gap, fillsAvailable: false)
            let leftWidths = Array(widths.prefix(left.count))
            let centerWidths = Array(widths.dropFirst(left.count).prefix(center.count))
            let rightWidths = Array(widths.suffix(right.count))
            let centerX = totalWidth(leftWidths, gap: gap) + (left.isEmpty ? 0 : gap)
            place(left, widths: leftWidths, x: 0, gap: gap, result: &result)
            place(center, widths: centerWidths, x: centerX, gap: gap, result: &result)
            place(right, widths: rightWidths, x: width - totalWidth(rightWidths, gap: gap), gap: gap, result: &result)
            return result
        }
        let centerWidth = min(desiredCenter, max(0, width - leftMinimum - rightMinimum - outsideGaps))
        let centerX = max(leftMinimum + (left.isEmpty ? 0 : gap),
                          min((width - centerWidth) / 2,
                              width - rightMinimum - (right.isEmpty ? 0 : gap) - centerWidth))
        let leftWidths = allocatedWidths(left, in: max(0, centerX - gap), gap: gap, fillsAvailable: false)
        let centerWidths = allocatedWidths(center, in: centerWidth, gap: gap, fillsAvailable: false)
        let rightWidths = allocatedWidths(right, in: max(0, width - centerX - centerWidth - gap),
                                          gap: gap, fillsAvailable: false)
        place(left, widths: leftWidths, x: 0, gap: gap, result: &result)
        place(center, widths: centerWidths, x: centerX, gap: gap, result: &result)
        place(right, widths: rightWidths, x: width - totalWidth(rightWidths, gap: gap), gap: gap, result: &result)
        return result
    }

    private static func minimumWidth(_ views: [RecordLineItem], gap: CGFloat) -> CGFloat {
        totalWidth(views.map(\.minimumWidth), gap: gap)
    }

    private static func totalWidth(_ widths: [CGFloat], gap: CGFloat) -> CGFloat {
        widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * gap
    }

    private static func allocatedWidths(_ views: [RecordLineItem], in width: CGFloat, gap: CGFloat,
                                 fillsAvailable: Bool) -> [CGFloat] {
        guard !views.isEmpty else { return [] }
        let space = max(0, width - CGFloat(max(0, views.count - 1)) * gap)
        var widths = views.map(\.desiredWidth)
        let desired = widths.reduce(0, +)
        if desired <= space {
            // Extend a trailing text value (the default URL), without pushing
            // later same-alignment contents apart or stretching a centered group.
            if fillsAvailable, let index = views.indices.last, views[index].fillsAvailable {
                widths[index] += space - desired
            }
            return widths
        }
        let minimums = views.map(\.minimumWidth)
        let minimumTotal = minimums.reduce(0, +)
        if minimumTotal >= space {
            return minimums.map { max(1, $0 * space / max(1, minimumTotal)) }
        }
        // Compact status and method tags keep their intrinsic width. Variable
        // text shares the remaining width by its desired size, rather than an
        // equal-width grid that squeezes a URL between short values.
        let flexible = zip(widths, minimums).map { max(0, $0 - $1) }
        let flexibleTotal = flexible.reduce(0, +)
        return zip(minimums, flexible).map { $0 + (space - minimumTotal) * $1 / max(1, flexibleTotal) }
    }


    private static func place(_ items: [RecordLineItem], widths: [CGFloat], x: CGFloat, gap: CGFloat,
                              result: inout [RecordLinePlacement]) {
        var x = x
        for (item, width) in zip(items, widths) {
            let width = max(1, width)
            result.append(.init(index: item.index, x: x, width: width))
            x += width + gap
        }
    }
}

@MainActor
private final class RecordContentLineView: NSView {
    var onDeviceAliasChange: (String, String) -> Void = { _, _ in }
    private var contentViews: [RecordContentView] = []
    var selected = false {
        didSet { for view in contentViews { view.selected = selected } }
    }
    override var isFlipped: Bool { true }

    func contentHeight(for width: CGFloat) -> CGFloat {
        let placements = RecordLineLayout.placements(for: contentViews.enumerated().map { $1.layoutItem(index: $0) }, width: width)
        return placements.map { contentViews[$0.index].contentHeight(for: $0.width) }.max() ?? 0
    }

    func configure(_ contents: [RequestLogRenderedContent], row: RecordRow, isPreview: Bool) {
        while contentViews.count > contents.count { contentViews.removeLast().removeFromSuperview() }
        while contentViews.count < contents.count {
            let view = RecordContentView()
            contentViews.append(view); addSubview(view)
        }
        for (view, content) in zip(contentViews, contents) {
            view.onDeviceAliasChange = { [weak self] in self?.onDeviceAliasChange($0, $1) }
            view.configure(content, row: row, isPreview: isPreview)
            view.selected = selected
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let placements = RecordLineLayout.placements(for: contentViews.enumerated().map { $1.layoutItem(index: $0) }, width: bounds.width)
        for placement in placements {
            let view = contentViews[placement.index]
            let height = view.contentHeight(for: placement.width)
            let y: CGFloat
            switch view.verticalAlignment {
            case .top: y = 0
            case .center: y = (bounds.height - height) / 2
            case .bottom: y = bounds.height - height
            }
            view.frame = NSRect(x: placement.x, y: y, width: placement.width, height: height)
        }
    }
}

@MainActor
private final class RecordContentView: NSView {
    var onDeviceAliasChange: (String, String) -> Void = { _, _ in }
    private var labels: [NSTextField] = []
    private var tags: [RequestLogValueTag] = []
    private var outlines: [RequestLogValueOutline] = []
    private let device = DeviceSourceButton(usesGlass: false)
    private var textColor = NSColor.labelColor
    private var field = RequestLogContentField.url
    private var displayLines: [String] = []
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var hostFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    private var emphasizesHost = false
    private var usesTags = false
    private var usesOutlines = false
    private var borderColorSource = RequestLogBorderColorSource.text
    private var customBorderColor: NSColor?
    private var measurement: RecordContentMeasurement?
    private var truncation = NSLineBreakMode.byTruncatingTail
    var horizontalAlignment = RequestLogHorizontalAlignment.left
    var verticalAlignment = RequestLogVerticalAlignment.center
    var selected = false {
        didSet { updateColors() }
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        addSubview(device)
        device.onRename = { [weak self] in self?.onDeviceAliasChange($0, $1) }
    }
    required init?(coder: NSCoder) { nil }

    private var displayedViews: [NSView] {
        if !device.isHidden { return [device] }
        if usesOutlines { return outlines.map { $0 as NSView } }
        return usesTags ? tags.map { $0 as NSView } : labels.map { $0 as NSView }
    }
    func contentHeight(for width: CGFloat) -> CGFloat { measurement?.height(for: width) ?? 0 }
    func layoutItem(index: Int) -> RecordLineItem {
        measurement?.layoutItem(index: index) ?? .init(index: index, horizontalAlignment: horizontalAlignment,
                                                     desiredWidth: 1, minimumWidth: 1, fillsAvailable: false)
    }

    func configure(_ content: RequestLogRenderedContent, row: RecordRow, isPreview: Bool) {
        let configuration = content.configuration
        let appearance = configuration.appearance
        measurement = RecordContentMeasurement(content: content, row: row)
        field = configuration.field
        horizontalAlignment = configuration.horizontalAlignment
        verticalAlignment = configuration.verticalAlignment
        displayLines = content.displayText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let presentation = appearance.presentation.effectivePresentation
        usesTags = presentation == .roundedRectangleTag || presentation == .capsule
        usesOutlines = field != .device && presentation.isOutline
        borderColorSource = appearance.borderColorSource
        customBorderColor = appearance.borderColor?.appKitColor
        emphasizesHost = field == .url && appearance.emphasizesHost
        let status = content.text.split(whereSeparator: { $0.isWhitespace }).first.flatMap { Int($0) }
        let isError = (field == .status && status.map { $0 >= 400 } == true)
            || (field == .detail && row.failure != nil)
        font = Self.resolvedFont(appearance, field: field, emphasizesError: appearance.emphasizesErrors && isError)
        hostFont = Self.resolvedFont(appearance, field: field, emphasizesError: false, weightOverride: .semibold)
        switch appearance.truncation {
        case .automatic: truncation = field == .url ? .byTruncatingMiddle : .byTruncatingTail
        case .none: truncation = .byCharWrapping
        case .middle: truncation = .byTruncatingMiddle
        case .tail: truncation = .byTruncatingTail
        }
        switch field {
        case .time, .ruleGroup, .rules: textColor = .secondaryLabelColor
        case .duration:
            textColor = appearance.highlightsSlowRequests
                && row.durationSeconds * 1000 > Double(appearance.effectiveSlowThresholdMilliseconds)
                ? .systemOrange : .secondaryLabelColor
        case .method: textColor = appearance.usesSemanticColors ? RequestMethodLabel.color(for: content.text) : .labelColor
        case .status: textColor = appearance.usesSemanticColors ? RequestStatusStyle.color(status) : .labelColor
        case .detail: textColor = appearance.emphasizesErrors && isError ? .systemRed : .labelColor
        default: textColor = .labelColor
        }
        let title = field.needsName ? field.title + "：" + configuration.displayTitle : field.title
        let tooltip = title + (field.stages.isEmpty ? "" : " · " + configuration.stage.title) + "\n" + content.text
        synchronizeLabels(count: usesTags || usesOutlines ? 0 : displayLines.count)
        synchronizeTags(count: usesTags ? displayLines.count : 0)
        synchronizeOutlines(count: usesOutlines ? displayLines.count : 0)
        device.isHidden = true
        if field == .device, row.deviceSource != nil {
            device.update(source: row.deviceSource, alias: row.deviceAlias)
            device.bezelColor = appearance.backgroundColor?.appKitColor
            device.title = content.displayText
            device.font = font
            device.isEnabled = !isPreview
            device.isHidden = false
            device.alignment = textAlignment
            device.cell?.wraps = appearance.truncation == .none
            device.cell?.usesSingleLineMode = appearance.truncation != .none
            device.cell?.lineBreakMode = truncation
            device.setAccessibilityValue(content.text)
            for label in labels { label.isHidden = true }
            for tag in tags { tag.isHidden = true }
        } else {
            // Close any alias editor when a reused content slot changes fields.
            device.update(source: nil, alias: "")
            for (label, text) in zip(labels, displayLines) {
                label.isHidden = false
                label.stringValue = text
                label.font = font
                label.alignment = textAlignment
                label.maximumNumberOfLines = appearance.truncation == .none ? 0 : 1
                label.cell?.wraps = appearance.truncation == .none
                label.cell?.usesSingleLineMode = appearance.truncation != .none
                label.lineBreakMode = truncation
                label.toolTip = tooltip
            }
            for (tag, text) in zip(tags, displayLines) {
                tag.isHidden = false
                tag.setPresentation(presentation)
                tag.bezelColor = appearance.backgroundColor?.appKitColor
                tag.title = text
                tag.font = font
                tag.alignment = textAlignment
                tag.cell?.wraps = appearance.truncation == .none
                tag.cell?.usesSingleLineMode = appearance.truncation != .none
                tag.cell?.lineBreakMode = truncation
                tag.toolTip = tooltip
                tag.setAccessibilityLabel(title)
                tag.setAccessibilityValue(text)
            }
            for (outline, text) in zip(outlines, displayLines) {
                outline.configure(appearance)
                outline.label.stringValue = text
                outline.label.font = font
                outline.label.alignment = textAlignment
                outline.label.maximumNumberOfLines = appearance.truncation == .none ? 0 : 1
                outline.label.cell?.wraps = appearance.truncation == .none
                outline.label.cell?.usesSingleLineMode = appearance.truncation != .none
                outline.label.lineBreakMode = truncation
                outline.toolTip = tooltip
                outline.setAccessibilityLabel(title)
                outline.setAccessibilityValue(text)
            }
        }
        toolTip = tooltip
        setAccessibilityLabel(title)
        setAccessibilityValue(content.text)
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        let heights = measurement?.heights(for: bounds.width) ?? []
        for (view, height) in zip(displayedViews, heights) {
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + RecordCell.lineSpacing
        }
    }

    private var textAlignment: NSTextAlignment {
        switch horizontalAlignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }

    private func synchronizeLabels(count: Int) {
        while labels.count > count { labels.removeLast().removeFromSuperview() }
        while labels.count < count {
            let label = NSTextField(labelWithString: "")
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labels.append(label); addSubview(label)
        }
    }

    private func synchronizeTags(count: Int) {
        while tags.count > count { tags.removeLast().removeFromSuperview() }
        while tags.count < count {
            let tag = RequestLogValueTag()
            tags.append(tag); addSubview(tag)
        }
    }

    private func updateColors() {
        let color = selected ? NSColor.alternateSelectedControlTextColor : textColor
        for (label, text) in zip(labels, displayLines) {
            label.attributedStringValue = attributedText(text, color: color)
        }
        for (tag, text) in zip(tags, displayLines) {
            tag.attributedTitle = attributedText(text, color: color)
        }
        for (outline, text) in zip(outlines, displayLines) {
            outline.label.attributedStringValue = attributedText(text, color: color)
            outline.borderColor = borderColorSource == .text ? color : customBorderColor ?? .separatorColor
        }
        if !device.isHidden { device.attributedTitle = attributedText(device.title, color: color) }
    }

    private func synchronizeOutlines(count: Int) {
        while outlines.count > count { outlines.removeLast().removeFromSuperview() }
        while outlines.count < count {
            let outline = RequestLogValueOutline()
            outlines.append(outline); addSubview(outline)
        }
    }

    private func attributedText(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = truncation
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
        if emphasizesHost, let range = Self.hostRange(in: text) {
            result.addAttribute(.font, value: hostFont, range: range)
        }
        return result
    }

    fileprivate static func resolvedFont(_ appearance: RequestLogContentAppearance, field: RequestLogContentField,
                                     emphasizesError: Bool, weightOverride: NSFont.Weight? = nil) -> NSFont {
        let weight: NSFont.Weight
        if let weightOverride { weight = weightOverride }
        else if emphasizesError { weight = .semibold }
        else {
            switch appearance.weight {
            case .automatic:
                weight = field == .method || field == .status ? .medium : .regular
            case .regular: weight = .regular
            case .medium: weight = .medium
            case .semibold: weight = .semibold
            }
        }
        switch appearance.font {
        case .system: return .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
        case .monospaced: return .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: weight)
        case .automatic:
            switch field {
            case .method: return .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: weight)
            case .status, .time, .duration: return .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: weight)
            default: return .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
            }
        }
    }

    /// Locate the host inside a parsed authority, never by a substring search
    /// that could emphasize a matching hostname in the path or query instead.
    fileprivate static func hostRange(in text: String) -> NSRange? {
        guard let address = URLComponents(string: text), let scheme = address.scheme,
              let host = address.host, !host.isEmpty,
              let prefix = text.range(of: scheme + "://", options: [.anchored, .caseInsensitive]) else { return nil }
        let authorityStart = prefix.upperBound
        let authorityEnd = text[authorityStart...].firstIndex { "/?#".contains($0) } ?? text.endIndex
        var start = authorityStart
        if let at = text[start..<authorityEnd].lastIndex(of: "@") { start = text.index(after: at) }
        guard start < authorityEnd else { return nil }
        let end: String.Index
        if text[start] == "[" {
            guard let bracket = text[start..<authorityEnd].firstIndex(of: "]") else { return nil }
            end = text.index(after: bracket)
        } else {
            end = text[start..<authorityEnd].firstIndex(of: ":") ?? authorityEnd
        }
        let displayedHost = String(text[start..<end]).removingPercentEncoding ?? String(text[start..<end])
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard displayedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .caseInsensitiveCompare(normalizedHost) == .orderedSame else { return nil }
        return NSRange(start..<end, in: text)
    }
}

/// Native cells are measured without constructing a view hierarchy. The same
/// measurement and width-allocation data also drives the actual content views.
@MainActor
private struct RecordContentMeasurement {
    private struct Entry {
        let cell: NSCell
        let naturalSize: NSSize
        let insets: NSSize
    }
    private let entries: [Entry]
    private let configuration: RequestLogLayoutContent
    private let wraps: Bool
    private let isDevice: Bool

    init(content: RequestLogRenderedContent, row: RecordRow) {
        let configuration = content.configuration
        self.configuration = configuration
        let appearance = configuration.appearance
        let wraps = appearance.truncation == .none
        let isDevice = configuration.field == .device && row.deviceSource != nil
        self.wraps = wraps; self.isDevice = isDevice
        let presentation = appearance.presentation.effectivePresentation
        let insets = configuration.field != .device && presentation.isOutline ? RequestLogValueOutline.insets(for: appearance) : .zero
        let status = content.text.split(whereSeparator: { $0.isWhitespace }).first.flatMap { Int($0) }
        let isError = configuration.field == .status && status.map { $0 >= 400 } == true
            || configuration.field == .detail && row.failure != nil
        let font = RecordContentView.resolvedFont(appearance, field: configuration.field,
                                                 emphasizesError: appearance.emphasizesErrors && isError)
        let hostFont = RecordContentView.resolvedFont(appearance, field: configuration.field,
                                                     emphasizesError: false, weightOverride: .semibold)
        let lines = isDevice ? [content.displayText]
            : content.displayText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let lineBreak: NSLineBreakMode
        switch appearance.truncation {
        case .none: lineBreak = .byCharWrapping
        case .middle: lineBreak = .byTruncatingMiddle
        case .tail: lineBreak = .byTruncatingTail
        case .automatic: lineBreak = configuration.field == .url ? .byTruncatingMiddle : .byTruncatingTail
        }
        let alignment: NSTextAlignment
        switch configuration.horizontalAlignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        entries = lines.map { text in
            let cell: NSCell
            if isDevice || presentation == .capsule || presentation == .roundedRectangleTag {
                let button = RequestLogValueCell(textCell: text)
                button.bezelStyle = .accessoryBarAction
                button.controlSize = isDevice ? .small : .regular
                cell = button
            } else {
                let label = NSTextFieldCell(textCell: text)
                label.isBordered = false; label.isBezeled = false; label.drawsBackground = false
                label.isEditable = false; label.isSelectable = false
                cell = label
            }
            cell.font = font; cell.alignment = alignment
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment; paragraph.lineBreakMode = lineBreak
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: font, .paragraphStyle: paragraph
            ])
            if configuration.field == .url, appearance.emphasizesHost,
               let range = RecordContentView.hostRange(in: text) {
                attributed.addAttribute(.font, value: hostFont, range: range)
            }
            if let button = cell as? NSButtonCell { button.attributedTitle = attributed }
            else { cell.attributedStringValue = attributed }
            cell.wraps = false; cell.usesSingleLineMode = true
            let textSize = cell.cellSize
            let natural = NSSize(width: textSize.width + insets.width * 2, height: textSize.height + insets.height * 2)
            cell.wraps = wraps; cell.usesSingleLineMode = !wraps
            cell.lineBreakMode = lineBreak
            return Entry(cell: cell, naturalSize: natural, insets: insets)
        }
    }

    func layoutItem(index: Int) -> RecordLineItem {
        let desired = max(1, entries.map { ceil($0.naturalSize.width) }.max() ?? 1)
        let compact = [.method, .status, .time, .duration].contains(configuration.field)
        let padding = entries.first.map { $0.insets.width * 2 } ?? 0
        let minimum = wraps ? min(desired, padding + 1) : min(desired, compact ? desired : configuration.field == .url ? 72 : 40)
        let presentation = configuration.appearance.presentation.effectivePresentation
        return .init(index: index, horizontalAlignment: configuration.horizontalAlignment,
                     desiredWidth: desired, minimumWidth: minimum,
                     fillsAvailable: !isDevice && presentation == .plainText && (!compact || wraps))
    }

    func heights(for width: CGFloat) -> [CGFloat] {
        entries.map { entry in
            let size = wraps ? entry.cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width - entry.insets.width * 2),
                                                                     height: .greatestFiniteMagnitude))
                : entry.naturalSize
            let height = wraps ? size.height + entry.insets.height * 2 : size.height
            return max(1, ceil(max(entry.naturalSize.height, height)))
        }
    }

    func height(for width: CGFloat) -> CGFloat {
        let heights = heights(for: width)
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * RecordCell.lineSpacing
    }
}

/// Read-only outlined content uses NSBox's native line border and a native label.
@MainActor
private final class RequestLogValueOutline: NSBox {
    let label = NSTextField(labelWithString: "")
    private var capsule = false
    private var textInsets = NSSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        boxType = .custom; borderType = .lineBorder; titlePosition = .noTitle
        contentViewMargins = .zero; fillColor = .clear; isTransparent = false
        contentView = label
        label.setAccessibilityElement(false)
        setAccessibilityRole(.staticText)
        clipsToBounds = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    static func insets(for appearance: RequestLogContentAppearance) -> NSSize {
        let width = CGFloat(appearance.effectiveBorderWidth)
        return NSSize(width: width + 4, height: width + 2)
    }

    func configure(_ appearance: RequestLogContentAppearance) {
        capsule = appearance.presentation == .capsuleBorder
        borderWidth = CGFloat(appearance.effectiveBorderWidth)
        textInsets = Self.insets(for: appearance)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let maximumRadius = max(0, min(bounds.width, bounds.height) / 2)
        let radius = capsule ? maximumRadius : min(6, maximumRadius)
        if cornerRadius != radius { cornerRadius = radius }
        let horizontal = min(textInsets.width, max(0, bounds.width - 1) / 2)
        let vertical = min(textInsets.height, max(0, bounds.height - 1) / 2)
        label.frame = bounds.insetBy(dx: horizontal, dy: vertical)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Adjust title layout and sizing while AppKit continues to render the native bezel.
@MainActor
private final class RequestLogValueCell: NSButtonCell {
    private var measuringNativeSize = false

    private var paddingAdjustment: NSSize {
        NSSize(width: -4, height: -1)
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: contentBounds(frame), in: controlView)
    }

    override var cellSize: NSSize {
        guard !measuringNativeSize else { return super.cellSize }
        measuringNativeSize = true
        defer { measuringNativeSize = false }
        return adjustedSize(super.cellSize)
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        guard !measuringNativeSize else { return super.cellSize(forBounds: rect) }
        let bounds = contentBounds(rect)
        measuringNativeSize = true
        defer { measuringNativeSize = false }
        return adjustedSize(super.cellSize(forBounds: bounds))
    }

    private func contentBounds(_ rect: NSRect) -> NSRect {
        let padding = paddingAdjustment
        // Tiny columns still receive a valid text rectangle.
        let horizontal = min(padding.width, max(0, rect.width - 1) / 2)
        let vertical = min(padding.height, max(0, rect.height - 1) / 2)
        return rect.insetBy(dx: horizontal, dy: vertical)
    }

    private func adjustedSize(_ size: NSSize) -> NSSize {
        let padding = paddingAdjustment
        return NSSize(width: max(1, size.width + padding.width * 2),
                      height: max(1, size.height + padding.height * 2))
    }
}

/// Native tag appearance, with the log table retaining selection and actions.
@MainActor
private final class RequestLogValueTag: NSButton {
    init(presentation: RequestLogContentPresentation = .roundedRectangleTag) {
        super.init(frame: .zero)
        cell = RequestLogValueCell(textCell: "")
        setPresentation(presentation)
        target = nil; action = nil
        setAccessibilityRole(.staticText)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    func setPresentation(_ presentation: RequestLogContentPresentation) {
        let capsule = presentation.effectivePresentation == .capsule
        // Share native metrics and colors; only the border shape changes.
        bezelStyle = .accessoryBarAction
        if #available(macOS 26.0, *) { borderShape = capsule ? .capsule : .roundedRectangle }
        invalidateIntrinsicContentSize()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityPerformPress() -> Bool { false }
}

@MainActor
enum RequestStatusStyle {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    static func color(_ status: Int?) -> NSColor {
        switch status {
        case .some(100..<200): .systemBlue
        case .some(200..<300): .systemGreen
        case .some(300..<400): .systemOrange
        case .some(400..<600): .systemRed
        default: .secondaryLabelColor
        }
    }
}

@MainActor
final class RequestMethodLabel: NSTextField {
    static let methodFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false; isSelectable = false; isBezeled = false; isBordered = false; drawsBackground = false
        font = Self.methodFont
        maximumNumberOfLines = 1
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
    }
    required init?(coder: NSCoder) { return nil }
    func setMethod(_ method: String) {
        stringValue = method
        textColor = Self.color(for: method)
        toolTip = method
        setAccessibilityLabel("请求方法")
        setAccessibilityValue(method)
    }

    static func color(for method: String) -> NSColor {
        switch method.uppercased() {
        case "POST": .systemOrange
        case "PUT", "PATCH": .systemPurple
        case "DELETE": .systemRed
        case "HEAD", "OPTIONS": .secondaryLabelColor
        default: .systemBlue
        }
    }
}

/// Both log cells and Inspector resolve names from the same workspace alias registry.
@MainActor
final class DeviceSourceButton: NSButton {
    var onRename: (String, String) -> Void = { _, _ in }
    private var source: String?
    private var alias = ""
    private(set) var popover: NSPopover?
    init(usesGlass: Bool = true) {
        super.init(frame: .zero)
        if !usesGlass { cell = RequestLogValueCell(textCell: "") }
        if #available(macOS 26.0, *) {
            bezelStyle = usesGlass ? .glass : .accessoryBarAction
            borderShape = .capsule
        } else { bezelStyle = usesGlass ? .badge : .accessoryBarAction }
        controlSize = .small
        alignment = .left
        cell?.lineBreakMode = .byTruncatingTail
        target = self; action = #selector(editAlias)
        setAccessibilityLabel("设备来源")
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    func update(source: String?, alias: String) {
        if self.source != source { popover?.close(); popover = nil }
        self.source = source; self.alias = alias
        title = DeviceSource.title(source, aliases: source.map { [$0: alias] } ?? [:])
        isEnabled = source != nil
        toolTip = source.map { ($0 == "local" ? "本机回环连接" : $0) + " · 点击设置别名" } ?? "此日志未记录设备来源"
        setAccessibilityValue(title)
    }
    @objc private func editAlias() {
        guard let source else { return }
        if let popover, popover.isShown { popover.performClose(nil); return }
        let popover = NSPopover()
        popover.behavior = .transient
        let editor = DeviceAliasViewController(source: source, alias: alias) { [weak self, weak popover] value in
            self?.onRename(source, value)
            popover?.performClose(nil)
        }
        popover.contentViewController = editor
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

@MainActor
final class DeviceAliasViewController: NSViewController {
    private let source: String
    private let field: ActionTextField
    private let save: (String) -> Void
    init(source: String, alias: String, save: @escaping (String) -> Void) {
        self.source = source; self.save = save
        field = ActionTextField(alias, placeholder: "例如：我的 iPhone")
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        field.setAccessibilityLabel("设备别名")
        field.onSubmit = { [weak self] in self?.submit() }
        let saveButton = ActionButton(title: "保存") { [weak self] in self?.submit() }
        let clear = ActionButton(title: "清除别名") { [weak self] in self?.save("") }
        let sourceLabel = NativeUI.label(source == "local" ? "本机回环连接" : source, size: 12, secondary: true)
        sourceLabel.isSelectable = true
        let note = NSTextField(wrappingLabelWithString: "同一来源的所有日志会统一更新。局域网设备按 IP 识别，IP 改变后需重新设置。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let stack = NativeUI.stack([NativeUI.label("设备别名", size: 14, weight: .semibold), sourceLabel, field, note,
                                   NativeUI.stack([clear, NSView(), saveButton], vertical: false)], spacing: 10)
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        note.widthAnchor.constraint(equalToConstant: 280).isActive = true
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        preferredContentSize = NSSize(width: 312, height: 200)
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(field) }
    private func submit() {
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        save(String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
    }
}
