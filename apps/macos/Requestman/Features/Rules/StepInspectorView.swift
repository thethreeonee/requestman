import AppKit
import RequestmanCore

@MainActor final class StepInspectorViewController: ObservedViewController {
    let model: WorkspaceModel
    var isPresented = true { didSet { script?.isPresented = isPresented; if !isPresented { deletion.close() } } }
    private var stepID: UUID?
    private let titleLabel = NativeUI.label("", size: 18, weight: .bold)
    private let typeIcon = NSImageView()
    private lazy var enabled = RulesSwitch { [weak self] value in self?.modify { $0.enabled = value } }
    private var name: RulesTextArea?
    private var status: ActionTextField?
    private var value: RulesTextArea?
    private var formatBody: NSButton?
    private var script: ScriptEditorViewController?
    let deletion = NSPopover()
    private var headerEditors: [HeaderEntryEditor] = []
    private lazy var removeButton = ActionButton(title: "删除") { [weak self] in self?.confirmRemoval() }
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView() }
    override func refresh() {
        let selected = model.selectedStep
        if stepID != selected?.id || view.subviews.isEmpty ||
            (selected.map { [.setHeader, .removeHeader].contains($0.kind) } == true && headerEditors.map(\.entryID) != selected?.headerEntries.map(\.id)) { rebuild(selected) }
        guard let selected else { return }
        titleLabel.stringValue = selected.kind.title; enabled.state = selected.enabled ? .on : .off
        typeIcon.image = NSImage(systemSymbolName: selected.kind.symbolName, accessibilityDescription: nil)
        name?.string = selected.name
        for (editor, entry) in zip(headerEditors, selected.headerEntries) { editor.update(entry, editable: model.loaded) }
        if status?.integerValue != selected.status { status?.integerValue = selected.status }
        value?.string = selected.value
        removeButton.isEnabled = model.loaded
        enabled.isEnabled = model.loaded; name?.textView.isEditable = model.loaded; status?.isEnabled = model.loaded
        value?.textView.isEditable = model.loaded
        formatBody?.isEnabled = model.loaded
        script?.update(step: selected, response: model.editingResponse, environment: model.document.environment?.values ?? [:])
    }
    private func rebuild(_ selected: ModificationStep?) {
        script?.isPresented = false; script?.removeFromParent(); script = nil
        deletion.close(); headerEditors = []
        name = nil; status = nil; value = nil; formatBody = nil
        view.subviews.forEach { $0.removeFromSuperview() }; stepID = selected?.id
        guard let selected else {
            let empty = NativeUI.stack([NativeUI.label("选择一个步骤", size: 20, weight: .semibold), NativeUI.label("配置请求或响应的修改动作。", secondary: true)], spacing: 10)
            view.addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: view.centerXAnchor), empty.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        typeIcon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        typeIcon.contentTintColor = .labelColor
        typeIcon.setAccessibilityElement(false)
        let heading = NativeUI.stack([typeIcon, titleLabel, spacer, NativeUI.label("启用"), enabled], vertical: false)
        let content: NSView
        if selected.kind == .script {
            let controller = ScriptEditorViewController(step: selected, response: model.editingResponse, environment: model.document.environment?.values ?? [:]) { [weak self] step in self?.replace(step) }
            controller.isPresented = isPresented; addChild(controller); script = controller; content = controller.view
        } else {
            let fields = NativeUI.stack([], spacing: 14)
            if [.setHeader, .removeHeader].contains(selected.kind) {
                for entry in selected.headerEntries {
                    let editor = HeaderEntryEditor(entry: entry, includesValue: selected.kind == .setHeader, onChange: { [weak self] updated in
                        self?.modify { step in
                            var entries = step.headerEntries
                            guard let index = entries.firstIndex(where: { $0.id == updated.id }) else { return }
                            entries[index] = updated; step.headerEntries = entries
                        }
                    }, onRemove: { [weak self] in
                        self?.modify { $0.headerEntries.removeAll { $0.id == entry.id } }
                    })
                    headerEditors.append(editor)
                    let box = fieldBox(editor); box.identifier = .init("rules.headerEntry")
                    fields.addArrangedSubview(box)
                    box.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                }
                let add = ActionButton(title: "添加 Header") { [weak self] in
                    self?.modify { $0.headerEntries.append(NamedValue()) }
                }
                add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                add.isEnabled = model.loaded; fields.addArrangedSubview(add)

            }
            if [.setQueryParameter, .replaceURLString].contains(selected.kind) {
                let label = selected.kind == .setQueryParameter ? "参数名称" : "查找字符串"
                let control = RulesTextArea(template: true) { [weak self] value in self?.modify { $0.name = value } }
                name = control; control.string = selected.name; control.textView.setAccessibilityLabel(label)
                control.heightAnchor.constraint(equalToConstant: 40).isActive = true
                let row = NativeUI.stack([NativeUI.label(label), control], vertical: false, spacing: 14)
                control.setContentHuggingPriority(.defaultLow, for: .horizontal)
                fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                let detail = NativeUI.label(selected.kind == .setQueryParameter
                    ? "不存在时添加；同名参数覆盖为一项。名称区分大小写，值自动编码。"
                    : "区分大小写，按原文替换 URL 中的所有匹配；替换为空可删除字符串。", size: 11, secondary: true)
                detail.maximumNumberOfLines = 0; detail.lineBreakMode = .byWordWrapping
                fields.addArrangedSubview(detail)
            }
            if [.mock, .setStatus, .redirect].contains(selected.kind) {
                let field = ActionTextField(String(selected.status), placeholder: "状态码") { [weak self] value in if let number = Int(value) { self?.modify { $0.status = number } } }; status = field
                let row = NativeUI.stack([NativeUI.label("状态码"), field], vertical: false)
                fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            }
            if ![.setHeader, .removeHeader, .setStatus].contains(selected.kind) {
                let body = [.replaceBody, .mock].contains(selected.kind)
                let label = body ? "Body · 文本 / 模板" : (selected.kind == .setQueryParameter ? "参数值 / 模板" :
                    (selected.kind == .replaceURLString ? "替换为 / 模板" : "值 / 模板"))
                let area = RulesTextArea(template: true, bodyEditor: body) { [weak self] text in self?.modify { $0.value = text } }; value = area
                if body {
                    let message = NativeUI.label("", size: 11, secondary: true)
                    message.maximumNumberOfLines = 0; message.lineBreakMode = .byWordWrapping; message.isHidden = true
                    let format = ActionButton(title: "格式化 JSON") { [weak area] in
                        message.isHidden = area?.formatJSON() == true
                        message.stringValue = message.isHidden ? "" : "无法格式化：请检查 JSON 语法。原文已保留。"
                    }
                    format.controlSize = .small; format.toolTip = "支持无引号 key 和末尾逗号；格式化为 JSON，保留字段顺序与模板变量，可撤销。"
                    formatBody = format
                    let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    let row = NativeUI.stack([NativeUI.label(label), spacer, format], vertical: false)
                    fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                    fields.addArrangedSubview(message)
                    area.onChange = { [weak self] text in message.isHidden = true; self?.modify { $0.value = text } }
                } else { fields.addArrangedSubview(NativeUI.label(label)) }
                area.textView.setAccessibilityLabel(label)
                fields.addArrangedSubview(area)
                area.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                if body {
                    area.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
                    area.setContentHuggingPriority(.init(1), for: .vertical)
                    fields.setHuggingPriority(.init(1), for: .vertical)
                } else { area.heightAnchor.constraint(equalToConstant: 72).isActive = true }
            }
            let stack: NSStackView
            if [.setHeader, .removeHeader].contains(selected.kind) { stack = fields }
            else {
                let box = fieldBox(fields)
                stack = NativeUI.stack([box], spacing: 16)
                box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let document = FlippedView()
            NativeUI.pin(stack, to: document, insets: NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0))
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
            scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
            ])
            if [.replaceBody, .mock].contains(selected.kind) {
                stack.setHuggingPriority(.init(1), for: .vertical)
                let fill = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
                fill.priority = .init(249)
                // Fill the viewport when possible; the 360 pt editor minimum can make the form scroll.
                NSLayoutConstraint.activate([
                    document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor), fill
                ])
            }
            content = scroll
        }
        let footerSpacer = NSView(); footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        removeButton.imagePosition = .imageLeading; removeButton.controlSize = .small
        removeButton.contentTintColor = .systemRed
        let footer = NativeUI.stack([footerSpacer, removeButton], vertical: false)
        let divider = NativeUI.separator()
        var sections: [NSView] = [heading]
        if [.setHeader, .removeHeader].contains(selected.kind) {
            let hint = NativeUI.label(selected.kind == .setHeader
                ? "不存在时添加；存在时覆盖。同名 Header 不区分大小写，后面的值优先。"
                : "按名称移除以下 Header，不区分大小写；不存在时跳过。", size: 11, secondary: true)
            hint.identifier = .init("rules.stepDescription")
            hint.maximumNumberOfLines = 0; hint.lineBreakMode = .byWordWrapping
            sections.append(hint)
        }
        let stack = NativeUI.stack(sections + [content, divider, footer], spacing: 16)
        for section in sections.dropFirst() { section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for wide in [heading, content, divider, footer] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    private func fieldBox(_ content: NSView) -> NSBox {
        let box = NSBox(); box.titlePosition = .noTitle
        box.contentViewMargins = .zero; box.contentView = NSView()
        NativeUI.pin(box.contentView!, to: box, insets: NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12))
        NativeUI.pin(content, to: box.contentView!)
        return box
    }
    private func modify(_ update: (inout ModificationStep) -> Void) { guard model.loaded, var step = model.selectedStep else { return }; update(&step); replace(step) }
    private func replace(_ step: ModificationStep) {
        guard model.loaded, var workflow = model.workflow else { return }
        if model.editingResponse, let index = workflow.responseSteps.firstIndex(where: { $0.id == step.id }) { workflow.responseSteps[index] = step }
        if !model.editingResponse, let index = workflow.requestSteps.firstIndex(where: { $0.id == step.id }) { workflow.requestSteps[index] = step }
        model.updateWorkflow(workflow)
    }
    override func viewWillDisappear() { super.viewWillDisappear(); deletion.close() }
    private func confirmRemoval() {
        guard model.loaded, let selected = model.selectedStep, let workflowID = model.workflow?.id else { return }
        let response = model.editingResponse
        let controller = NSViewController(); controller.view = NSView()
        let cancel = ActionButton(title: "取消") { [weak self] in self?.deletion.close() }
        let confirm = ActionButton(title: "删除步骤") { [weak self] in
            guard let self else { return }
            deletion.close()
            guard model.workflow?.id == workflowID, model.editingResponse == response,
                  model.selectedStepID == selected.id else { return }
            remove()
        }
        confirm.contentTintColor = .systemRed
        let message = NativeUI.label("确定删除“\(selected.kind.title)”步骤？")
        message.maximumNumberOfLines = 0; message.lineBreakMode = .byWordWrapping
        let stack = NativeUI.stack([message, NativeUI.stack([cancel, confirm], vertical: false)], spacing: 16)
        NativeUI.pin(stack, to: controller.view, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        controller.preferredContentSize = NSSize(width: 300, height: 100)
        deletion.behavior = .transient; deletion.contentViewController = controller
        deletion.show(relativeTo: removeButton.bounds, of: removeButton, preferredEdge: .maxY)
    }
    private func remove() {
        guard model.loaded, var workflow = model.workflow else { return }
        if model.editingResponse { workflow.responseSteps.removeAll { $0.id == model.selectedStepID } } else { workflow.requestSteps.removeAll { $0.id == model.selectedStepID } }
        model.updateWorkflow(workflow); model.selectedStepID = nil
    }
}

