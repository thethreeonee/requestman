import AppKit
import RequestmanCore

@MainActor
final class RequestRecordsTable: NSView {
    static let columnWidthsKey = "requestLog.columnWidths.v1"
    var onSelectionChange: (UUID?) -> Void = { _ in }
    private let coordinator: Coordinator
    private let scrollView: NSScrollView

    init(columnDefaults: UserDefaults = .standard) {
        coordinator = Coordinator(defaults: columnDefaults)
        scrollView = RecordsScrollView()
        super.init(frame: .zero)
        coordinator.onSelectionChange = { [weak self] in self?.onSelectionChange($0) }
        configure()
    }
    required init?(coder: NSCoder) { nil }

    private func configure() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder

        let table = NSTableView()
        table.rowHeight = 56
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        table.setAccessibilityLabel("请求日志")
        for column in RecordColumn.allCases {
            let item = RecordsTableColumn(identifier: column.identifier)
            item.title = column.title
            item.minWidth = 0
            item.maxWidth = .greatestFiniteMagnitude
            item.resizingMask = .userResizingMask
            item.isEditable = false
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

    func update(records: [CaptureRecord], selectedID: UUID?) {
        coordinator.selection = selectedID
        coordinator.update(records: records)
        coordinator.fitColumns(to: scrollView.contentView.bounds.width)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selection: UUID?
        var onSelectionChange: (UUID?) -> Void = { _ in }
        weak var table: NSTableView?
        private var rows: [RecordRow] = []
        private var updating = false
        private let defaults: UserDefaults
        private var preferredWidths: [CGFloat]?
        private var availableWidth: CGFloat = 0
        private var applyingWidths = false
        private let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        init(defaults: UserDefaults) {
            self.defaults = defaults
            if let saved = defaults.dictionary(forKey: RequestRecordsTable.columnWidthsKey) {
                let widths = RecordColumn.allCases.compactMap { column -> CGFloat? in
                    guard let value = saved[column.rawValue] as? Double,
                          value.isFinite, value > 0, value < 100_000 else { return nil }
                    return CGFloat(value)
                }
                if widths.count == RecordColumn.allCases.count { preferredWidths = widths }
            }
        }

        func update(records: [CaptureRecord]) {
            guard let table else { return }
            let nextRows = records.map { RecordRow(record: $0, timeFormatter: timeFormatter) }
            updating = true
            defer { updating = false }

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
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: RecordColumn.allCases.indices))
                }
            }

            let selectedRow = selection.flatMap { id in rows.firstIndex { $0.id == id } }
            let indexes = selectedRow.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
        }

        func fitColumns(to width: CGFloat) {
            guard table != nil, width > 0, abs(width - availableWidth) > 0.1 else { return }
            availableWidth = width
            // Record updates never overwrite a manual resize. Only viewport changes
            // adapt the saved proportions, without persisting the temporary layout.
            let compactScale = min(1, width / 900)
            let time: CGFloat = max(60, 104 * compactScale)
            let status: CGFloat = max(48, 76 * compactScale)
            let duration: CGFloat = max(64, 92 * compactScale)
            let flexible = max(0, width - time - status - duration)
            let initial = [time, status, flexible * 0.40, flexible * 0.30,
                           flexible * 0.18, flexible * 0.12, duration]
            let weights = preferredWidths ?? initial
            let minimums = minimumWidths
            var widths = Array(repeating: CGFloat.zero, count: weights.count)
            var remaining = Array(weights.indices)
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
            let widths: [CGFloat] = [60, 48, 120, 80, 60, 48, 64]
            let scale = min(1, availableWidth / (widths.reduce(0, +) * 1.5))
            return widths.map { $0 * scale }
        }

        private func apply(_ widths: [CGFloat]) {
            guard let table else { return }
            applyingWidths = true
            defer { applyingWidths = false }
            let minimums = minimumWidths
            let minimumTotal = minimums.reduce(0, +)
            for (index, column) in table.tableColumns.enumerated() {
                column.minWidth = minimums[index]
                column.maxWidth = availableWidth - minimumTotal + minimums[index]
                column.width = widths[index]
            }
            table.setFrameSize(NSSize(width: availableWidth, height: table.frame.height))
        }

        func resizeColumn(_ column: NSTableColumn) {
            guard !applyingWidths, availableWidth > 0, let table,
                  let index = table.tableColumns.firstIndex(of: column) else { return }
            var widths = table.tableColumns.map(\.width)
            let minimums = minimumWidths
            // Borrow space from the next columns, then the preceding columns.
            // The dragged column keeps its width and the table remains viewport-wide.
            let neighbors = Array(widths.indices.dropFirst(index + 1)) + Array((0..<index).reversed())
            var excess = widths.reduce(0, +) - availableWidth
            for neighbor in neighbors where excess > 0 {
                let reduction = min(excess, max(0, widths[neighbor] - minimums[neighbor]))
                widths[neighbor] -= reduction
                excess -= reduction
            }
            if excess < 0, let neighbor = neighbors.first { widths[neighbor] -= excess }
            apply(widths)
            preferredWidths = widths
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !applyingWidths, let table else { return }
            // AppKit sends this notification when tracking ends. Live layout is
            // handled by the column's width setter; persist only the final widths.
            let widths = table.tableColumns.map(\.width)
            defaults.set(Dictionary(uniqueKeysWithValues: zip(RecordColumn.allCases, widths).map {
                ($0.0.rawValue, Double($0.1))
            }), forKey: RequestRecordsTable.columnWidthsKey)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let identifier = tableColumn?.identifier,
                  let column = RecordColumn(rawValue: identifier.rawValue) else { return nil }
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? RecordCell)
                ?? RecordCell(column: column)
            cell.configure(rows[row])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            if selection != selected { selection = selected; onSelectionChange(selected) }
        }
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

