import AppKit
import RequestmanCore

@MainActor final class WorkflowMatchTestViewController: NSViewController {
    private let workflow: RequestWorkflow
    private var generation = 0
    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE"]
    private lazy var method = ActionPopUpButton(items: methods) { [weak self] _ in self?.inputChanged() }
    private lazy var url = ActionTextField(placeholder: "https://api.example.com/v1/orders/123") { [weak self] _ in self?.inputChanged() }
    private let headerRows = NativeUI.stack([])
    private let resultRows = NativeUI.stack([])
    private let status = NativeUI.label("输入示例请求后点击“测试”。", weight: .medium)
    private lazy var runButton = ActionButton(title: "测试") { [weak self] in self?.run() }
    private var inputs: [MatchTestHeaderRow] = []
    private var contentStack: NSStackView?
    private var heightConstraint: NSLayoutConstraint!

    init(workflow: RequestWorkflow) {
        self.workflow = workflow
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 480)
        heightConstraint.priority = .defaultLow
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 760),
            heightConstraint
        ])
        let done = ActionButton(title: "完成") { [weak self] in self?.dismiss(nil) }
        done.identifier = .init("matchTest.done")
        if #available(macOS 26.0, *) { done.bezelStyle = .glass; done.borderShape = .capsule }
        done.keyEquivalent = "\u{1b}"
        let heading = NativeUI.stack([NativeUI.label("测试匹配", size: 18, weight: .bold), Self.spacer(), done], vertical: false)
        let subtitle = NativeUI.label("当前规则：\(workflow.name)", secondary: true)
        subtitle.toolTip = workflow.name
        let footer = Self.text("仅检测匹配条件，不执行流程、不发送请求。", secondary: true)

        let body = NativeUI.stack([], spacing: 10)
        func add(_ child: NSView) {
            body.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        add(NativeUI.label("当前匹配条件", weight: .semibold))
        var summaryRows: [NSView] = [Self.row("请求方法", Self.text(workflow.method == "*" ? "全部" : workflow.method)),
                                     Self.row(workflow.matchTarget.title, Self.text("\(workflow.matchRule.title)    \(workflow.matchPattern)"))]
        if workflow.matchHeaderEnabled {
            summaryRows.append(Self.row("Header", Self.text("\(workflow.matchHeaderName)    \(workflow.matchHeaderRule.title)    \(workflow.matchHeaderPattern)")))
        }
        add(Self.group(summaryRows))
        if let error = WorkflowMatchTest.validationError(for: workflow) {
            let errorLabel = Self.text(error); errorLabel.textColor = .systemRed
            add(errorLabel)
            let back = ActionButton(title: "返回修改") { [weak self] in self?.dismiss(nil) }
            add(NativeUI.stack([back, Self.spacer()], vertical: false))
        }
        add(NativeUI.separator())
        add(NativeUI.label("测试请求", weight: .semibold))
        if workflow.method != "*" && !methods.contains(workflow.method) { method.addItem(withTitle: workflow.method) }
        method.selectItem(withTitle: workflow.method == "*" ? "GET" : workflow.method)
        method.identifier = .init("matchTest.method"); method.setAccessibilityLabel("测试请求方法")
        method.widthAnchor.constraint(equalToConstant: 130).isActive = true
        add(Self.row("请求方法", NativeUI.stack([method, Self.spacer()], vertical: false)))
        Self.configure(url, id: "matchTest.url", label: "测试 URL")
        url.onSubmit = { [weak self] in self?.run() }
        add(Self.row("测试 URL", url))
        var addHeaderButton: NSButton?
        if workflow.matchHeaderEnabled {
            add(Self.row("测试 Header", headerRows))
            addHeader(name: workflow.matchHeaderName)
            let addHeader = ActionButton(title: "添加 Header") { [weak self] in self?.addHeader() }
            addHeader.identifier = .init("matchTest.addHeader")
            addHeaderButton = addHeader
        }
        runButton.identifier = .init("matchTest.run"); runButton.keyEquivalent = "\r"
        add(NativeUI.stack((addHeaderButton.map { [$0 as NSView] } ?? []) + [Self.spacer(), runButton], vertical: false))
        add(NativeUI.separator())
        add(NativeUI.label("测试结果", weight: .semibold))
        status.identifier = .init("matchTest.status")
        status.maximumNumberOfLines = 0; status.lineBreakMode = .byWordWrapping
        add(status)
        add(resultRows)
        if !workflow.enabled { add(Self.text("当前规则已停用；测试仅验证条件，实际捕获不会启用此规则。", secondary: true)) }
        let stack = NativeUI.stack([heading, subtitle, NativeUI.separator(), body, footer], spacing: 12)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24))
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        contentStack = stack
        inputChanged()
        preferredContentSize = view.frame.size
    }

    override func viewDidAppear() { super.viewDidAppear(); fitContentHeight() }
    override func viewWillDisappear() { super.viewWillDisappear(); generation += 1 }

    private func fitContentHeight() {
        guard let contentStack else { return }
        view.layoutSubtreeIfNeeded()
        let height = max(320, ceil(contentStack.fittingSize.height + 44))
        guard abs(heightConstraint.constant - height) > 1 else { return }
        heightConstraint.constant = height
        let size = NSSize(width: 760, height: height)
        preferredContentSize = size
        view.setFrameSize(size)
        if let window = view.window, window.contentViewController === self || window.sheetParent != nil {
            window.setContentSize(size)
        }
        view.layoutSubtreeIfNeeded()
    }

    private func addHeader(name: String = "") {
        let row = MatchTestHeaderRow(name: name)
        row.changed = { [weak self] in self?.inputChanged() }
        row.remove = { [weak self, weak row] in
            guard let self, let row else { return }
            inputs.removeAll { $0 === row }
            headerRows.removeArrangedSubview(row); row.removeFromSuperview()
            inputChanged()
        }
        inputs.append(row); headerRows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: headerRows.widthAnchor).isActive = true
        inputChanged()
    }

    private func inputChanged() {
        generation += 1
        for row in resultRows.arrangedSubviews { resultRows.removeArrangedSubview(row); row.removeFromSuperview() }
        let error = WorkflowMatchTest.validationError(for: workflow)
        runButton.isEnabled = error == nil && !url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        runButton.title = "测试"
        status.stringValue = error == nil ? "输入示例请求后点击“测试”。" : "无法测试：请先修正当前匹配条件。"
        status.textColor = error == nil ? .secondaryLabelColor : .systemRed
        fitContentHeight()
    }

    private func run() {
        view.window?.makeFirstResponder(nil)
        guard runButton.isEnabled else { return }
        generation += 1
        let current = generation, workflow = workflow
        let method = method.titleOfSelectedItem ?? "GET", url = url.stringValue
        let headers = inputs.map { HTTPField($0.name.stringValue, $0.value.stringValue) }
        runButton.isEnabled = false; runButton.title = "测试中…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                WorkflowMatchTest.evaluate(workflow, method: method, url: url, headers: headers)
            }.value
            guard let self, generation == current else { return }
            show(result)
            runButton.isEnabled = true; runButton.title = "测试"
        }
    }

    private func show(_ result: WorkflowMatchTest) {
        defer { fitContentHeight() }
        for row in resultRows.arrangedSubviews { resultRows.removeArrangedSubview(row); row.removeFromSuperview() }
        if let error = result.error {
            status.stringValue = "无法测试：\(error)"; status.textColor = .systemRed
            return
        }
        status.stringValue = result.matched ? "匹配成功 · 所有条件均满足" : "未匹配 · \(result.conditions.filter { !$0.matched }.map(\.name).joined(separator: "、"))条件未满足"
        status.textColor = result.matched ? .systemGreen : .systemOrange
        for condition in result.conditions {
            let symbol = condition.matched ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: condition.matched ? "匹配" : "未匹配")!)
            icon.contentTintColor = condition.matched ? .systemGreen : .systemOrange
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let detail = Self.text(condition.detail)
            if let range = condition.highlight, range.length > 0 {
                let attributed = NSMutableAttributedString(string: condition.detail)
                attributed.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.15), range: range)
                detail.attributedStringValue = attributed
            }
            let content = NativeUI.stack([NativeUI.label(condition.name, weight: .medium), detail], spacing: 4)
            detail.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            let label = NativeUI.label(condition.matched ? "匹配" : "未匹配")
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.textColor = condition.matched ? .systemGreen : .systemOrange
            let row = NativeUI.stack([icon, content, label], vertical: false, spacing: 10)
            row.distribution = .fill
            content.setContentHuggingPriority(.defaultLow, for: .horizontal)
            content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            resultRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultRows.widthAnchor).isActive = true
            let separator = NativeUI.separator(); resultRows.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: resultRows.widthAnchor).isActive = true
        }
    }

    private static func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }
    private static func text(_ value: String, secondary: Bool = false) -> NSTextField {
        let field = NativeUI.label(value, secondary: secondary)
        field.isSelectable = true; field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private static func row(_ title: String, _ content: NSView) -> NSStackView {
        let label = NativeUI.label(title); label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let row = NativeUI.stack([label, content], vertical: false, spacing: 12)
        row.alignment = .top
        return row
    }
    private static func group(_ rows: [NSView]) -> NSBox {
        let stack = NativeUI.stack(rows, spacing: 10)
        let box = NSBox(); box.titlePosition = .noTitle; box.contentViewMargins = .zero
        box.contentView = NSView(); NativeUI.pin(box.contentView!, to: box)
        NativeUI.pin(stack, to: box.contentView!, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return box
    }
    fileprivate static func configure(_ field: NSTextField, id: String, label: String) {
        field.identifier = .init(id); field.setAccessibilityLabel(label)
        field.cell?.usesSingleLineMode = true; field.cell?.wraps = false; field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

@MainActor private final class MatchTestHeaderRow: NSView {
    var changed: (() -> Void)?
    var remove: (() -> Void)?
    lazy var name = ActionTextField(placeholder: "Header 名称") { [weak self] _ in self?.changed?() }
    lazy var value = ActionTextField(placeholder: "Header 值") { [weak self] _ in self?.changed?() }
    init(name: String) {
        super.init(frame: .zero)
        self.name.stringValue = name
        WorkflowMatchTestViewController.configure(self.name, id: "matchTest.headerName", label: "测试 Header 名称")
        WorkflowMatchTestViewController.configure(value, id: "matchTest.headerValue", label: "测试 Header 值")
        let remove = ActionButton(title: "移除") { [weak self] in self?.remove?() }
        let stack = NativeUI.stack([self.name, value, remove], vertical: false, spacing: 8)
        self.name.widthAnchor.constraint(equalTo: value.widthAnchor).isActive = true
        NativeUI.pin(stack, to: self)
    }
    required init?(coder: NSCoder) { nil }
}
