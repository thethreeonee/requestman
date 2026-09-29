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

    init(columnDefaults: UserDefaults = .standard) {
        coordinator = Coordinator(defaults: columnDefaults)
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
        table.menuForRow = { [weak coordinator = coordinator] in coordinator?.menu(forRow: $0) }
        table.rowHeight = 56
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        table.setAccessibilityLabel("请求日志")
        for column in RecordColumn.allCases {
            let item = RecordsTableColumn(identifier: column.identifier)
            if column == .time || column == .duration {
                item.headerCell = RecordsEdgeHeaderCell(textCell: column.title)
            }
            item.title = column.title
            item.minWidth = 0
            item.maxWidth = .greatestFiniteMagnitude
            item.resizingMask = .userResizingMask
            item.isEditable = false
            item.isHidden = column == .device
            item.headerCell.alignment = column == .duration ? .right : .left
            table.addTableColumn(item)
            item.widthChanged = { [weak coordinator = coordinator] column in
                coordinator?.resizeColumn(column)
            }
        }
        table.dataSource = coordinator
        table.delegate = coordinator
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
        private var preferredWidths: [String: CGFloat] = [:]
        private var availableWidth: CGFloat = 0
        private var requiredRequestWidth: CGFloat = 0
        private var fittedRequestWidth: CGFloat = -1
        private var applyingWidths = false
        private var displayOptions = RequestLogDisplayOptions()
        private var lastAllowLAN: Bool?
        private var configuringColumns = false
        private var displayOptionsChanged = false

        init(defaults: UserDefaults) {
            self.defaults = defaults
            super.init()
            reloadPreferences()
            NotificationCenter.default.addObserver(self, selector: #selector(preferencesRestored),
                                                   name: .init("Requestman.preferencesRestored"), object: nil)
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
            let methodWidth = displayOptions.showsMethod
                ? (Set(nextRows.map(\.method)).map { RequestMethodTag.requiredWidth(for: $0) }.max() ?? 0) + 8 : 0
            let statusWidth = displayOptions.columns.contains(.status)
                ? RequestMethodTag.requiredWidth(for: "599", font: RequestMethodTag.statusFont) + 8 : 0
            requiredRequestWidth = methodWidth + statusWidth + 24
            updating = true
            defer { updating = false }

            if displayOptionsChanged {
                rows = nextRows
                table.reloadData()
                displayOptionsChanged = false
            }
            if nextRows != rows {
                let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
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
                    !inserted.contains($0) && previous[rows[$0].id] != rows[$0]
                })
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: table.tableColumns.indices))
                }
            }

            let selectedRow = selection.flatMap { id in rows.firstIndex { $0.id == id } }
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
            for extra in options.extraColumns where table.tableColumn(withIdentifier: .init(extra.identifier)) == nil {
                let item = RecordsTableColumn(identifier: .init(extra.identifier))
                item.minWidth = 0; item.maxWidth = .greatestFiniteMagnitude
                item.resizingMask = .userResizingMask; item.isEditable = false
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
                item.isHidden = !options.isColumnVisible(id, allowLAN: allowLAN)
                item.headerToolTip = options.extraColumns.first(where: { $0.identifier == id })?.summary
            }
            availableWidth = 0
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard !configuringColumns, let table else { return }
            let order = table.tableColumns.map { $0.identifier.rawValue }
            displayOptions.columnOrder = order
            onColumnOrderChange(order)
        }

        private var visibleColumnIndexes: [Int] {
            guard let table else { return [] }
            return table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        }

        func fitColumns(to width: CGFloat) {
            guard let table, !configuringColumns, width > 0,
                  abs(width - availableWidth) > 0.1 || requiredRequestWidth != fittedRequestWidth else { return }
            availableWidth = width
            fittedRequestWidth = requiredRequestWidth
            // Record updates never overwrite a manual resize. Only viewport changes
            // adapt the saved proportions, without persisting the temporary layout.
            let compactScale = min(1, width / 900)
            let time: CGFloat = max(60, 104 * compactScale)
            let status: CGFloat = max(48, 76 * compactScale)
            let duration: CGFloat = max(64, 92 * compactScale)
            let flexible = max(0, width - time - status - duration)
            let weights = table.tableColumns.map { column -> CGFloat in
                if let preferred = preferredWidths[column.identifier.rawValue] { return preferred }
                switch RecordColumn(rawValue: column.identifier.rawValue) {
                case .time: return time
                case .status: return status
                case .duration: return duration
                case .request: return max(1, flexible * 0.52)
                case .rules: return max(1, flexible * 0.36)
                case .device: return max(1, flexible * 0.12)
                case nil: return max(1, flexible * 0.22)
                }
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
                switch RecordColumn(rawValue: column.identifier.rawValue) {
                case .time: return 60
                case .status, .device: return 48
                case .request: return 120
                case .duration: return 64
                case .rules, nil: return 80
                }
            }
            let scale = min(1, availableWidth / max(1, widths.reduce(0, +) * 1.5))
            var minimums = widths.map { $0 * scale }
            if let index = table.tableColumns.firstIndex(where: { $0.identifier == RecordColumn.request.identifier }),
               !table.tableColumns[index].isHidden {
                let otherMinimums = minimums.reduce(0, +) - minimums[index]
                minimums[index] = min(max(minimums[index], requiredRequestWidth), max(0, availableWidth - otherMinimums))
            }
            return minimums
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
        }

        func resizeColumn(_ column: NSTableColumn) {
            guard !applyingWidths, !column.isHidden, availableWidth > 0, let table,
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
            guard !applyingWidths, !configuringColumns, let table else { return }
            for column in table.tableColumns where !column.isHidden {
                preferredWidths[column.identifier.rawValue] = column.width
            }
            defaults.set(preferredWidths.mapValues(Double.init), forKey: RequestRecordsTable.columnWidthsKey)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func menu(forRow row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
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
            guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
            let column = RecordColumn(rawValue: identifier.rawValue)
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? RecordCell)
                ?? RecordCell(column: column, identifier: identifier)
            cell.device.onRename = { [weak self] in self?.onDeviceAliasChange($0, $1) }
            cell.configure(rows[row], options: displayOptions)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            if selection != selected { selection = selected; onSelectionChange(selected) }
        }
    }
}

