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
    private var popover: NSPopover?
    private let url = NSButton(title: "", target: nil, action: nil)
    private let method = RequestMethodTag()
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
        status.font = RequestStatusStyle.font
        method.setContentHuggingPriority(.required, for: .horizontal)
        method.setContentCompressionResistancePriority(.required, for: .horizontal)
        method.heightAnchor.constraint(equalToConstant: 24).isActive = true
        rule.isBordered = false; rule.alignment = .left; rule.font = .systemFont(ofSize: 14)
        rule.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        rule.imagePosition = .imageLeading; rule.lineBreakMode = .byTruncatingTail
        rule.target = self; rule.action = #selector(openMatchedWorkflow)
        rule.setAccessibilityLabel("命中的规则与项目")
        error.textColor = .systemRed; error.maximumNumberOfLines = 2
        let stats = NativeUI.stack([method, status, NativeUI.label("│", size: 12, secondary: true), duration,
                                   NativeUI.label("│", size: 12, secondary: true), bytes], vertical: false, spacing: 10)
        let summary = NativeUI.stack([url, stats, rule, error], spacing: 10)
        summary.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for child in [url, rule, error] { child.widthAnchor.constraint(equalTo: summary.widthAnchor, constant: -32).isActive = true }
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
        method.setMethod(record.method)
        status.stringValue = record.status.map(String.init) ?? "—"
        status.textColor = RequestStatusStyle.color(record.status)
        duration.stringValue = "\(Int(record.duration * 1000)) ms"
        bytes.stringValue = "响应 \(ByteCountFormatter.string(fromByteCount: Int64(record.responseBytes), countStyle: .file))"
        rule.isHidden = record.matchedWorkflowID == nil
        rule.title = "\(record.workflow)    \(record.project)"
        rule.isEnabled = record.matchedWorkflowID.map(workflowExists) ?? false
        rule.toolTip = rule.isEnabled ? "打开请求修改：\(record.workflow)" : "对应的请求修改已不存在"
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
    @objc private func openMatchedWorkflow() {
        guard let id = record?.matchedWorkflowID, workflowExists(id) else { return }
        openWorkflow?(id)
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

enum RequestClipboard {
    @MainActor static func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
}
