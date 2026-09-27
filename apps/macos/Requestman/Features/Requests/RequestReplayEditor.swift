import AppKit
import RequestmanCore
import RequestmanEditor

@MainActor
final class RequestReplayEditor: NSViewController {
    private let initial: RequestReplayDraft
    private let send: (RequestReplayDraft) async throws -> Void
    private let method = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var url = ActionTextField { [weak self] _ in self?.validate() }
    private lazy var headers = ReplayHeadersEditor(fields: initial.headers) { [weak self] in self?.validate() }
    // Use the same syntax-colored editor as the rule body editor, without rewriting the payload.
    private lazy var body = CodeEditorView(language: base64 ? .plaintext : .json) { [weak self] _ in self?.validate() }
    private let bodyFormat = NativeUI.label("", size: 12, secondary: true)
    private let message = NSTextField(wrappingLabelWithString: "结果将在请求日志中显示")
    private let base64: Bool
    private var sending = false
    private var submissionTask: Task<Void, Never>?
    private lazy var submit = ActionButton(title: "发送") { [weak self] in self?.replay() }

    init(draft: RequestReplayDraft, send: @escaping (RequestReplayDraft) async throws -> Void) {
        initial = draft; self.send = send
        base64 = draft.headers.contains { $0.name.lowercased() == "content-encoding" && !$0.value.isEmpty && $0.value.lowercased() != "identity" }
            || String(data: draft.body, encoding: .utf8).map { $0.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) } } != false
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 780))
        preferredContentSize = view.frame.size
        method.addItems(withTitles: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
        if !method.itemTitles.contains(initial.method) { method.addItem(withTitle: initial.method) }
        method.selectItem(withTitle: initial.method)
        method.controlSize = .large; method.font = .systemFont(ofSize: 15)
        url.controlSize = .large; url.font = .systemFont(ofSize: 15)
        method.widthAnchor.constraint(equalToConstant: 140).isActive = true
        method.setAccessibilityLabel("请求方法")
        method.toolTip = "选择请求方法"
        url.setAccessibilityLabel("请求 URL")
        url.stringValue = initial.url; url.placeholderString = "https://example.com/path"
        method.target = self; method.action = #selector(methodChanged)
        url.onSubmit = { [weak self] in self?.replay() }
        url.lineBreakMode = .byTruncatingMiddle
        body.string = base64 ? initial.body.base64EncodedString() : String(data: initial.body, encoding: .utf8) ?? ""
        body.textView.setAccessibilityLabel(base64 ? "请求正文 Base64" : "请求正文")
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)

        let heading = NativeUI.stack([
            NativeUI.label("重新发送请求", size: 22, weight: .semibold),
            NativeUI.label("修改此请求，然后重新发送。", size: 14, secondary: true)
        ], spacing: 8)
        let methodGroup = labeled("请求方法", control: method)
        let urlGroup = labeled("请求 URL", control: url)
        let address = NativeUI.stack([methodGroup, urlGroup], vertical: false, spacing: 14)
        address.alignment = .top
        urlGroup.widthAnchor.constraint(equalTo: address.widthAnchor, constant: -154).isActive = true
        let bodyHeading = NativeUI.stack([
            NativeUI.label("请求体", size: 14, weight: .semibold), flexibleSpace(), bodyFormat
        ], vertical: false)
        let bodyGroup = NativeUI.stack([bodyHeading, body], spacing: 8)
        bodyHeading.widthAnchor.constraint(equalTo: bodyGroup.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: bodyGroup.widthAnchor).isActive = true
        let content = NativeUI.stack([heading, address, headers, bodyGroup], spacing: 26)
        for child in [address, headers, bodyGroup] as [NSView] {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        let cancel = ActionButton(title: "取消") { [weak self] in
            self?.submissionTask?.cancel(); self?.dismiss(nil)
        }
        cancel.keyEquivalent = "\u{1b}"; submit.keyEquivalent = "\r"
        for button in [cancel, submit] {
            button.controlSize = .large
            if #available(macOS 26.0, *) {
                button.bezelStyle = .glass
                button.borderShape = .capsule
            }
        }
        submit.bezelColor = .controlAccentColor
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        submit.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        message.font = .systemFont(ofSize: 12)
        message.setAccessibilityLabel("重放状态")
        let feedback = NativeUI.stack([NativeUI.label("发送时应用当前规则"), message], spacing: 4)
        message.widthAnchor.constraint(equalTo: feedback.widthAnchor).isActive = true
        let actions = NativeUI.stack([feedback, flexibleSpace(), cancel, submit], vertical: false, spacing: 12)
        feedback.widthAnchor.constraint(equalTo: actions.widthAnchor, constant: -230).isActive = true
        let separator = NativeUI.separator()
        for child in [content, separator, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -20),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            actions.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            actions.heightAnchor.constraint(greaterThanOrEqualToConstant: 38)
        ])
        validate()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(url)
    }

    private func labeled(_ title: String, control: NSView) -> NSStackView {
        let group = NativeUI.stack([NativeUI.label(title, size: 14), control], spacing: 7)
        control.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func flexibleSpace() -> NSView {
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return space
    }

    private func draft() throws -> RequestReplayDraft {
        let bytes: Data
        if base64 {
            let compact = body.string.filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: compact) else { throw WorkflowError.invalid("请求体不是有效的 Base64") }
            bytes = decoded
        } else { bytes = Data(body.string.utf8) }
        // Table edits preserve field order, duplicates, and untouched whitespace.
        var result = RequestReplayDraft(method: method.titleOfSelectedItem ?? "", url: url.stringValue, headers: headers.fields, body: bytes)
        result.sourceRecordID = initial.sourceRecordID
        try result.validate()
        return result
    }

    private func validate() {
        guard !sending else { return }
        let isJSON = headers.fields.contains { $0.name.lowercased() == "content-type" && $0.value.lowercased().contains("json") }
            || (try? JSONSerialization.jsonObject(with: Data(body.string.utf8), options: .fragmentsAllowed)) != nil
        bodyFormat.stringValue = base64 ? "Base64" : isJSON ? "JSON · UTF-8" : "文本 · UTF-8"
        do { _ = try draft(); showMessage("结果将在请求日志中显示"); submit.isEnabled = true }
        catch { showMessage(error.localizedDescription, error: true); submit.isEnabled = false }
    }

    private func showMessage(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func setSending(_ value: Bool) {
        sending = value
        method.isEnabled = !value; url.isEnabled = !value
        headers.isEnabled = !value; body.textView.isEditable = !value
        submit.isEnabled = !value
    }

    private func replay() {
        guard !sending else { return }
        view.window?.makeFirstResponder(nil)
        do {
            let request = try draft()
            setSending(true); showMessage("正在发送…")
            submissionTask = Task { [weak self] in
                guard let self else { return }
                do { try await send(request); dismiss(nil) }
                catch { setSending(false); showMessage(error.localizedDescription, error: true) }
            }
        } catch { showMessage(error.localizedDescription, error: true); submit.isEnabled = false }
    }
}

