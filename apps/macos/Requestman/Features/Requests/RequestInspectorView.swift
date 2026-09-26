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
        duration.stringValue = "\(Int(record.duration * 1000)) ms"
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
