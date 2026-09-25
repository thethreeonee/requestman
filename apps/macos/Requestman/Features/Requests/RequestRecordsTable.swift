import AppKit
import SwiftUI
import RequestmanCore

struct RequestRecordsTable: NSViewRepresentable {
    let records: [CaptureRecord]
    @Binding var selectedID: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selectedID) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = RecordsScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder

        let table = NSTableView()
        table.rowHeight = 48
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        table.setAccessibilityLabel("请求日志")
        for column in RecordColumn.allCases {
            let item = NSTableColumn(identifier: column.identifier)
            item.title = column.title
            item.minWidth = 0
            item.maxWidth = .greatestFiniteMagnitude
            item.resizingMask = []
            item.isEditable = false
            item.headerCell.alignment = column == .duration ? .right : .left
            table.addTableColumn(item)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scrollView.documentView = table
        context.coordinator.table = table
        scrollView.contentWidthChanged = { [weak coordinator = context.coordinator] width in
            coordinator?.fitColumns(to: width)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.selection = $selectedID
        context.coordinator.update(records: records)
        context.coordinator.fitColumns(to: scrollView.contentView.bounds.width)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selection: Binding<UUID?>
        weak var table: NSTableView?
        private var rows: [RecordRow] = []
        private var updating = false
        private let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        init(selection: Binding<UUID?>) { self.selection = selection }

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

            let selectedRow = selection.wrappedValue.flatMap { id in rows.firstIndex { $0.id == id } }
            let indexes = selectedRow.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
        }

        func fitColumns(to availableWidth: CGFloat) {
            guard let table, availableWidth > 0 else { return }
            // Compact metadata stays predictable; request/project/environment share
            // remaining space. Even a narrow split sums exactly to the viewport.
            let compactScale = min(1, availableWidth / 460)
            let time: CGFloat = 74 * compactScale
            let status: CGFloat = 56 * compactScale
            let duration: CGFloat = 78 * compactScale
            let flexible = max(0, availableWidth - time - status - duration)
            let project = min(180, flexible * 0.29)
            let environment = min(100, flexible * 0.17)
            let request = flexible - project - environment
            let widths = [time, status, request, project, environment, duration]
            for (column, width) in zip(table.tableColumns, widths) where abs(column.width - width) > 0.1 {
                column.width = width
            }
            if abs(table.frame.width - availableWidth) > 0.1 {
                table.setFrameSize(NSSize(width: availableWidth, height: table.frame.height))
            }
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
            if selection.wrappedValue != selected { selection.wrappedValue = selected }
        }
    }
}

private enum RecordColumn: String, CaseIterable {
    case time, status, request, project, environment, duration
    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    var title: String {
        switch self {
        case .time: "时间"
        case .status: "状态码"
        case .request: "请求"
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
    let workflow: String
    let environment: String
    let status: Int?
    let duration: String
    let outcome: CaptureRecord.Outcome
    let result: String

    init(record: CaptureRecord, timeFormatter: DateFormatter) {
        id = record.id
        time = timeFormatter.string(from: record.startedAt)
        method = record.method
        url = record.url
        project = record.project
        workflow = record.workflow
        environment = record.environment
        status = record.status
        duration = String(format: "%.0f ms", max(0, record.duration) * 1000)
        outcome = record.outcome
        result = record.error.map { "\(record.outcome.rawValue) · \($0)" } ?? record.outcome.rawValue
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
        primary.font = .systemFont(ofSize: 12)
        secondary.font = .systemFont(ofSize: 11)
        secondary.isHidden = column != .request && column != .project
        if column == .request {
            primary.lineBreakMode = .byTruncatingMiddle
            addSubview(methodTag)
        }
        if column == .duration { primary.alignment = .right }
        if column == .time || column == .status || column == .duration {
            primary.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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
            primaryColor = row.outcome == .failed || (row.status ?? 0) >= 400 ? .systemRed : .secondaryLabelColor
        case .request:
            primary.stringValue = row.url
            secondary.stringValue = row.result
            secondaryColor = Self.outcomeColor(row.outcome)
            methodTag.setMethod(row.method)
        case .project:
            primary.stringValue = row.project
            secondary.stringValue = row.workflow
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
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = min(8, bounds.width / 2)
        let width = max(0, bounds.width - inset * 2)
        if column == .request {
            let tagWidth = min(methodTag.intrinsicContentSize.width, width * 0.45)
            let gap = min(7, max(0, width - tagWidth))
            methodTag.frame = NSRect(x: inset, y: 5, width: tagWidth, height: 18)
            primary.frame = NSRect(x: inset + tagWidth + gap, y: 5, width: max(0, width - tagWidth - gap), height: 18)
            secondary.frame = NSRect(x: inset, y: 26, width: width, height: 16)
        } else if column == .project {
            primary.frame = NSRect(x: inset, y: 5, width: width, height: 18)
            secondary.frame = NSRect(x: inset, y: 26, width: width, height: 16)
        } else {
            primary.frame = NSRect(x: inset, y: (bounds.height - 18) / 2, width: width, height: 18)
        }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        primary.textColor = selected ? .alternateSelectedControlTextColor : primaryColor
        secondary.textColor = selected ? .alternateSelectedControlTextColor : secondaryColor
        methodTag.selected = selected
    }

    private static func outcomeColor(_ outcome: CaptureRecord.Outcome) -> NSColor {
        switch outcome {
        case .failed: .systemRed
        case .modified: .systemBlue
        case .mocked: .systemPurple
        case .tunnel: .secondaryLabelColor
        case .forwarded: .systemGreen
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
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
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
        NSSize(width: min(86, label.intrinsicContentSize.width + 12), height: 18)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: min(4, bounds.width / 2), y: 2,
                             width: max(0, bounds.width - 8), height: max(0, bounds.height - 3))
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = selected ? .alternateSelectedControlTextColor : tint
        color.withAlphaComponent(selected ? 0.2 : 0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    private func updateColor() {
        label.textColor = selected ? .alternateSelectedControlTextColor : tint
        needsDisplay = true
    }
}
