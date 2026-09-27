import AppKit
import RequestmanCore

@MainActor
final class RequestInspectorViewController: ObservedViewController {
    var openWorkflow: ((UUID) -> Void)?
    var workflowExists: (UUID) -> Bool = { _ in false }
    private let history: ExecutionHistoryModel
    private let mode: RequestInspectionMode
    var isPresented = false { didSet { if isViewLoaded { refresh() } } }
    private var tab: RequestDetailTab = .requestHeaders
    private var record: CaptureRecord?
    private var panes: [RequestDetailTab: RequestPayloadViewController] = [:]
    private let url = NativeUI.label("", size: 17, weight: .semibold)
    private let copyURLButton = NSButton(title: "", target: nil, action: nil)
    private let method = RequestMethodTag()
    private let status = NativeUI.label("", size: 12)
    private let duration = NativeUI.label("", size: 12, secondary: true)
    private let bytes = NativeUI.label("", size: 12, secondary: true)
    private let rule = MatchedRulePathControl()
    private let error = NativeUI.label("", size: 11)
    private let content = NSView()
    private let streamView = RequestStreamView()
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private var tabs: ToolbarSectionControl!
    private var rootStack: NSStackView!

    init(history: ExecutionHistoryModel, mode: RequestInspectionMode) {
        self.history = history; self.mode = mode
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = FlippedView()
        url.font = .systemFont(ofSize: 17, weight: .semibold); url.alignment = .left
        url.textColor = .labelColor; url.lineBreakMode = .byTruncatingMiddle
        url.maximumNumberOfLines = 1
        url.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyURLButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyURLButton.imagePosition = .imageOnly; copyURLButton.controlSize = .large
        copyURLButton.target = self; copyURLButton.action = #selector(copyURL)
        copyURLButton.setAccessibilityLabel("复制完整 URL")
        if #available(macOS 26.0, *) { copyURLButton.bezelStyle = .glass; copyURLButton.borderShape = .circle }
        else { copyURLButton.bezelStyle = .circular }
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            copyURLButton.setContentHuggingPriority(.required, for: orientation)
            copyURLButton.setContentCompressionResistancePriority(.required, for: orientation)
        }
        let urlRow = NativeUI.stack([url, copyURLButton], vertical: false, spacing: 10)
        urlRow.distribution = .fill
        status.font = RequestStatusStyle.font
        method.setContentHuggingPriority(.required, for: .horizontal)
        method.setContentCompressionResistancePriority(.required, for: .horizontal)
        method.heightAnchor.constraint(equalToConstant: 24).isActive = true
        rule.pathStyle = .standard; rule.isEditable = false
        rule.focusRingType = .none
        rule.backgroundColor = .clear; rule.font = .systemFont(ofSize: 14)
        rule.target = self; rule.action = #selector(openMatchedWorkflow)
        rule.setAccessibilityLabel("命中的规则与项目")
        error.textColor = .systemRed; error.maximumNumberOfLines = 2
        let stats = NativeUI.stack([method, status, NativeUI.label("│", size: 12, secondary: true), duration,
                                   NativeUI.label("│", size: 12, secondary: true), bytes], vertical: false, spacing: 10)
        let summary = NativeUI.stack([urlRow, stats, rule, error], spacing: 10)
        summary.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for child in [urlRow, rule, error] { child.widthAnchor.constraint(equalTo: summary.widthAnchor, constant: -32).isActive = true }
        let size: NSControl.ControlSize
        if #available(macOS 26.0, *) { size = .extraLarge } else { size = .large }
        tabs = ToolbarSectionControl(labels: RequestDetailTab.allCases.map(\.title), accessibilityLabel: "请求数据",
                                     fillsAvailableWidth: true, controlSize: size) { [weak self] in self?.selectTab($0) }
        tabs.segmentDistribution = .fillProportionally
        tabs.selectedSegment = 0
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageOnly; copyButton.controlSize = size
        copyButton.target = self; copyButton.action = #selector(copyContent(_:))
        if #available(macOS 26.0, *) { copyButton.bezelStyle = .glass; copyButton.borderShape = .circle }
        else { copyButton.bezelStyle = .circular }
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            copyButton.setContentHuggingPriority(.required, for: orientation)
            copyButton.setContentCompressionResistancePriority(.required, for: orientation)
        }
        let tabRow = NativeUI.stack([tabs, copyButton], vertical: false, spacing: 10)
        tabRow.distribution = .fill
        tabRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 10, right: 16)
        tabs.heightAnchor.constraint(equalToConstant: tabs.intrinsicContentSize.height).isActive = true
        copyButton.heightAnchor.constraint(equalToConstant: copyButton.intrinsicContentSize.height).isActive = true
        rootStack = NativeUI.stack([summary, tabRow, content], spacing: 0)
        NativeUI.pin(rootStack, to: view)
        for child in [summary, tabRow, content] { child.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        NativeUI.pin(streamView, to: content)
        streamView.isHidden = true
        streamView.onCopyChange = { [weak self] in self?.updateCopy() }
    }
    override func refresh() {
        let next = history.selected
        let version = mode.version
        if record?.id != next?.id {
            for pane in panes.values { pane.update(version: version, isActive: false); pane.view.removeFromSuperview(); pane.removeFromParent() }
            panes.removeAll()
        }
        record = next
        rootStack.isHidden = next == nil
        guard let record else { return }
        url.stringValue = record.url; url.toolTip = record.url
        url.setAccessibilityLabel("请求 URL"); url.setAccessibilityValue(record.url)
        copyURLButton.isEnabled = !record.urlWasTruncated
        copyURLButton.toolTip = record.urlWasTruncated ? "URL 记录已截断，无法复制完整地址" : "复制完整 URL"
        method.setMethod(record.method)
        status.stringValue = record.status.map(String.init) ?? "—"
        status.textColor = RequestStatusStyle.color(record.status)
        duration.stringValue = record.connectionState.isActive ? record.connectionState.rawValue : "\(Int(record.duration * 1000)) ms"
        bytes.stringValue = "响应 \(ByteCountFormatter.string(fromByteCount: Int64(record.responseBytes), countStyle: .file))"
        rule.isHidden = record.matchedWorkflowID == nil
        let rulePath = [record.project, record.workflow]
        if rule.pathItems.map(\.title) != rulePath {
            rule.pathItems = rulePath.map { title in
                let item = NSPathControlItem()
                item.title = title
                return item
            }
        }
        rule.setAccessibilityValue(rulePath.joined(separator: " > "))
        rule.isEnabled = record.matchedWorkflowID.map(workflowExists) ?? false
        rule.toolTip = rulePath.joined(separator: " > ") + (rule.isEnabled ? "\n打开请求修改" : "\n对应的请求修改已不存在")
        error.isHidden = record.error == nil; error.stringValue = record.error ?? ""; error.toolTip = record.error
        let showsStream = tab == .responseBody && record.captureProtocol != .http
        streamView.isHidden = !showsStream
        streamView.update(record: record, version: version, active: isPresented && showsStream)
        if let index = RequestDetailTab.allCases.firstIndex(of: .responseBody) {
            tabs.setLabel(record.captureProtocol == .sse ? "事件流" : record.captureProtocol == .webSocket ? "消息" : "响应体", forSegment: index)
        }
        if !showsStream, panes[tab] == nil {
            let pane = RequestPayloadViewController(record: record, tab: tab, version: version)
            pane.onCopyChange = { [weak self] in self?.updateCopy() }
            panes[tab] = pane; addChild(pane); NativeUI.pin(pane.view, to: content)
        }
        for (item, pane) in panes {
            pane.view.isHidden = item != tab || showsStream
            pane.update(record: record, version: version, isActive: isPresented && item == tab && !showsStream)
        }
        updateCopy()
    }
    private func selectTab(_ index: Int) {
        guard RequestDetailTab.allCases.indices.contains(index) else { return }
        tab = RequestDetailTab.allCases[index]
        if !(view.window?.firstResponder is NSSegmentedControl) { view.window?.makeFirstResponder(nil) }
        refresh()
    }
    private var currentCopy: RequestPayloadCopyContent? {
        if isPresented, tab == .responseBody, record?.captureProtocol != .http, !streamView.copyText.isEmpty {
            return .init(tab: tab, version: mode.version, text: streamView.copyText)
        }
        guard isPresented, let copy = panes[tab]?.copyContent, copy.tab == tab, copy.version == mode.version, !copy.text.isEmpty else { return nil }
        return copy
    }
    private func updateCopy() {
        copyButton.isEnabled = currentCopy != nil
        copyButton.toolTip = "复制当前\(tab.title)"; copyButton.setAccessibilityLabel("复制当前\(tab.title)")
    }
    @objc private func copyContent(_ sender: NSButton) { if let currentCopy { RequestClipboard.copy(currentCopy.text) } }
    @objc private func copyURL() {
        guard let record, !record.urlWasTruncated else { return }
        RequestClipboard.copy(record.url)
    }
    @objc private func openMatchedWorkflow() {
        guard let id = record?.matchedWorkflowID, workflowExists(id) else { return }
        openWorkflow?(id)
    }
}