extension RequestReplayEditor {
    @objc private func methodChanged() { validate() }
}

/// Native name/value table. Each edit updates the draft without normalizing other fields.
@MainActor
private final class ReplayHeadersEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var fields: [HTTPField]
    private let onChange: () -> Void
    private let table = NSTableView()
    private let count = NativeUI.label("", size: 12, secondary: true)
    private let controls = NSSegmentedControl()
    var isEnabled = true {
        didSet {
            controls.isEnabled = isEnabled
            for row in 0..<table.numberOfRows {
                for column in 0..<table.numberOfColumns {
                    (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.isEnabled = isEnabled
                }
            }
        }
    }

    init(fields: [HTTPField], onChange: @escaping () -> Void) {
        self.fields = fields; self.onChange = onChange
        super.init(frame: .zero)
        let heading = NativeUI.stack([NativeUI.label("请求头", size: 14, weight: .semibold), count], vertical: false, spacing: 12)
        for (identifier, title, width) in [("name", "名称", CGFloat(220)), ("value", "值", CGFloat(500))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width; column.minWidth = 100
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain; table.rowHeight = 28
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("请求头")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.heightAnchor.constraint(equalToConstant: 156).isActive = true
        controls.segmentCount = 2; controls.trackingMode = .momentary
        controls.controlSize = .large
        controls.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "添加请求头"), forSegment: 0)
        controls.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "删除所选请求头"), forSegment: 1)
        controls.setWidth(30, forSegment: 0); controls.setWidth(30, forSegment: 1)
        controls.setToolTip("添加请求头", forSegment: 0)
        controls.setToolTip("删除所选请求头", forSegment: 1)
        controls.setAccessibilityLabel("添加或删除请求头")
        controls.target = self; controls.action = #selector(changeRows(_:))
        let hint = NativeUI.label("Host 和 Content-Length 自动生成", size: 12, secondary: true)
        hint.toolTip = "Host、Content-Length 和连接字段由重放服务自动生成。"
        let tools = NativeUI.stack([controls, hint], vertical: false, spacing: 12)
        let stack = NativeUI.stack([heading, scroll, tools], spacing: 8)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NativeUI.pin(stack, to: self)
        updateControls()
    }
    required init?(coder: NSCoder) { nil }
    func numberOfRows(in tableView: NSTableView) -> Int { fields.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let isName = tableColumn.identifier.rawValue == "name"
        let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = tableColumn.identifier
        if cell.textField == nil {
            let field = ActionTextField(presentation: .table)
            field.onBeginEditing = { [weak self, weak field] in
                guard let self, let field else { return }
                let row = table.row(for: field)
                if row >= 0 { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
            field.onChange = { [weak self, weak field] text in
                guard let self, let field else { return }
                let row = table.row(for: field)
                guard fields.indices.contains(row) else { return }
                if field.tag == 0 { fields[row].name = text }
                else { fields[row].value = text }
                onChange()
            }
            cell.textField = field; field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let field = cell.textField!
        field.tag = isName ? 0 : 1
        field.stringValue = isName ? fields[row].name : fields[row].value
        field.placeholderString = isName ? "名称" : "值"
        field.setAccessibilityLabel(isName ? "请求头名称" : "请求头值")
        field.isEnabled = isEnabled
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    private func updateControls() {
        count.stringValue = "\(fields.count) 项"
        controls.setEnabled(table.selectedRow >= 0, forSegment: 1)
    }
    @objc private func changeRows(_ sender: NSSegmentedControl) {
        guard isEnabled else { return }
        window?.makeFirstResponder(nil)
        let add = sender.selectedSegment == 0
        if add { fields.append(HTTPField("", "")) }
        else if fields.indices.contains(table.selectedRow) { fields.remove(at: table.selectedRow) }
        table.reloadData()
        if add {
            let row = fields.count - 1
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
            window?.makeFirstResponder(cell?.textField)
        }
        updateControls(); onChange()
    }
}