/// Each row keeps its controls while typing; only add/remove rebuilds the list.
@MainActor private final class HeaderEntryEditor: NSView {
    private var entry: NamedValue
    var entryID: UUID { entry.id }
    private let onChange: (NamedValue) -> Void
    private lazy var name = HeaderNameField(name: entry.name) { [weak self] text in
        guard let self else { return }; entry.name = text; onChange(entry)
    }
    private lazy var value = RulesTextArea(template: true) { [weak self] text in
        guard let self else { return }; entry.value = text; onChange(entry)
    }
    private let warning = NativeUI.label("此 Header 由代理维护，请通过目标地址或 Body 步骤修改。", size: 11)
    private let remove: ActionButton
    init(entry: NamedValue, includesValue: Bool, onChange: @escaping (NamedValue) -> Void, onRemove: @escaping () -> Void) {
        self.entry = entry; self.onChange = onChange
        remove = ActionButton(title: "") { onRemove() }
        super.init(frame: .zero)
        remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除 Header")
        remove.setAccessibilityLabel("删除 Header"); remove.toolTip = "删除此 Header"
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NativeUI.stack([name, remove], vertical: false)
        if includesValue {
            value.textView.setAccessibilityLabel("Header 值 / 模板")
            value.heightAnchor.constraint(equalToConstant: 72).isActive = true
        }
        warning.textColor = .systemRed; warning.maximumNumberOfLines = 0; warning.lineBreakMode = .byWordWrapping
        let sections: [NSView] = includesValue ? [row, value, warning] : [row, warning]
        let stack = NativeUI.stack(sections, spacing: 8)
        NativeUI.pin(stack, to: self)
        for wide in sections { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        update(entry, editable: true)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ entry: NamedValue, editable: Bool) {
        self.entry = entry
        if name.stringValue != entry.name { name.stringValue = entry.name }
        value.string = entry.value
        name.isEnabled = editable; value.textView.isEditable = editable; remove.isEnabled = editable
        warning.isHidden = !WorkflowEngine.managedHeaders.contains(entry.name.lowercased())
    }
}