@MainActor
private final class RecordsTableView: NSTableView {
    var menuForRow: (Int) -> NSMenu? = { _ in nil }

    override func menu(for event: NSEvent) -> NSMenu? {
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

@MainActor
private final class RecordsEdgeHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Inset only the title; AppKit still draws the full header and resize borders.
        let inset = min(12, cellFrame.width / 2)
        super.drawInterior(withFrame: cellFrame.insetBy(dx: inset, dy: 0), in: controlView)
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
    let device = DeviceSourceButton()
    private let column: RecordColumn?
    private let primary = NSTextField(labelWithString: "")
    private let methodTag = RequestMethodTag()
    private let statusTag = RequestMethodTag()
    private var tags: [RequestMethodTag] = []
    private var primaryColor = NSColor.labelColor

    init(column: RecordColumn?, identifier: NSUserInterfaceItemIdentifier) {
        self.column = column
        super.init(frame: .zero)
        self.identifier = identifier
        primary.maximumNumberOfLines = 1
        primary.lineBreakMode = column == .request ? .byTruncatingMiddle : .byTruncatingTail
        primary.cell?.usesSingleLineMode = true
        primary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primary.font = .systemFont(ofSize: 13)
        addSubview(primary)
        if column == .request { addSubview(statusTag); addSubview(methodTag) }
        if column == .duration { primary.alignment = .right }
        if column == .time || column == .duration {
            primary.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        }
        if column == .device { addSubview(device) }
        textField = primary
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func configure(_ row: RecordRow, options: RequestLogDisplayOptions) {
        primaryColor = .labelColor
        primary.isHidden = column == .device
        var badges: [(value: String, tint: NSColor, tooltip: String)] = []
        func append(_ value: String, tint: NSColor = .secondaryLabelColor, tooltip: String? = nil) {
            badges.append((value.replacingOccurrences(of: "\n", with: " · "), tint, tooltip ?? value))
        }
        switch column {
        case .time:
            primary.stringValue = row.time
            primaryColor = .secondaryLabelColor
        case .status:
            primary.stringValue = ""
        case .request:
            let showsURL = options.columns.contains(.request)
            primary.stringValue = showsURL ? row.url : ""
            primary.isHidden = !showsURL
            methodTag.isHidden = !options.showsMethod
            methodTag.setMethod(row.method)
            statusTag.isHidden = !options.columns.contains(.status)
            statusTag.setStatus(row.status)
            if showsURL, let detail = row.replay ?? row.failure {
                append(detail, tint: row.failure == nil ? .secondaryLabelColor : .systemRed)
            }
        case .rules:
            primary.stringValue = row.project
            primaryColor = .secondaryLabelColor
            if let workflow = row.workflow { append(workflow) }
        case nil:
            primary.stringValue = (row.extraValues[identifier?.rawValue ?? ""] ?? "—")
                .replacingOccurrences(of: "\n", with: " · ")
        case .device:
            device.update(source: row.deviceSource, alias: row.deviceAlias)
            primary.stringValue = device.title
        case .duration:
            primary.stringValue = row.duration
            primaryColor = .secondaryLabelColor
        }
        for field in options.mergedFields(in: identifier?.rawValue ?? "") {
            let value = row.extraValues[field.identifier] ?? "—"
            let tint = field.field == .status ? RequestStatusStyle.color(Int(value)) : NSColor.secondaryLabelColor
            append(value, tint: tint, tooltip: field.displayTitle + " · " + field.stage.title + "\n" + value)
        }
        while tags.count > badges.count { tags.removeLast().removeFromSuperview() }
        while tags.count < badges.count {
            let tag = RequestMethodTag(); tags.append(tag); addSubview(tag)
        }
        for (tag, badge) in zip(tags, badges) {
            tag.setTag(badge.value, tint: badge.tint, tooltip: badge.tooltip)
        }
        primary.toolTip = column == nil ? row.extraValues[identifier?.rawValue ?? ""] : primary.stringValue
        var details = primary.isHidden ? [] : [primary.toolTip ?? primary.stringValue]
        if column == .device { details = [device.title] }
        if column == .request {
            var firstLine: [String] = []
            if !statusTag.isHidden { firstLine.append(row.status.map(String.init) ?? "—") }
            if !methodTag.isHidden { firstLine.append(row.method) }
            if !primary.isHidden { firstLine.append(row.url) }
            details = [firstLine.joined(separator: " ")]
            if !primary.isHidden { details.append(row.result) }
        }
        if column == .rules && row.workflow == nil { details.append("未命中规则") }
        details += badges.map(\.tooltip)
        toolTip = details.joined(separator: "\n")
        setAccessibilityLabel(options.title(forColumnID: identifier?.rawValue ?? ""))
        setAccessibilityValue(toolTip)
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = min(12, bounds.width / 2)
        let width = max(0, bounds.width - inset * 2)
        let top = tags.isEmpty ? (bounds.height - 24) / 2 : 4
        if column == .device {
            device.frame = NSRect(x: inset, y: top, width: width, height: 24)
        }
        if column == .request {
            var textX = inset
            for tag in [statusTag, methodTag] where !tag.isHidden {
                let available = max(0, inset + width - textX)
                let tagWidth = min(available, tag.intrinsicContentSize.width)
                tag.frame = NSRect(x: textX, y: top, width: tagWidth, height: 24)
                textX += tagWidth + min(8, max(0, available - tagWidth))
            }
            primary.frame = NSRect(x: textX, y: top + 2, width: max(0, inset + width - textX), height: 20)
        } else {
            primary.frame = NSRect(x: inset, y: top + 2, width: width, height: 20)
        }
        // Keep every secondary value on the same line; truncate within each tag when space is limited.
        let gap = tags.count > 1 ? min(6, width / CGFloat(tags.count * 2)) : 0
        let space = max(0, width - gap * CGFloat(max(0, tags.count - 1)))
        let desired = tags.map { $0.intrinsicContentSize.width }
        let total = desired.reduce(0, +)
        let minimum = min(36, space / CGFloat(max(1, tags.count)))
        let flexible = desired.reduce(CGFloat.zero) { $0 + max(0, $1 - minimum) }
        var x = inset
        for (tag, desiredWidth) in zip(tags, desired) {
            let tagWidth = total <= space ? desiredWidth
                : minimum + max(0, space - minimum * CGFloat(tags.count)) * max(0, desiredWidth - minimum) / max(1, flexible)
            tag.frame = NSRect(x: x, y: 30, width: tagWidth, height: 22)
            x += tagWidth + gap
        }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        primary.textColor = selected ? .alternateSelectedControlTextColor : primaryColor
        statusTag.selected = selected
        methodTag.selected = selected
        for tag in tags { tag.selected = selected }
    }
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
final class RequestMethodTag: NSView {
    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)

    static func requiredWidth(for method: String, font: NSFont = font) -> CGFloat {
        let cell = NSTextFieldCell(textCell: method)
        cell.font = font
        cell.isBordered = false
        cell.usesSingleLineMode = true
        cell.alignment = .center
        cell.lineBreakMode = .byTruncatingTail
        return ceil(cell.cellSize.width) + 12
    }

    private let label = NSTextField(labelWithString: "")
    private var tint = NSColor.systemBlue
    private var usesNeutralText = false
    private var isSubdued = false
    var selected = false {
        didSet { updateColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Self.font
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { return nil }

    func setMethod(_ method: String) {
        usesNeutralText = false
        isSubdued = false
        label.font = Self.font
        label.stringValue = method
        toolTip = method
        label.toolTip = method
        switch method.uppercased() {
        case "POST": tint = .systemOrange
        case "PUT", "PATCH": tint = .systemPurple
        case "DELETE": tint = .systemRed
        case "HEAD", "OPTIONS": tint = .secondaryLabelColor
        default: tint = .systemBlue
        }
        invalidateIntrinsicContentSize()
        updateColor()
    }

    func setStatus(_ status: Int?) {
        setTag(status.map(String.init) ?? "—", tint: RequestStatusStyle.color(status),
               tooltip: "状态码：" + (status.map(String.init) ?? "—"))
        label.font = Self.statusFont
        usesNeutralText = false
        isSubdued = false
        invalidateIntrinsicContentSize()
        updateColor()
    }

    func setTag(_ value: String, tint: NSColor, tooltip: String) {
        label.stringValue = value
        self.tint = tint
        usesNeutralText = true
        isSubdued = true
        label.font = Self.font
        toolTip = tooltip; label.toolTip = tooltip
        setAccessibilityLabel(tooltip)
        invalidateIntrinsicContentSize()
        updateColor()
    }

    override var intrinsicContentSize: NSSize {
        // Match the drawing cell: NSTextField's intrinsic width can omit truncation padding.
        NSSize(width: Self.requiredWidth(for: label.stringValue, font: label.font ?? Self.font), height: 24)
    }

    override func layout() {
        super.layout()
        let textHeight = min(label.intrinsicContentSize.height, bounds.height)
        label.frame = NSRect(x: min(6, bounds.width / 2), y: (bounds.height - textHeight) / 2,
                             width: max(0, bounds.width - 12), height: textHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let color: NSColor = selected && !usesNeutralText ? .alternateSelectedControlTextColor : tint
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        color.withAlphaComponent(isSubdued ? (selected ? 0.08 : 0.04) : (selected ? 0.18 : 0.10)).setFill()
        path.fill()
        color.withAlphaComponent(isSubdued ? (selected ? 0.25 : 0.16) : (selected ? 0.65 : 0.45)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        label.textColor = selected ? .alternateSelectedControlTextColor : (usesNeutralText ? .labelColor : tint)
        needsDisplay = true
    }
}

/// Both log cells and Inspector resolve names from the same workspace alias registry.
@MainActor
final class DeviceSourceButton: NSButton {
    var onRename: (String, String) -> Void = { _, _ in }
    private var source: String?
    private var alias = ""
    private(set) var popover: NSPopover?
    init() {
        super.init(frame: .zero)
        bezelStyle = .inline
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
