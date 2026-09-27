import AppKit
import RequestmanCore
import RequestmanEditor

@MainActor
final class RequestReplayEditor: NSViewController {
    private let initial: RequestReplayDraft
    private let send: (RequestReplayDraft) async throws -> Void
    private let method = NSTextField()
    private let url = NSTextField()
    private lazy var headers = CodeEditorView(language: .plaintext) { [weak self] _ in self?.validate() }
    private lazy var body = CodeEditorView(language: .plaintext) { [weak self] _ in self?.validate() }
    private let message = NSTextField(wrappingLabelWithString: "")
    private let base64: Bool
    private var sending = false
    private var submissionTask: Task<Void, Never>?
    private lazy var submit = ActionButton(title: "重放") { [weak self] in self?.replay() }

    init(draft: RequestReplayDraft, send: @escaping (RequestReplayDraft) async throws -> Void) {
        initial = draft; self.send = send
        base64 = draft.headers.contains { $0.name.lowercased() == "content-encoding" && !$0.value.isEmpty && $0.value.lowercased() != "identity" }
            || String(data: draft.body, encoding: .utf8).map { $0.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) } } != false
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 600))
        preferredContentSize = view.frame.size
        method.stringValue = initial.method; method.placeholderString = "方法"
        method.widthAnchor.constraint(equalToConstant: 90).isActive = true
        method.setAccessibilityLabel("请求方法"); url.setAccessibilityLabel("请求 URL")
        url.stringValue = initial.url; url.placeholderString = "https://example.com/path"
        method.delegate = self; url.delegate = self
        headers.string = initial.headers.map { $0.name + ": " + $0.value }.joined(separator: "\n")
        body.string = base64 ? initial.body.base64EncodedString() : String(data: initial.body, encoding: .utf8) ?? ""
        headers.textView.setAccessibilityLabel("请求头"); body.textView.setAccessibilityLabel(base64 ? "请求正文 Base64" : "请求正文")
        headers.heightAnchor.constraint(equalToConstant: 130).isActive = true
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let cancel = ActionButton(title: "取消") { [weak self] in self?.submissionTask?.cancel(); self?.dismiss(nil) }
        cancel.keyEquivalent = "\u{1b}"; submit.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NativeUI.stack([spacer, cancel, submit], vertical: false)
        let address = NativeUI.stack([method, url], vertical: false)
        message.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize: 12)
        let hint = NSTextField(wrappingLabelWithString: "基于原始请求编辑，发送时应用当前规则。Host、Content-Length 和连接字段自动生成。提交后在日志查看进度、结果或取消。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        let stack = NativeUI.stack([NativeUI.label("编辑后重放", size: 17, weight: .semibold), hint, address,
            NativeUI.label("请求头", size: 12), headers, NativeUI.label(base64 ? "请求体 · Base64" : "请求体 · UTF-8", size: 12), body, message, actions], spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)])
        for child in [hint, address, headers, body, message, actions] as [NSView] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        validate()
    }
    private func draft() throws -> RequestReplayDraft {
        let bytes: Data
        if base64 {
            let compact = body.string.filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: compact) else { throw WorkflowError.invalid("请求体不是有效的 Base64") }
            bytes = decoded
        } else { bytes = Data(body.string.utf8) }
        // Keep untouched header values byte-for-byte, including duplicate fields and whitespace.
        let originalHeaders = initial.headers.map { $0.name + ": " + $0.value }.joined(separator: "\n")
        let fields = headers.string == originalHeaders ? initial.headers : try RequestReplayDraft.parseHeaders(headers.string)
        var result = RequestReplayDraft(method: method.stringValue, url: url.stringValue, headers: fields, body: bytes)
        result.sourceRecordID = initial.sourceRecordID
        try result.validate()
        return result
    }
    private func validate() {
        guard !sending else { return }
        do { _ = try draft(); message.stringValue = ""; submit.isEnabled = true }
        catch { message.stringValue = error.localizedDescription; submit.isEnabled = false }
    }
    private func replay() {
        guard !sending else { return }
        do {
            let request = try draft()
            sending = true; submit.isEnabled = false; message.stringValue = "正在发送…"
            submissionTask = Task { [weak self] in
                guard let self else { return }
                do { try await send(request); dismiss(nil) }
                catch { sending = false; message.stringValue = error.localizedDescription; submit.isEnabled = true }
            }
        } catch { message.stringValue = error.localizedDescription }
    }
}

extension RequestReplayEditor: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { validate() }
}