@MainActor
private final class MatchedRulePathControl: NSPathControl {
    override var isEnabled: Bool {
        didSet {
            if isEnabled != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

enum RequestClipboard {
    @MainActor static func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Paged stream inspection. Only the visible page is read from the session store.
@MainActor
private final class RequestStreamView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let table = NSTableView()
    private let text = NSTextView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let search = NSSearchField()
    private let follow = NSButton(checkboxWithTitle: "跟随最新", target: nil, action: nil)
    private let format = NSSegmentedControl(labels: ["消息", "原始数据"], trackingMode: .selectOne, target: nil, action: nil)
    private let previous = NSButton(title: "上一页", target: nil, action: nil)
    private let next = NSButton(title: "下一页", target: nil, action: nil)
    private let tableScroll = NSScrollView()
    private var store: CaptureStreamStore?
    private var revision = -1
    private var page = 0
    private var rawOffset: UInt64 = 0
    private var messages: [CaptureStreamMessage] = []
    private var rows: [CaptureStreamMessage] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isSSE = false
    private var active = false
    private var selecting = false
    var copyText: String { text.string }
    var onCopyChange: () -> Void = {}
    override init(frame: NSRect) {
        super.init(frame: frame)
        for (id, title, width) in [("time", "时间", 78.0), ("direction", "方向", 42.0), ("kind", "类型 / ID", 100.0), ("size", "大小", 65.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 24; table.style = .inset
        table.setAccessibilityLabel("事件与消息")
        tableScroll.documentView = table; tableScroll.hasVerticalScroller = true
        text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.drawsBackground = false
        let textScroll = NSScrollView(); textScroll.documentView = text; textScroll.hasVerticalScroller = true
        tableScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        search.placeholderString = "搜索当前页"; search.delegate = self; search.sendsSearchStringImmediately = true
        follow.state = .on; follow.target = self; follow.action = #selector(changePageMode)
        format.selectedSegment = 0; format.target = self; format.action = #selector(changePageMode)
        previous.target = self; previous.action = #selector(previousPage)
        next.target = self; next.action = #selector(nextPage)
        let navigation = NativeUI.stack([previous, next, follow], vertical: false, spacing: 8)
        let stack = NativeUI.stack([notice, format, tableScroll, textScroll, search, navigation], spacing: 8)
        NativeUI.pin(stack, to: self, insets: NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12))
        for child in [notice, tableScroll, textScroll, search] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        textScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }
    func update(record: CaptureRecord, version: InspectionVersion, active: Bool) {
        self.active = active
        let selected = version == .original ? record.receivedStream : record.stream
        let changed = store !== selected
        if changed { task?.cancel(); generation += 1; store = selected; page = 0; rawOffset = 0; revision = -1; messages = []; rows = []; text.string = "" }
        isSSE = record.captureProtocol == .sse
        format.isHidden = !isSSE
        if !isSSE { format.selectedSegment = 0 }
        guard active else { task?.cancel(); generation += 1; revision = -1; return }
        let summary = selected?.summary
        notice.stringValue = [record.connectionState.rawValue, "\(summary?.count ?? 0) 条消息", record.closeReason,
                              summary?.error.map { "记录失败：\($0)" },
                              version == .difference ? "事件与消息暂不提供修改对比" : nil].compactMap { $0 }.joined(separator: " · ")
        if revision != summary?.revision || changed { reload() }
    }
    private func reload() {
        guard active else { return }
        task?.cancel(); generation += 1
        let generation = generation
        guard let store else { text.string = "尚未收到事件或消息"; table.reloadData(); return }
        let summary = store.summary
        revision = summary.revision
        let raw = isSSE && format.selectedSegment == 1
        if follow.state == .on {
            page = max(0, (summary.count - 1) / 200)
            rawOffset = UInt64(max(0, (summary.bytes - 1) / 65_536) * 65_536)
        }
        previous.isEnabled = raw ? rawOffset > 0 : page > 0
        next.isEnabled = raw ? rawOffset + 65_536 < UInt64(summary.bytes) : (page + 1) * 200 < summary.count
        tableScroll.isHidden = raw; search.isHidden = raw
        let page = page, offset = rawOffset, selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        task = Task { @MainActor [weak self] in
            do {
                if raw {
                    let bytes = try await store.readRaw(from: offset)
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    text.string = String(data: bytes, encoding: .utf8) ?? bytes.map { String(format: "%02x", $0) }.joined(separator: " "); onCopyChange()
                } else {
                    let values = try await store.read(from: page * 200)
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    messages = values; filterRows(selection: selection)
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                notice.stringValue = "读取事件记录失败：\(error.localizedDescription)"
            }
        }
    }
    private func filterRows(selection: Int? = nil) {
        let query = search.stringValue
        rows = messages.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.kind.localizedCaseInsensitiveContains(query) || ($0.eventID ?? "").localizedCaseInsensitiveContains(query) }
        table.reloadData()
        let index = rows.isEmpty ? nil : follow.state == .on ? rows.count - 1 : selection.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        selecting = true
        defer { selecting = false }
        if let index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); if follow.state == .on { table.scrollRowToVisible(index) } }
        showSelection()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row], value: String
        switch tableColumn?.identifier.rawValue {
        case "time": value = item.date.formatted(date: .omitted, time: .standard)
        case "direction": value = item.direction.rawValue
        case "kind": value = item.kind + (item.eventID.flatMap { $0.isEmpty ? nil : " / \($0)" } ?? "")
        default: value = ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file)
        }
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingTail; label.toolTip = value
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !selecting { follow.state = .off }; showSelection() }
    private func showSelection() {
        text.string = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].text : ""
        onCopyChange()
    }
    func controlTextDidChange(_ obj: Notification) { filterRows() }
    @objc private func previousPage() { follow.state = .off; page = max(0, page - 1); rawOffset = rawOffset >= 65_536 ? rawOffset - 65_536 : 0; reload() }
    @objc private func nextPage() { follow.state = .off; page += 1; rawOffset += 65_536; reload() }
    @objc private func changePageMode() { reload() }
}
