import AppKit
import RequestmanCore

@MainActor
final class RequestInspectorViewController: ObservedViewController {
    private let history: ExecutionHistoryModel
    private let mode: RequestInspectionMode
    var isPresented = false { didSet { if isViewLoaded { refresh() } } }
    private var tab: RequestDetailTab = .requestHeaders
    private var record: CaptureRecord?
    private var panes: [RequestDetailTab: RequestPayloadViewController] = [:]
    private var popover: NSPopover?
    private let url = NSButton(title: "", target: nil, action: nil)
    private let query = NSButton(title: "查询参数", target: nil, action: nil)
    private let method = NativeUI.label("", size: 12, weight: .medium, secondary: true)
    private let status = NativeUI.label("", size: 12)
    private let duration = NativeUI.label("", size: 12, secondary: true)
    private let bytes = NativeUI.label("", size: 12, secondary: true)
    private let rule = NSButton(title: "", target: nil, action: nil)
    private let error = NativeUI.label("", size: 11)
    private let content = NSView()
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
        url.isBordered = false; url.lineBreakMode = .byTruncatingMiddle
        url.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        url.target = self; url.action = #selector(showURL)
        query.isBordered = false; query.alignment = .left; query.font = .systemFont(ofSize: 12)
        query.target = self; query.action = #selector(showQuery)
        query.toolTip = "查看 URL 中的查询参数，与请求正文分开展示"
        rule.isBordered = false; rule.alignment = .left; rule.font = .systemFont(ofSize: 12)
        rule.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        rule.imagePosition = .imageLeading; rule.lineBreakMode = .byTruncatingTail
        rule.target = self; rule.action = #selector(showRules)
        rule.toolTip = "查看命中规则与执行步骤"
        error.textColor = .systemRed; error.maximumNumberOfLines = 2
        let stats = NativeUI.stack([method, status, NativeUI.label("│", size: 12, secondary: true), duration,
                                   NativeUI.label("│", size: 12, secondary: true), bytes], vertical: false, spacing: 10)
        let summary = NativeUI.stack([url, query, stats, rule, error], spacing: 10)
        summary.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for child in [url, rule, error] { child.widthAnchor.constraint(equalTo: summary.widthAnchor, constant: -32).isActive = true }
        let size: NSControl.ControlSize
        if #available(macOS 26.0, *) { size = .extraLarge } else { size = .large }
        tabs = ToolbarSectionControl(labels: RequestDetailTab.allCases.map(\.title), accessibilityLabel: "请求数据",
                                     fillsAvailableWidth: true, controlSize: size) { [weak self] in self?.selectTab($0) }
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
    }
    override func refresh() {
        let next = history.selected
        let version = mode.version
        if record?.id != next?.id {
            popover?.close(); popover = nil
            for pane in panes.values { pane.update(version: version, isActive: false); pane.view.removeFromSuperview(); pane.removeFromParent() }
            panes.removeAll()
        }
        record = next
        rootStack.isHidden = next == nil
        guard let record else { return }
        if !isPresented { popover?.close(); popover = nil }
        url.title = record.url; url.toolTip = record.url
        url.setAccessibilityLabel("请求 URL"); url.setAccessibilityValue(record.url)
        let initialQuery = URLComponents(string: record.url)?.queryItems?.count ?? 0
        let finalQuery = URLComponents(string: record.finalURL)?.queryItems?.count ?? 0
        query.isHidden = initialQuery == 0 && finalQuery == 0
        query.title = "查询参数  " + (initialQuery == finalQuery ? "\(initialQuery)" : "\(initialQuery) → \(finalQuery)") + "  ›"
        method.stringValue = record.method
        status.stringValue = statusText(record)
        status.textColor = record.error != nil || (record.status ?? 0) >= 400 ? .systemRed : ((record.status ?? 300) >= 300 ? .secondaryLabelColor : .systemGreen)
        duration.stringValue = "\(Int(record.duration * 1000)) ms"
        bytes.stringValue = "响应 \(ByteCountFormatter.string(fromByteCount: Int64(record.responseBytes), countStyle: .file))"
        rule.isHidden = record.matchedWorkflowID == nil
        rule.title = "\(record.workflow)    \(record.project)  ›"
        error.isHidden = record.error == nil; error.stringValue = record.error ?? ""; error.toolTip = record.error
        if panes[tab] == nil {
            let pane = RequestPayloadViewController(record: record, tab: tab, version: version)
            pane.onCopyChange = { [weak self] in self?.updateCopy() }
            panes[tab] = pane; addChild(pane); NativeUI.pin(pane.view, to: content)
        }
        for (item, pane) in panes {
            pane.view.isHidden = item != tab
            pane.update(version: version, isActive: isPresented && item == tab)
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
        guard isPresented, let copy = panes[tab]?.copyContent, copy.tab == tab, copy.version == mode.version, !copy.text.isEmpty else { return nil }
        return copy
    }
    private func updateCopy() {
        copyButton.isEnabled = currentCopy != nil
        copyButton.toolTip = "复制当前\(tab.title)"; copyButton.setAccessibilityLabel("复制当前\(tab.title)")
    }
    @objc private func copyContent(_ sender: NSButton) { if let currentCopy { RequestClipboard.copy(currentCopy.text) } }
    private func show(_ controller: NSViewController, from sender: NSView, size: NSSize) {
        guard isPresented else { return }
        popover?.close()
        let next = NSPopover(); next.behavior = .transient; next.contentViewController = controller; next.contentSize = size
        popover = next; next.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX)
    }
    @objc private func showURL() {
        guard let record else { return }
        show(RequestURLDetails(record: record), from: url, size: NSSize(width: 480, height: 360))
    }
    @objc private func showQuery() {
        guard let record else { return }
        show(RequestQueryDetails(record: record), from: query, size: NSSize(width: 420, height: 360))
    }
    @objc private func showRules() {
        guard let record else { return }
        let controller = RequestTextDetails(title: record.workflow,
            text: (["项目  \(record.project)", "环境  \(record.environment)", "执行步骤"] +
                   (record.steps.isEmpty ? ["没有执行步骤"] : record.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }) + [record.outcome.rawValue]).joined(separator: "\n\n"))
        show(controller, from: rule, size: NSSize(width: 340, height: 360))
    }
    private func statusText(_ record: CaptureRecord) -> String {
        guard let status = record.status else { return record.outcome.rawValue }
        let reasons = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 301: "Moved Permanently", 302: "Found", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"]
        return reasons[status].map { "\(status) \($0)" } ?? String(status)
    }
}

