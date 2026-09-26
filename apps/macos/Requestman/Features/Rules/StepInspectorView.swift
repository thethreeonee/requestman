import AppKit
import RequestmanCore

@MainActor final class StepInspectorViewController: ObservedViewController {
    let model: WorkspaceModel
    var isPresented = true { didSet { script?.isPresented = isPresented; if !isPresented { deletion.close() } } }
    private var stepID: UUID?
    private let titleLabel = NativeUI.label("", size: 18, weight: .bold)
    private let typeIcon = NSImageView()
    private lazy var enabled = RulesSwitch { [weak self] value in self?.modify { $0.enabled = value } }
    private var status: ActionTextField?
    private var delay: ActionTextField?
    private var delayError: NSTextField?
    private var value: RulesTextArea?
    private var method: ActionPopUpButton?
    // IANA HTTP Method Registry, checked 2026-09-26. Excludes CONNECT, TRACE and PRI.
    // Common methods appear first.
    private static let httpMethods = [
        "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS",
        "ACL", "BASELINE-CONTROL", "BIND", "CHECKIN", "CHECKOUT", "COPY", "LABEL", "LINK", "LOCK",
        "MERGE", "MKACTIVITY", "MKCALENDAR", "MKCOL", "MKREDIRECTREF", "MKWORKSPACE", "MOVE",
        "ORDERPATCH", "PROPFIND", "PROPPATCH", "QUERY", "REBIND", "REPORT", "SEARCH",
        "UNBIND", "UNCHECKOUT", "UNLINK", "UNLOCK", "UPDATE", "UPDATEREDIRECTREF", "VERSION-CONTROL"
    ]
    private var formatBody: NSButton?
    private var script: ScriptEditorViewController?
    let deletion = NSPopover()
    private var headerEditors: [HeaderEntryEditor] = []
    private var queryEditors: [QueryParameterEntryEditor] = []
    private var replacementEditors: [URLReplacementEntryEditor] = []
    private var queryDescription: NSTextField?
    private lazy var removeButton = ActionButton(title: "删除") { [weak self] in self?.confirmRemoval() }
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView() }
    override func refresh() {
        let selected = model.selectedStep
        if stepID != selected?.id || view.subviews.isEmpty ||
            (selected.map { [.setHeader, .removeHeader].contains($0.kind) } == true && headerEditors.map(\.entryID) != selected?.headerEntries.map(\.id)) ||
            (selected?.kind == .setQueryParameter && queryEditors.map(\.entryID) != selected?.queryParameterEntries.map(\.id)) ||
            (selected?.kind == .replaceURLString && replacementEditors.map(\.entryID) != selected?.urlReplacementEntries.map(\.id)) { rebuild(selected) }
        guard let selected else { return }
        titleLabel.stringValue = selected.kind.title; enabled.state = selected.enabled ? .on : .off
        typeIcon.image = NSImage(systemSymbolName: selected.kind.symbolName, accessibilityDescription: nil)
        for (editor, entry) in zip(replacementEditors, selected.urlReplacementEntries) { editor.update(entry, editable: model.loaded) }
        for (editor, entry) in zip(headerEditors, selected.headerEntries) { editor.update(entry, editable: model.loaded) }
        for (editor, entry) in zip(queryEditors, selected.queryParameterEntries) { editor.update(entry, editable: model.loaded) }
        if let queryDescription {
            var description = "按顺序执行：添加不存在的参数；修改或删除名称匹配的全部参数，未匹配时跳过。名称区分大小写，修改保留原名称，值自动进行 URL 编码。"
            if selected.queryParameterEntries.contains(where: { $0.operation == nil }) {
                description += "\n旧配置仍在参数不存在时添加、同名时覆盖为一项；选择操作或匹配规则后使用新规则。"
            }
            queryDescription.stringValue = description
        }
        if status?.integerValue != selected.status { status?.integerValue = selected.status }
        value?.string = selected.value
        if delay?.stringValue != selected.value { delay?.stringValue = selected.value }
        delay?.isEnabled = model.loaded
        delayError?.isHidden = (try? WorkflowEngine.delayMilliseconds(selected.value)) != nil
        updateMethod(selected.value)
        removeButton.isEnabled = model.loaded
        enabled.isEnabled = model.loaded; status?.isEnabled = model.loaded
        value?.textView.isEditable = model.loaded
        formatBody?.isEnabled = model.loaded
        script?.update(step: selected, response: model.editingResponse, environment: model.document.environment?.values ?? [:], environmentTypes: model.document.environment?.valueTypes ?? [:])
    }
    private func updateMethod(_ value: String) {
        guard let method else { return }
        let current = value.isEmpty ? "请选择请求方法" : value
        let titles = Self.httpMethods.contains(current) ? Self.httpMethods : [current] + Self.httpMethods
        if method.itemTitles != titles {
            method.removeAllItems(); method.addItems(withTitles: titles)
            method.menu?.autoenablesItems = false
            for item in method.itemArray {
                if !Self.httpMethods.contains(item.title) {
                    item.isEnabled = false
                    item.toolTip = value.isEmpty ? nil : "保留已有配置；请选择一个已知请求方法以替换。"
                }
            }
        }
        method.selectItem(withTitle: current)
        method.isEnabled = model.loaded
    }
    private func rebuild(_ selected: ModificationStep?) {
        script?.isPresented = false; script?.removeFromParent(); script = nil
        deletion.close(); headerEditors = []; queryEditors = []; replacementEditors = []
        queryDescription = nil
        status = nil; delay = nil; delayError = nil; value = nil; method = nil; formatBody = nil
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
            let controller = ScriptEditorViewController(step: selected, response: model.editingResponse, environment: model.document.environment?.values ?? [:], environmentTypes: model.document.environment?.valueTypes ?? [:]) { [weak self] step in self?.replace(step) }
            controller.isPresented = isPresented; addChild(controller); script = controller; content = controller.view
        } else {
            let fields = NativeUI.stack([], spacing: 14)
            if [.setHeader, .removeHeader].contains(selected.kind) {
                for entry in selected.headerEntries {
                    let editor = HeaderEntryEditor(entry: entry, onChange: { [weak self] updated in
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
                let add = ActionButton(title: "Header 修改") { [weak self] in
                    self?.modify { $0.headerEntries.append(HeaderEntry(operation: .add)) }
                }
                add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                add.imagePosition = .imageLeading
                add.isEnabled = model.loaded; fields.addArrangedSubview(add)

            }
            if selected.kind == .setQueryParameter {
                for entry in selected.queryParameterEntries {
                    let editor = QueryParameterEntryEditor(entry: entry, onChange: { [weak self] updated in
                        self?.modify { step in
                            var entries = step.queryParameterEntries
                            guard let index = entries.firstIndex(where: { $0.id == updated.id }) else { return }
                            entries[index] = updated; step.queryParameterEntries = entries
                        }
                    }, onRemove: { [weak self] in
                        self?.modify { $0.queryParameterEntries.removeAll { $0.id == entry.id } }
                    })
                    queryEditors.append(editor)
                    let box = fieldBox(editor); box.identifier = .init("rules.queryParameterEntry")
                    fields.addArrangedSubview(box)
                    box.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                }
                let add = ActionButton(title: "添加参数操作") { [weak self] in
                    self?.modify { $0.queryParameterEntries.append(QueryParameterEntry()) }
                }
                add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                add.imagePosition = .imageLeading
                add.isEnabled = model.loaded; fields.addArrangedSubview(add)
            }
            if selected.kind == .replaceURLString {
                for entry in selected.urlReplacementEntries {
                    let editor = URLReplacementEntryEditor(entry: entry, onChange: { [weak self] updated in
                        self?.modify { step in
                            var entries = step.urlReplacementEntries
                            guard let index = entries.firstIndex(where: { $0.id == updated.id }) else { return }
                            entries[index] = updated; step.urlReplacementEntries = entries
                        }
                    }, onRemove: { [weak self] in
                        self?.modify { $0.urlReplacementEntries.removeAll { $0.id == entry.id } }
                    })
                    replacementEditors.append(editor)
                    let box = fieldBox(editor); box.identifier = .init("rules.urlReplacementEntry")
                    fields.addArrangedSubview(box)
                    box.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                }
                let add = ActionButton(title: "添加替换配置") { [weak self] in
                    self?.modify { $0.urlReplacementEntries.append(URLReplacementEntry()) }
                }
                add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                add.imagePosition = .imageLeading
                add.isEnabled = model.loaded; fields.addArrangedSubview(add)
            }
            if [.mock, .setStatus, .redirect].contains(selected.kind) {
                let field = ActionTextField(String(selected.status), placeholder: "状态码") { [weak self] value in if let number = Int(value) { self?.modify { $0.status = number } } }; status = field
                let row = NativeUI.stack([NativeUI.label("状态码"), field], vertical: false)
                fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            }
            if selected.kind == .delay {
                let field = ActionTextField(selected.value, placeholder: "1000") { [weak self] value in self?.modify { $0.value = value } }
                field.setAccessibilityLabel("延迟时间（ms）"); delay = field
                let row = NativeUI.stack([NativeUI.label("等待时间"), field, NativeUI.label("ms")], vertical: false)
                fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                let error = NativeUI.label("请输入非负整数，单位 ms。", size: 11)
                error.textColor = .systemRed; error.identifier = .init("rules.delayError"); delayError = error
                fields.addArrangedSubview(error)
            }
            if selected.kind == .setMethod {
                let popup = ActionPopUpButton(items: []) { [weak self] index in
                    guard let self, let item = method?.item(at: index), item.isEnabled else { return }
                    modify { $0.value = item.title }
                }
                method = popup
                popup.setAccessibilityLabel("请求方法")
                fields.addArrangedSubview(NativeUI.label("请求方法"))
                fields.addArrangedSubview(popup)
                popup.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            }
            if ![.setHeader, .removeHeader, .setStatus, .setQueryParameter, .replaceURLString, .setMethod, .delay].contains(selected.kind) {
                let body = [.replaceBody, .mock].contains(selected.kind)
                let label = body ? "Body · 文本" : (selected.kind == .rewriteURL ? "目标 URL" :
                    (selected.kind == .redirect ? "重定向目标" : "值"))
                let area = RulesTextArea(template: true, bodyEditor: body) { [weak self] text in self?.modify { $0.value = text } }; value = area
                if body {
                    let message = NativeUI.label("", size: 11, secondary: true)
                    message.maximumNumberOfLines = 0; message.lineBreakMode = .byWordWrapping; message.isHidden = true
                    let format = ActionButton(title: "格式化 JSON") { [weak area] in
                        message.isHidden = area?.formatJSON() == true
                        message.stringValue = message.isHidden ? "" : "无法格式化：请检查 JSON 语法。原文已保留。"
                    }
                    format.controlSize = .small; format.toolTip = "支持无引号 key 和末尾逗号；格式化为 JSON，保留字段顺序与变量，可撤销。"
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
            if [.setHeader, .removeHeader, .setQueryParameter, .replaceURLString].contains(selected.kind) { stack = fields }
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
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        removeButton.imagePosition = .imageLeading; removeButton.controlSize = .small
        removeButton.contentTintColor = .systemRed
        removeButton.attributedTitle = NSAttributedString(string: "删除", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: removeButton.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ])
        let footer = NativeUI.stack([footerSpacer, removeButton], vertical: false)
        let divider = NativeUI.separator()
        var sections: [NSView] = [heading]
        if selected.kind == .script {
            let hint = NativeUI.label("失败时停止当前流程，并在请求日志中记录错误。", size: 11, secondary: true)
            hint.identifier = .init("rules.stepDescription")
            hint.maximumNumberOfLines = 0; hint.lineBreakMode = .byWordWrapping
            sections.append(hint)
        }
        if selected.kind == .setQueryParameter {
            let hint = NativeUI.label("", size: 11, secondary: true)
            hint.identifier = .init("rules.stepDescription")
            hint.maximumNumberOfLines = 0; hint.lineBreakMode = .byWordWrapping
            hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            queryDescription = hint
            sections.append(hint)
        }
        if [.setHeader, .removeHeader].contains(selected.kind) {
            let hint = NativeUI.label("逐条选择添加、修改或删除，按顺序执行；Header 名称不区分大小写。", size: 11, secondary: true)
            hint.identifier = .init("rules.stepDescription")
            hint.maximumNumberOfLines = 0; hint.lineBreakMode = .byWordWrapping
            sections.append(hint)
        }
        if selected.kind == .replaceURLString {
            let hint = NativeUI.label("按顺序执行，区分大小写，按原文替换整个 URL 中的所有匹配；替换为空可删除字符串。", size: 11, secondary: true)
            hint.identifier = .init("rules.stepDescription")
            hint.maximumNumberOfLines = 0; hint.lineBreakMode = .byWordWrapping
            hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            sections.append(hint)
        }
        if [.rewriteURL, .redirect].contains(selected.kind) {
            let hint = NativeUI.label(selected.kind == .rewriteURL
                ? "修改代理实际访问的地址，保留请求方法和 Body。"
                : "返回 3xx 状态码和目标地址，由客户端发起新请求。", size: 11, secondary: true)
            hint.identifier = .init("rules.stepDescription")
            hint.maximumNumberOfLines = 0; hint.lineBreakMode = .byWordWrapping
            sections.append(hint)
        }
        if selected.kind == .delay {
            let hint = NativeUI.label("等待设定的时间后继续执行下一步；0 ms 立即继续。", size: 11, secondary: true)
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
    private var entry: HeaderEntry
    var entryID: UUID { entry.id }
    private let onChange: (HeaderEntry) -> Void
    private var availableOperations: [HeaderOperation] {
        entry.operation == .set ? [.set] + HeaderOperation.editableCases : HeaderOperation.editableCases
    }
    private lazy var operation: ActionPopUpButton = ActionPopUpButton(items: availableOperations.map(\.title)) { [weak self] index in
        guard let self, availableOperations.indices.contains(index), availableOperations[index] != .set else { return }
        entry.operation = availableOperations[index]
        onChange(entry)
        update(entry, editable: operation.isEnabled)
    }
    private lazy var name = HeaderNameField(name: entry.name) { [weak self] text in
        guard let self else { return }; entry.name = text; onChange(entry)
    }
    private lazy var value = RulesTextArea(template: true) { [weak self] text in
        guard let self else { return }; entry.value = text; onChange(entry)
    }
    private let warning = NativeUI.label("此 Header 由代理维护，请通过目标地址或 Body 步骤修改。", size: 11)
    private let remove: ActionButton
    init(entry: HeaderEntry, onChange: @escaping (HeaderEntry) -> Void, onRemove: @escaping () -> Void) {
        self.entry = entry; self.onChange = onChange
        remove = ActionButton(title: "") { onRemove() }
        super.init(frame: .zero)
        remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除 Header")
        remove.imagePosition = .imageOnly
        if #available(macOS 26.0, *) { remove.bezelStyle = .glass; remove.borderShape = .circle }
        else { remove.bezelStyle = .circular }
        NSLayoutConstraint.activate([
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 24)
        ])
        remove.setAccessibilityLabel("删除 Header"); remove.toolTip = "删除此 Header"
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        operation.setAccessibilityLabel("Header 修改方法")
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NativeUI.stack([NativeUI.label("修改方法"), operation, spacer, remove], vertical: false)
        value.textView.setAccessibilityLabel("Header 值")
        value.heightAnchor.constraint(equalToConstant: 72).isActive = true
        warning.textColor = .systemRed; warning.maximumNumberOfLines = 0; warning.lineBreakMode = .byWordWrapping
        let sections: [NSView] = [row, name, value, warning]
        let stack = NativeUI.stack(sections, spacing: 8)
        NativeUI.pin(stack, to: self)
        for wide in sections { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        update(entry, editable: true)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ entry: HeaderEntry, editable: Bool) {
        self.entry = entry
        if name.stringValue != entry.name { name.stringValue = entry.name }
        value.string = entry.value
        let titles = availableOperations.map(\.title)
        if operation.itemTitles != titles {
            operation.removeAllItems(); operation.addItems(withTitles: titles)
        }
        operation.menu?.autoenablesItems = false
        operation.item(withTitle: HeaderOperation.set.title)?.isEnabled = false
        operation.selectItem(withTitle: (entry.operation ?? .set).title)
        operation.isEnabled = editable
        let removes = entry.operation == .remove
        if removes && value.textView === window?.firstResponder { window?.makeFirstResponder(operation) }
        value.isHidden = removes
        name.isEnabled = editable; value.textView.isEditable = editable; remove.isEnabled = editable
        warning.isHidden = !WorkflowEngine.managedHeaders.contains(entry.name.lowercased())
    }
}


@MainActor private final class QueryParameterEntryEditor: NSView {
    private static let matchRules: [WorkflowMatchRule] = [.equals, .contains, .wildcard, .regex]
    private var entry: QueryParameterEntry
    var entryID: UUID { entry.id }
    private let onChange: (QueryParameterEntry) -> Void
    private lazy var operation: ActionPopUpButton = ActionPopUpButton(items: ["添加", "修改", "删除"]) { [weak self] index in
        guard let self else { return }
        entry.operation = QueryParameterOperation.allCases[index]
        onChange(entry)
        update(entry, editable: operation.isEnabled)
    }
    private lazy var matchRule: ActionPopUpButton = ActionPopUpButton(items: Self.matchRules.map(\.title)) { [weak self] index in
        guard let self else { return }
        entry.matchRule = Self.matchRules[index]
        if entry.operation == nil { entry.operation = .modify }
        onChange(entry)
        update(entry, editable: operation.isEnabled)
    }
    private lazy var name = ActionTextField() { [weak self] text in
        guard let self else { return }; entry.name = text; onChange(entry)
    }
    private lazy var value = RulesTextArea(template: true) { [weak self] text in
        guard let self else { return }; entry.value = text; onChange(entry)
    }
    private let remove: ActionButton
    private var valueRow: NSStackView!
    init(entry: QueryParameterEntry, onChange: @escaping (QueryParameterEntry) -> Void, onRemove: @escaping () -> Void) {
        self.entry = entry; self.onChange = onChange
        remove = ActionButton(title: "") { onRemove() }
        super.init(frame: .zero)
        operation.setAccessibilityLabel("参数操作")
        matchRule.setAccessibilityLabel("参数名称匹配规则")
        matchRule.toolTip = "参数名称匹配规则"
        remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除参数操作")
        remove.imagePosition = .imageOnly
        if #available(macOS 26.0, *) { remove.bezelStyle = .glass; remove.borderShape = .circle }
        else { remove.bezelStyle = .circular }
        NSLayoutConstraint.activate([
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 24)
        ])
        remove.setAccessibilityLabel("删除参数操作"); remove.toolTip = "删除此参数操作"
        name.setAccessibilityLabel("参数名称"); value.textView.setAccessibilityLabel("参数值")
        name.cell?.usesSingleLineMode = true
        name.cell?.wraps = false
        name.cell?.isScrollable = true
        value.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let operationRow = row("操作", control: NativeUI.stack([operation, matchRule, spacer, remove], vertical: false, spacing: 6))
        let nameRow = row("参数名称", control: name)
        valueRow = row("参数值", control: value)
        let stack = NativeUI.stack([operationRow, nameRow, valueRow], spacing: 10)
        NativeUI.pin(stack, to: self)
        for wide in [operationRow, nameRow, valueRow!] {
            wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        update(entry, editable: true)
    }
    required init?(coder: NSCoder) { nil }
    private func row(_ title: String, control: NSView) -> NSStackView {
        let label = NativeUI.label(title)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NativeUI.stack([label, control], vertical: false, spacing: 12)
        row.alignment = .top
        return row
    }
    func update(_ entry: QueryParameterEntry, editable: Bool) {
        self.entry = entry
        operation.selectItem(at: QueryParameterOperation.allCases.firstIndex(of: entry.operation ?? .modify)!)
        matchRule.selectItem(at: Self.matchRules.firstIndex(of: entry.matchRule)!)
        matchRule.isHidden = entry.operation == .add
        matchRule.isEnabled = editable
        if name.stringValue != entry.name { name.stringValue = entry.name }
        value.string = entry.value
        operation.isEnabled = editable; remove.isEnabled = editable
        name.isEnabled = editable; value.textView.isEditable = editable
        let hidesValue = entry.operation == .remove
        if hidesValue && value.textView === window?.firstResponder { window?.makeFirstResponder(operation) }
        valueRow.isHidden = hidesValue

    }
}


@MainActor private final class URLReplacementEntryEditor: NSView {
    private var entry: URLReplacementEntry
    var entryID: UUID { entry.id }
    private let onChange: (URLReplacementEntry) -> Void
    private lazy var search = ActionTextField() { [weak self] text in
        guard let self else { return }; entry.search = text; onChange(entry)
    }
    private lazy var replacement = RulesTextArea(template: true) { [weak self] text in
        guard let self else { return }; entry.replacement = text; onChange(entry)
    }
    private let remove: ActionButton
    init(entry: URLReplacementEntry, onChange: @escaping (URLReplacementEntry) -> Void, onRemove: @escaping () -> Void) {
        self.entry = entry; self.onChange = onChange
        remove = ActionButton(title: "") { onRemove() }
        super.init(frame: .zero)
        remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除替换配置")
        remove.imagePosition = .imageOnly
        if #available(macOS 26.0, *) { remove.bezelStyle = .glass; remove.borderShape = .circle }
        else { remove.bezelStyle = .circular }
        NSLayoutConstraint.activate([
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 24)
        ])
        remove.setAccessibilityLabel("删除替换配置"); remove.toolTip = "删除此替换配置"
        search.setAccessibilityLabel("查找字符串")
        search.cell?.usesSingleLineMode = true; search.cell?.wraps = false; search.cell?.isScrollable = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replacement.textView.setAccessibilityLabel("替换为")
        replacement.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let searchLabel = NativeUI.label("查找字符串")
        let replacementLabel = NativeUI.label("替换为")
        searchLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        replacementLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let searchRow = NativeUI.stack([searchLabel, search, remove], vertical: false, spacing: 12)
        let replacementRow = NativeUI.stack([replacementLabel, replacement], vertical: false, spacing: 12)
        replacementRow.alignment = .top
        let stack = NativeUI.stack([searchRow, replacementRow], spacing: 10)
        NativeUI.pin(stack, to: self)
        for row in [searchRow, replacementRow] { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        update(entry, editable: true)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ entry: URLReplacementEntry, editable: Bool) {
        self.entry = entry
        if search.stringValue != entry.search { search.stringValue = entry.search }
        replacement.string = entry.replacement
        search.isEnabled = editable; replacement.textView.isEditable = editable; remove.isEnabled = editable
    }
}
