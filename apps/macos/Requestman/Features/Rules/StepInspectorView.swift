import AppKit
import RequestmanCore
import RequestmanEditor

@MainActor final class StepInspectorViewController: ObservedViewController {
    let model: WorkspaceModel
    var isPresented = true { didSet { script?.isPresented = isPresented; updateAccessoryVisibility(); if !isPresented { deletion.close(); templatePopover?.close() } } }
    private var templatePopover: NSPopover?
    private var bottomAccessory: NSViewController?
    private var stepID: UUID?
    private var displayedLiteralValues = false
    private var displayedBodySource: BodySource = .text
    private var displayedURLRewriteTarget: URLRewriteTarget = .fullURL
    private var urlRewriteTarget: NSSegmentedControl?
    private var bodyFilePath: NSTextField?
    private var bodySource: NSSegmentedControl?
    private var chooseBodyFile: NSButton?
    private var status: ActionTextField?
    private var delay: ActionTextField?
    private var delayError: NSTextField?
    private var value: RulesTextArea?
    private var bodyValue: CodeEditorView?
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
    private var jsonEditors: [JSONEntryEditor] = []
    private var headerEditors: [HeaderEntryEditor] = []
    private var queryEditors: [QueryParameterEntryEditor] = []
    private var replacementEditors: [URLReplacementEntryEditor] = []
    private lazy var removeButton = ActionButton(title: "删除") { [weak self] in self?.confirmRemoval() }
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView() }
    func installAccessories(on item: NSSplitViewItem) {
        guard #available(macOS 26.0, *), bottomAccessory == nil else { return }
        _ = view
        let bottom = NSSplitViewItemAccessoryViewController()
        bottom.automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) { bottom.preferredScrollEdgeEffectStyle = .soft }
        bottom.view = NSView()
        bottomAccessory = bottom
        item.addBottomAlignedAccessoryViewController(bottom)
        rebuild(model.selectedStep); refresh()
    }
    @objc private func showTemplateValues(_ sender: NSButton) {
        guard isPresented, model.selectedStep != nil else { return }
        if templatePopover?.isShown == true { templatePopover?.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = TemplateValuesViewController(response: model.editingResponse,
            environment: model.document.environment?.variables ?? [])
        templatePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    private func updateAccessoryVisibility() {
        if #available(macOS 26.0, *) {
            (bottomAccessory as? NSSplitViewItemAccessoryViewController)?.isHidden = !isPresented || model.selectedStep == nil
        }
    }
    override func refresh() {
        let selected = model.selectedStep
        if stepID != selected?.id || displayedBodySource != (selected?.bodySource ?? .text) || displayedLiteralValues != (selected?.literalValues == true) || view.subviews.isEmpty ||
            (selected?.kind == .rewriteURL && displayedURLRewriteTarget != selected?.effectiveURLRewriteTarget) ||
            (selected.map { [.setHeader, .removeHeader].contains($0.kind) } == true && headerEditors.map(\.entryID) != selected?.headerEntries.map(\.id)) ||
            (selected?.kind == .modifyJSON && jsonEditors.map(\.entryID) != selected?.jsonEntries.map(\.id)) ||
            (selected?.kind == .setQueryParameter && queryEditors.map(\.entryID) != selected?.queryParameterEntries.map(\.id)) ||
            (selected?.kind == .replaceURLString && replacementEditors.map(\.entryID) != selected?.urlReplacementEntries.map(\.id)) { rebuild(selected) }
        guard let selected else { return }
        for (editor, entry) in zip(replacementEditors, selected.urlReplacementEntries) { editor.update(entry, editable: model.loaded) }
        for (editor, entry) in zip(jsonEditors, selected.jsonEntries) { editor.update(entry, editable: model.loaded) }
        for (editor, entry) in zip(headerEditors, selected.headerEntries) { editor.update(entry, editable: model.loaded) }
        for (editor, entry) in zip(queryEditors, selected.queryParameterEntries) { editor.update(entry, editable: model.loaded) }
        if status?.integerValue != selected.status { status?.integerValue = selected.status }
        value?.string = selected.value
        bodyValue?.string = selected.value
        bodySource?.isEnabled = model.loaded
        urlRewriteTarget?.isEnabled = model.loaded
        chooseBodyFile?.isEnabled = model.loaded
        bodyFilePath?.stringValue = selected.bodyFilePath ?? "尚未选择文件"
        bodyFilePath?.toolTip = selected.bodyFilePath
        if delay?.stringValue != selected.value { delay?.stringValue = selected.value }
        delay?.isEnabled = model.loaded
        delayError?.isHidden = (try? ModificationExecutionEngine.delayMilliseconds(selected.value)) != nil
        updateMethod(selected.value)
        removeButton.isEnabled = model.loaded
        status?.isEnabled = model.loaded
        value?.textView.isEditable = model.loaded
        bodyValue?.textView.isEditable = model.loaded
        formatBody?.isEnabled = model.loaded && selected.bodyEncoding != .base64
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
        templatePopover?.close(); templatePopover = nil
        deletion.close(); jsonEditors = []; headerEditors = []; queryEditors = []; replacementEditors = []
        bodyFilePath = nil; bodySource = nil; chooseBodyFile = nil
        status = nil; delay = nil; delayError = nil; value = nil; bodyValue = nil; method = nil; formatBody = nil
        urlRewriteTarget = nil
        view.subviews.forEach { $0.removeFromSuperview() }; stepID = selected?.id
        bottomAccessory?.view.subviews.forEach { $0.removeFromSuperview() }
        updateAccessoryVisibility()
        displayedLiteralValues = selected?.literalValues == true
        displayedBodySource = selected?.bodySource ?? .text
        displayedURLRewriteTarget = selected?.effectiveURLRewriteTarget ?? .fullURL
        guard let selected else {
            let empty = NativeUI.stack([NativeUI.label("选择一个步骤", size: 20, weight: .semibold), NativeUI.label("配置请求或响应的修改动作。", secondary: true)], spacing: 10)
            view.addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: view.centerXAnchor), empty.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return
        }
        let content: NSView
        var bodySizingConstraints: [NSLayoutConstraint] = []
        if selected.kind == .script {
            let service = model.captureService
            let controller = ScriptEditorViewController(step: selected, response: model.editingResponse,
                environment: model.document.environment?.values ?? [:], environmentTypes: model.document.environment?.valueTypes ?? [:],
                httpClientFactory: { try await service.makeScriptHTTPClient() }) { [weak self] step in self?.replace(step) }
            controller.isPresented = isPresented; addChild(controller); script = controller; content = controller.view
        } else {
            let fields = NativeUI.stack([], spacing: 14)
            if selected.kind == .rewriteURL {
                let targets = URLRewriteTarget.allCases
                let control = NSSegmentedControl(labels: targets.map(\.title), trackingMode: .selectOne, target: self, action: #selector(changeURLRewriteTarget(_:)))
                control.segmentStyle = .automatic
                control.segmentDistribution = .fit
                control.controlSize = .large
                if #available(macOS 26.0, *) { control.borderShape = .capsule }
                if #available(macOS 27.0, *) { control.role = .tabs }
                control.setContentHuggingPriority(.required, for: .vertical)
                control.setContentCompressionResistancePriority(.required, for: .vertical)
                control.selectedSegment = targets.firstIndex(of: selected.effectiveURLRewriteTarget) ?? 0
                control.identifier = .init("rules.urlRewriteTarget")
                control.setAccessibilityLabel("修改目标")
                urlRewriteTarget = control
                fields.addArrangedSubview(NativeUI.label("修改目标"))
                fields.addArrangedSubview(control)
            }
            let isBodyStep = [.replaceBody, .mock].contains(selected.kind)
            if isBodyStep {
                let source = NSSegmentedControl(labels: ["文本", "本地文件"], trackingMode: .selectOne, target: self, action: #selector(changeBodySource(_:)))
                source.segmentStyle = .automatic
                source.segmentDistribution = .fit
                source.controlSize = .large
                if #available(macOS 26.0, *) { source.borderShape = .capsule }
                if #available(macOS 27.0, *) { source.role = .tabs }
                source.setContentHuggingPriority(.required, for: .vertical)
                source.setContentCompressionResistancePriority(.required, for: .vertical)
                source.selectedSegment = selected.usesBodyFile ? 1 : 0
                source.identifier = .init("rules.bodySource")
                source.setAccessibilityLabel("Body 来源")
                bodySource = source
                fields.addArrangedSubview(source)
            }
            if ![.setStatus, .delay, .setMethod].contains(selected.kind) && !selected.usesBodyFile {
                let templates = NSButton(checkboxWithTitle: "解析模板变量", target: self, action: #selector(toggleTemplates(_:)))
                templates.state = selected.literalValues == true ? .off : .on
                templates.isEnabled = model.loaded
                templates.toolTip = "关闭时，{{…}} 按原文保留。"
                templates.identifier = .init("rules.resolveTemplates")
                fields.addArrangedSubview(templates)
            }
            if [.setHeader, .removeHeader].contains(selected.kind) {
                for entry in selected.headerEntries {
                    let editor = HeaderEntryEditor(entry: entry, template: selected.literalValues != true, onChange: { [weak self] updated in
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
            }
            if selected.kind == .modifyJSON {
                for entry in selected.jsonEntries {
                    let editor = JSONEntryEditor(entry: entry, template: selected.literalValues != true, onChange: { [weak self] updated in
                        self?.modify { step in
                            guard let index = step.jsonEntries.firstIndex(where: { $0.id == updated.id }) else { return }
                            step.jsonEntries[index] = updated
                        }
                    }, onRemove: { [weak self] in
                        self?.modify { $0.jsonEntries.removeAll { $0.id == entry.id } }
                    })
                    jsonEditors.append(editor)
                    let box = fieldBox(editor); box.identifier = .init("rules.jsonEntry")
                    fields.addArrangedSubview(box)
                    box.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                }
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
            if selected.usesBodyFile {
                let choose = ActionButton(title: "映射本地文件…") { [weak self] in self?.selectBodyFile() }
                choose.identifier = .init("rules.chooseBodyFile"); chooseBodyFile = choose
                let path = NativeUI.label(selected.bodyFilePath ?? "尚未选择文件", secondary: true)
                path.lineBreakMode = .byTruncatingMiddle; path.isSelectable = true
                path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                path.identifier = .init("rules.bodyFilePath"); bodyFilePath = path
                let hint = NativeUI.label("每次执行时读取文件内容作为 Body。", size: 11, secondary: true)
                for item in [choose, path, hint] { fields.addArrangedSubview(item) }
                path.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            }
            if ![.modifyJSON, .setHeader, .removeHeader, .setStatus, .setQueryParameter, .replaceURLString, .setMethod, .delay].contains(selected.kind) && !selected.usesBodyFile {
                let body = [.replaceBody, .mock].contains(selected.kind)
                let label = body ? (selected.bodyEncoding == .base64 ? "Body · Base64" : "Body · 文本") : (selected.kind == .rewriteURL ? urlRewriteValueLabel(selected.effectiveURLRewriteTarget) :
                    (selected.kind == .redirect ? "重定向目标" : "值"))
                let area: NSView
                if body {
                    let editor = CodeEditorView(language: selected.bodyEncoding == .base64 ? .plaintext : .json)
                    if selected.literalValues != true {
                        editor.annotationRanges = { source in
                            TemplateLayoutManager.expression.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)).map(\.range)
                        }
                    }
                    editor.textView.setAccessibilityLabel(label)
                    bodyValue = editor; area = editor
                    let message = NativeUI.label("", size: 11, secondary: true)
                    message.maximumNumberOfLines = 0; message.lineBreakMode = .byWordWrapping; message.isHidden = true
                    let format = ActionButton(title: "格式化 JSON") { [weak editor] in
                        message.isHidden = editor?.formatJSON() == true
                        message.stringValue = message.isHidden ? "" : "无法格式化：请检查 JSON 语法。原文已保留。"
                    }
                    MatchingControls.glass(format)
                    format.controlSize = .small; format.toolTip = "支持无引号 key 和末尾逗号；格式化为 JSON，保留字段顺序与变量，可撤销。"
                    formatBody = format
                    format.isHidden = selected.bodyEncoding == .base64
                    let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    let row = NativeUI.stack([NativeUI.label(label), spacer, format], vertical: false)
                    fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                    fields.addArrangedSubview(message)
                    if selected.bodyEncoding == .base64 {
                        let hint = NativeUI.label("正文按原始字节保存，可编辑 Base64 内容。", size: 11, secondary: true)
                        fields.addArrangedSubview(hint)
                    }
                    editor.onChange = { [weak self] text in message.isHidden = true; self?.modify { $0.value = text } }
                } else {
                    let input = RulesTextArea(template: selected.literalValues != true) { [weak self] text in self?.modify { $0.value = text } }
                    input.textView.setAccessibilityLabel(label)
                    value = input; area = input
                    fields.addArrangedSubview(NativeUI.label(label))
                }
                fields.addArrangedSubview(area)
                area.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                if selected.kind == .rewriteURL, let description = urlRewriteInputDescription(selected.effectiveURLRewriteTarget) {
                    let hint = NativeUI.label(description, size: 11, secondary: true)
                    hint.identifier = .init("rules.urlRewriteInputDescription")
                    hint.maximumNumberOfLines = 0; hint.lineBreakMode = .byWordWrapping
                    hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    fields.addArrangedSubview(hint)
                    hint.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                }
                if body {
                    area.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
                    area.setContentHuggingPriority(.init(1), for: .vertical)
                    fields.setHuggingPriority(.init(1), for: .vertical)
                } else { area.heightAnchor.constraint(equalToConstant: 72).isActive = true }
            }
            let stack: NSStackView
            if [.modifyJSON, .setHeader, .removeHeader, .setQueryParameter, .replaceURLString].contains(selected.kind) { stack = fields }
            else {
                let box = fieldBox(fields)
                stack = NativeUI.stack([box], spacing: 16)
                box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let document = FlippedView()
            // Keep the field gutter inside the document so the scroller can reach the pane edge.
            NativeUI.pin(stack, to: document, insets: NSEdgeInsets(top: 12, left: bottomAccessory == nil ? 0 : 20, bottom: 12, right: 20))
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
            scroll.autohidesScrollers = true
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
            scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
            ])
            if isBodyStep && !selected.usesBodyFile {
                stack.setHuggingPriority(.init(1), for: .vertical)
                let availableHeight = bottomAccessory == nil ? scroll.contentView.heightAnchor : view.safeAreaLayoutGuide.heightAnchor
                let fill = document.heightAnchor.constraint(equalTo: availableHeight)
                fill.priority = .init(249)
                // Fill the viewport when possible; the 360 pt editor minimum can make the form scroll.
                bodySizingConstraints = [
                    document.heightAnchor.constraint(greaterThanOrEqualTo: availableHeight), fill
                ]
            }
            content = scroll
        }
        let footerSpacer = NSView(); footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        removeButton.imagePosition = .imageLeading
        removeButton.controlSize = .large
        if #available(macOS 26.0, *) { removeButton.bezelStyle = .glass; removeButton.borderShape = .capsule }
        removeButton.contentTintColor = .systemRed
        let removalTitle = NSMutableAttributedString(attributedString: removeButton.attributedTitle)
        removalTitle.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: removalTitle.length))
        removeButton.attributedTitle = removalTitle
        var footerItems: [NSView] = []
        let add: ActionButton?
        switch selected.kind {
        case .setHeader, .removeHeader:
            add = ActionButton(title: "Header 修改") { [weak self] in
                self?.modify { $0.headerEntries.append(HeaderEntry(operation: .add)) }
            }
        case .modifyJSON:
            add = ActionButton(title: "添加 JSON 修改") { [weak self] in
                self?.modify { $0.jsonEntries.append(JSONEditEntry()) }
            }
        case .setQueryParameter:
            add = ActionButton(title: "添加参数操作") { [weak self] in
                self?.modify { $0.queryParameterEntries.append(QueryParameterEntry()) }
            }
        case .replaceURLString:
            add = ActionButton(title: "添加替换配置") { [weak self] in
                self?.modify { $0.urlReplacementEntries.append(URLReplacementEntry()) }
            }
        default: add = nil
        }
        if let add {
            add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            add.imagePosition = .imageLeading
            add.controlSize = .large
            if #available(macOS 26.0, *) { add.bezelStyle = .glass; add.borderShape = .capsule }
            add.isEnabled = model.loaded
            footerItems.append(add)
        }
        let info = NSButton(image: NSImage(systemSymbolName: "info", accessibilityDescription: "动态值")!,
                            target: self, action: #selector(showTemplateValues(_:)))
        info.identifier = .init("rules.templateInfo")
        info.toolTip = "动态值"
        info.setAccessibilityLabel("动态值")
        info.controlSize = .regular
        info.image = info.image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        info.imagePosition = .imageOnly
        if #available(macOS 26.0, *) { info.bezelStyle = .glass; info.borderShape = .circle }
        NSLayoutConstraint.activate([info.widthAnchor.constraint(equalToConstant: 24),
                                     info.heightAnchor.constraint(equalToConstant: 24)])
        footerItems.append(info)
        let footer = NativeUI.stack(footerItems + [footerSpacer, removeButton], vertical: false, spacing: 12)
        footer.identifier = .init("rules.stepFooter")
        footer.heightAnchor.constraint(equalToConstant: 36).isActive = true
        if let bottomAccessory {
            NativeUI.pin(footer, to: bottomAccessory.view, insets: NSEdgeInsets(top: 16, left: 20, bottom: 8, right: 20))
            if selected.kind == .script {
                content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
                NSLayoutConstraint.activate([
                    content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                    content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                    content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                    content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
                ])
            } else { NativeUI.pin(content, to: view) }
            NSLayoutConstraint.activate(bodySizingConstraints)
            return
        }
        let stack = NativeUI.stack([content, footer], spacing: 16)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 12, left: 20, bottom: 8, right: selected.kind == .script ? 20 : 0))
        for fixed in [footer] {
            fixed.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -40).isActive = true
        }
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate(bodySizingConstraints)
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    private func urlRewriteValueLabel(_ target: URLRewriteTarget) -> String {
        switch target {
        case .fullURL: "目标 URL"
        case .host: "目标主机（可含端口）"
        case .path: "目标路径"
        }
    }
    private func urlRewriteInputDescription(_ target: URLRewriteTarget) -> String? {
        let captures = "支持 $1、$2 引用首个命中且含捕获组的正则条件；$$ 表示字面 $。"
        return switch target {
        case .fullURL: captures
        case .host: captures + "\n修改当前 URL 的主机，保留协议、路径和查询参数。不填端口时保留当前端口；可填写 example.com:8080，IPv6 使用 [::1]。"
        case .path: captures + "\n修改当前 URL 的路径，保留协议、主机、端口和查询参数。路径以 / 开头，支持中文及百分号编码；字面 ? 和 # 使用 %3F 和 %23。"
        }
    }
    private func fieldBox(_ content: NSView) -> NSBox {
        let box = NSBox(); box.titlePosition = .noTitle
        box.contentViewMargins = .zero; box.contentView = NSView()
        NativeUI.pin(box.contentView!, to: box, insets: NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12))
        NativeUI.pin(content, to: box.contentView!)
        return box
    }
    @objc private func changeURLRewriteTarget(_ sender: NSSegmentedControl) {
        let targets = URLRewriteTarget.allCases
        guard targets.indices.contains(sender.selectedSegment) else { return }
        view.window?.makeFirstResponder(nil)
        modify { $0.urlRewriteTarget = targets[sender.selectedSegment] }
        refresh()
    }
    @objc private func changeBodySource(_ sender: NSSegmentedControl) {
        view.window?.makeFirstResponder(nil)
        modify { $0.bodySource = sender.selectedSegment == 1 ? .file : .text }
        refresh()
    }
    private func selectBodyFile() {
        guard model.loaded, let selected = model.selectedStep, selected.usesBodyFile,
              let workflowID = model.workflow?.id else { return }
        let response = model.editingResponse
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "映射文件"
        if let path = selected.bodyFilePath { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK, let url = panel.url, let self,
                  model.workflow?.id == workflowID, model.editingResponse == response,
                  model.selectedStepID == selected.id, model.selectedStep?.usesBodyFile == true else { return }
            modify { $0.bodyFilePath = url.path }
            refresh()
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    @objc private func toggleTemplates(_ sender: NSButton) { modify { $0.literalValues = sender.state != .on } }
    private func modify(_ update: (inout ModificationStep) -> Void) { guard model.loaded, var step = model.selectedStep else { return }; update(&step); replace(step) }
    private func replace(_ step: ModificationStep) {
        guard model.loaded, var workflow = model.workflow else { return }
        if model.editingResponse, let index = workflow.responseSteps.firstIndex(where: { $0.id == step.id }) { workflow.responseSteps[index] = step }
        if !model.editingResponse, let index = workflow.requestSteps.firstIndex(where: { $0.id == step.id }) { workflow.requestSteps[index] = step }
        model.updateWorkflow(workflow)
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        deletion.close()
        templatePopover?.close()
    }
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
    private let template: Bool
    var entryID: UUID { entry.id }
    private let onChange: (HeaderEntry) -> Void
    private var availableOperations: [HeaderOperation] {
        HeaderOperation.editableCases
    }
    private lazy var operation: ActionPopUpButton = ActionPopUpButton(items: availableOperations.map(\.title)) { [weak self] index in
        guard let self, availableOperations.indices.contains(index) else { return }
        entry.operation = availableOperations[index]
        onChange(entry)
        update(entry, editable: operation.isEnabled)
    }
    private lazy var name = HeaderNameField(name: entry.name) { [weak self] text in
        guard let self else { return }; entry.name = text; onChange(entry)
    }
    private lazy var value = RulesTextArea(template: template) { [weak self] text in
        guard let self else { return }; entry.value = text; onChange(entry)
    }
    private let warning = NativeUI.label("此 Header 由代理维护，请通过目标地址或 Body 步骤修改。", size: 11)
    private let remove: ActionButton
    init(entry: HeaderEntry, template: Bool, onChange: @escaping (HeaderEntry) -> Void, onRemove: @escaping () -> Void) {
        self.entry = entry; self.template = template; self.onChange = onChange
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
        operation.selectItem(withTitle: (entry.operation ?? .set).title)
        operation.isEnabled = editable
        let removes = entry.operation == .remove
        if removes && value.textView === window?.firstResponder { window?.makeFirstResponder(operation) }
        value.isHidden = removes
        name.isEnabled = editable; value.textView.isEditable = editable; remove.isEnabled = editable
        warning.isHidden = !HTTPMessageValidation.managedHeaders.contains(entry.name.lowercased())
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


@MainActor private final class JSONEntryEditor: NSView {
    private var entry: JSONEditEntry
    private let template: Bool
    var entryID: UUID { entry.id }
    private let onChange: (JSONEditEntry) -> Void
    private lazy var operation: ActionPopUpButton = ActionPopUpButton(items: JSONEditOperation.allCases.map(\.title)) { [weak self] index in
        guard let self else { return }
        entry.operation = JSONEditOperation.allCases[index]
        onChange(entry); update(entry, editable: operation.isEnabled)
    }
    private lazy var path = ActionTextField(placeholder: "data.name 或 items[0].name") { [weak self] text in
        guard let self else { return }; entry.path = text; onChange(entry)
    }
    private lazy var value = RulesTextArea(template: template) { [weak self] text in
        guard let self else { return }; entry.value = text; onChange(entry)
    }
    private let remove: ActionButton
    private var valueSection: NSStackView!
    init(entry: JSONEditEntry, template: Bool, onChange: @escaping (JSONEditEntry) -> Void, onRemove: @escaping () -> Void) {
        self.entry = entry; self.template = template; self.onChange = onChange
        remove = ActionButton(title: "") { onRemove() }
        super.init(frame: .zero)
        remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "删除 JSON 修改")
        remove.imagePosition = .imageOnly
        if #available(macOS 26.0, *) { remove.bezelStyle = .glass; remove.borderShape = .circle }
        else { remove.bezelStyle = .circular }
        NSLayoutConstraint.activate([remove.widthAnchor.constraint(equalToConstant: 24), remove.heightAnchor.constraint(equalToConstant: 24)])
        remove.setAccessibilityLabel("删除 JSON 修改"); remove.toolTip = "删除此 JSON 修改"
        operation.setAccessibilityLabel("JSON 修改方法")
        path.setAccessibilityLabel("JSON 路径")
        path.cell?.usesSingleLineMode = true; path.cell?.wraps = false; path.cell?.isScrollable = true
        path.appearance = nil
        path.backgroundColor = .textBackgroundColor; path.textColor = .textColor
        path.toolTip = "对象字段使用点号，数组使用从 0 开始的下标；特殊键名使用 [\"a.b\"]。"
        value.textView.setAccessibilityLabel("JSON 值")
        value.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NativeUI.stack([NativeUI.label("修改方法"), operation, spacer, remove], vertical: false)
        let hint = NativeUI.label("值使用 JSON 格式，例如 \"张三\"、100、true、null、[] 或 {}。", size: 11, secondary: true)
        hint.maximumNumberOfLines = 0; hint.lineBreakMode = .byWordWrapping
        valueSection = NativeUI.stack([NativeUI.label("JSON 值"), value, hint], spacing: 8)
        let sections: [NSView] = [row, NativeUI.label("路径"), path, valueSection]
        let stack = NativeUI.stack(sections, spacing: 8)
        NativeUI.pin(stack, to: self)
        for wide in sections { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        value.widthAnchor.constraint(equalTo: valueSection.widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: valueSection.widthAnchor).isActive = true
        update(entry, editable: true)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ entry: JSONEditEntry, editable: Bool) {
        self.entry = entry
        if path.stringValue != entry.path { path.stringValue = entry.path }
        value.string = entry.value
        operation.selectItem(at: JSONEditOperation.allCases.firstIndex(of: entry.operation)!)
        operation.isEnabled = editable; path.isEnabled = editable
        value.textView.isEditable = editable; remove.isEnabled = editable
        if entry.operation == .remove, value.textView === window?.firstResponder { window?.makeFirstResponder(operation) }
        valueSection.isHidden = entry.operation == .remove
    }
}