@MainActor
private final class RequestURLDetails: NSViewController {
    private let record: CaptureRecord
    init(record: CaptureRecord) { self.record = record; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = FlippedView()
        let copy = ActionButton(title: "复制完整 URL") { [record] in RequestClipboard.copy(record.url) }
        copy.isEnabled = !record.urlWasTruncated
        copy.toolTip = record.urlWasTruncated ? "URL 记录已截断，无法复制完整地址" : "复制完整 URL"
        let header = NativeUI.stack([NativeUI.label("请求 URL", weight: .semibold), NSView(), copy], vertical: false)
        let source = RequestSourceView()
        source.update(text: record.url, search: "", stateKey: "url", isVisible: true)
        let note = NSTextField(wrappingLabelWithString: "URL 超出记录上限，以下仅显示已记录的部分，地址不完整。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.isHidden = !record.urlWasTruncated
        let stack = NativeUI.stack([header, note, source], spacing: 12)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        for child in [header, note, source] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        source.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
}

@MainActor
private final class RequestQueryDetails: NSViewController {
    private let record: CaptureRecord
    init(record: CaptureRecord) { self.record = record; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        view = scroll
        var fields: [NSView] = [NativeUI.label("查询参数", weight: .semibold)]
        func section(_ title: String, url: String, truncated: Bool) {
            fields.append(NativeUI.label(title, size: 12, weight: .medium, secondary: true))
            let items = URLComponents(string: url)?.queryItems ?? []
            if items.isEmpty { fields.append(NativeUI.label("无查询参数", size: 11, secondary: true)) }
            for item in items { fields.append(URLParameterRow(name: item.name, value: item.value ?? "")) }
            if truncated { fields.append(NativeUI.label("URL 超出记录上限，查询参数可能不完整。", size: 11, secondary: true)) }
        }
        section("原始 URL", url: record.url, truncated: record.urlWasTruncated)
        if URLComponents(string: record.url)?.percentEncodedQuery != URLComponents(string: record.finalURL)?.percentEncodedQuery {
            fields.append(NativeUI.separator()); section("最终 URL", url: record.finalURL, truncated: record.finalURLWasTruncated)
        }
        let stack = NativeUI.stack(fields, spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        for field in fields { field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
    }
}

@MainActor
private final class URLParameterRow: NSView {
    private let name: NSTextField
    private let value: NSTextField
    private let copy: NSButton
    private let text: String
    private var tracking: NSTrackingArea?
    init(name: String, value: String) {
        self.name = NativeUI.label(name, size: 12)
        self.value = NSTextField(wrappingLabelWithString: value)
        self.text = value
        self.copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制 \(name)")!, target: nil, action: nil)
        super.init(frame: .zero)
        self.value.isSelectable = true
        for label in [self.name, self.value] { label.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
        copy.isBordered = false; copy.alphaValue = 0; copy.isEnabled = false
        copy.target = self; copy.action = #selector(copyValue); copy.toolTip = "复制字段值"
        let stack = NativeUI.stack([self.name, self.value, copy], vertical: false, spacing: 8)
        stack.alignment = .top
        NativeUI.pin(stack, to: self, insets: NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0))
        self.name.widthAnchor.constraint(equalToConstant: 120).isActive = true
        self.value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let menu = NSMenu(); let item = NSMenuItem(title: "复制字段值", action: #selector(copyValue), keyEquivalent: "")
        item.target = self; menu.addItem(item); self.menu = menu
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking); self.tracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    private func setHovered(_ hovered: Bool) {
        copy.isEnabled = hovered
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { copy.alphaValue = hovered ? 1 : 0 }
        else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; copy.animator().alphaValue = hovered ? 1 : 0 } }
    }
    @objc private func copyValue() { RequestClipboard.copy(text) }
}

@MainActor
private final class RequestTextDetails: NSViewController {
    private let heading: String
    private let text: String
    init(title: String, text: String) { heading = title; self.text = text; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        let source = RequestSourceView(); source.setFont(.systemFont(ofSize: 12))
        source.update(text: text, search: "", stateKey: "details", isVisible: true)
        let stack = NativeUI.stack([NativeUI.label(heading, weight: .semibold), source], spacing: 12)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        source.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

enum RequestClipboard {
    @MainActor static func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
}