private enum RecordColumn: String, CaseIterable {
    case time, status, request, rules, project, environment, duration
    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    var title: String {
        switch self {
        case .time: "时间"
        case .status: "状态码"
        case .request: "请求"
        case .rules: "命中的规则"
        case .project: "项目"
        case .environment: "环境"
        case .duration: "耗时"
        }
    }
}

private struct RecordRow: Equatable {
    let id: UUID
    let time: String
    let method: String
    let url: String
    let project: String
    let rules: [String]
    let environment: String
    let status: Int?
    let duration: String
    let result: String
    let failure: String?

    init(record: CaptureRecord, timeFormatter: DateFormatter) {
        id = record.id
        time = timeFormatter.string(from: record.startedAt)
        method = record.method
        url = record.url
        project = record.project
        rules = record.matchedRules.map(\.summary)
        environment = record.environment
        status = record.status
        let seconds = max(0, record.duration)
        duration = seconds >= 1 ? String(format: "%.1f s", seconds) : String(format: "%.0f ms", seconds * 1000)
        result = record.error.map { "\(record.outcome.rawValue) · \($0)" } ?? record.outcome.rawValue
        failure = record.error ?? (record.outcome == .failed ? record.outcome.rawValue : nil)
    }
}

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
    private let column: RecordColumn
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let methodTag = RequestMethodTag()
    private let moreRules = NSButton(title: "", target: nil, action: nil)
    private var ruleSummaries: [String] = []
    private var rulesPopover: NSPopover?
    private var primaryColor = NSColor.labelColor
    private var secondaryColor = NSColor.secondaryLabelColor

    init(column: RecordColumn) {
        self.column = column
        super.init(frame: .zero)
        identifier = column.identifier
        for label in [primary, secondary] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        primary.font = .systemFont(ofSize: 13)
        secondary.font = .systemFont(ofSize: 12)
        secondary.isHidden = column != .request && column != .rules
        if column == .request {
            primary.lineBreakMode = .byTruncatingMiddle
            addSubview(methodTag)
        }
        if column == .rules {
            moreRules.bezelStyle = .inline
            moreRules.target = self
            moreRules.action = #selector(showRules(_:))
            moreRules.isHidden = true
            moreRules.setAccessibilityLabel("查看全部命中规则")
            addSubview(moreRules)
        }
        if column == .duration { primary.alignment = .right }
        if column == .time || column == .status || column == .duration {
            primary.font = .monospacedDigitSystemFont(ofSize: 13, weight: column == .status ? .medium : .regular)
        }
        textField = primary
    }

    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func configure(_ row: RecordRow) {
        primaryColor = .labelColor
        secondaryColor = .secondaryLabelColor
        switch column {
        case .time:
            primary.stringValue = row.time
            primaryColor = .secondaryLabelColor
        case .status:
            primary.stringValue = row.status.map(String.init) ?? "—"
            primaryColor = Self.statusColor(row.status)
        case .request:
            primary.stringValue = row.url
            secondary.stringValue = row.failure ?? ""
            secondary.isHidden = row.failure == nil
            secondaryColor = .systemRed
            methodTag.setMethod(row.method)
        case .rules:
            if ruleSummaries != row.rules { rulesPopover?.close() }
            ruleSummaries = row.rules
            primary.stringValue = row.rules.first ?? "—"
            secondary.stringValue = row.rules.dropFirst().first ?? ""
            secondary.isHidden = row.rules.count < 2
            moreRules.isHidden = row.rules.count <= 2
            moreRules.title = "+\(max(0, row.rules.count - 2))"
        case .project:
            primary.stringValue = row.project
        case .environment:
            primary.stringValue = row.environment
        case .duration:
            primary.stringValue = row.duration
            primaryColor = .secondaryLabelColor
        }
        primary.toolTip = primary.stringValue
        secondary.toolTip = secondary.stringValue
        toolTip = column == .request
            ? "\(row.method) \(row.url)\n\(row.result)"
            : (secondary.isHidden ? primary.stringValue : "\(primary.stringValue)\n\(secondary.stringValue)")
        if column == .rules {
            toolTip = row.rules.isEmpty ? "未命中规则" : row.rules.joined(separator: "\n")
            setAccessibilityLabel("命中的规则")
            setAccessibilityValue(toolTip)
        }
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = min(12, bounds.width / 2)
        let width = max(0, bounds.width - inset * 2)
        let lineHeight: CGFloat = 20
        if column == .request {
            let tagWidth = min(methodTag.intrinsicContentSize.width, width * 0.45)
            let gap = min(10, max(0, width - tagWidth))
            let top = secondary.isHidden ? (bounds.height - 24) / 2 : 6
            methodTag.frame = NSRect(x: inset, y: top, width: tagWidth, height: 24)
            let textX = inset + tagWidth + gap
            let textWidth = max(0, width - tagWidth - gap)
            primary.frame = NSRect(x: textX, y: top + 2, width: textWidth, height: lineHeight)
            secondary.frame = NSRect(x: textX, y: 32, width: textWidth, height: 18)
        } else if column == .rules && !secondary.isHidden {
            let moreWidth: CGFloat = moreRules.isHidden ? 0 : min(34, width)
            primary.frame = NSRect(x: inset, y: 7, width: width, height: lineHeight)
            secondary.frame = NSRect(x: inset, y: 30, width: max(0, width - moreWidth), height: lineHeight)
            moreRules.frame = NSRect(x: bounds.width - inset - moreWidth, y: 29, width: moreWidth, height: 22)
        } else {
            primary.frame = NSRect(x: inset, y: (bounds.height - lineHeight) / 2, width: width, height: lineHeight)
        }
    }

    @objc private func showRules(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = NSTextView()
        text.isEditable = false
        text.isRichText = false
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.string = (["命中的规则"] + ruleSummaries).joined(separator: "\n\n")
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        controller.view = scroll
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: min(360, CGFloat(ruleSummaries.count) * 32 + 60))
        rulesPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        primary.textColor = selected ? .alternateSelectedControlTextColor : primaryColor
        secondary.textColor = selected ? .alternateSelectedControlTextColor : secondaryColor
        methodTag.selected = selected
        if column == .rules {
            for label in [primary, secondary] {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let value = NSMutableAttributedString(string: label.stringValue, attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
                    .paragraphStyle: paragraph
                ])
                if let separator = label.stringValue.range(of: " · ") {
                    let range = NSRange(label.stringValue.startIndex..<separator.upperBound, in: label.stringValue)
                    value.addAttribute(.foregroundColor,
                        value: selected ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor,
                        range: range)
                }
                label.attributedStringValue = value
            }
        }
    }

    private static func statusColor(_ status: Int?) -> NSColor {
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
private final class RequestMethodTag: NSView {
    private let label = NSTextField(labelWithString: "")
    private var tint = NSColor.systemBlue
    var selected = false {
        didSet { updateColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { return nil }

    func setMethod(_ method: String) {
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: min(90, max(72, label.intrinsicContentSize.width + 18)), height: 24)
    }

    override func layout() {
        super.layout()
        let textHeight = min(label.intrinsicContentSize.height, bounds.height)
        label.frame = NSRect(x: min(6, bounds.width / 2), y: (bounds.height - textHeight) / 2,
                             width: max(0, bounds.width - 12), height: textHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = selected ? .alternateSelectedControlTextColor : tint
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        color.withAlphaComponent(selected ? 0.18 : 0.10).setFill()
        path.fill()
        color.withAlphaComponent(selected ? 0.65 : 0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        label.textColor = selected ? .alternateSelectedControlTextColor : tint
        needsDisplay = true
    }
}
