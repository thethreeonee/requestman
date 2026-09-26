import AppKit
import RequestmanCore

@MainActor final class ScriptEditorViewController: NSViewController {
    private var step: ModificationStep
    private var response: Bool
    private var environment: [String: String]
    private let onChange: (ModificationStep) -> Void
    private var execution: ScriptExecutionControl?
    private var running = false
    private var sample = ScriptPreviewInput()
    private let help = NSPopover()
    var isPresented = true { didSet { if !isPresented { help.close(); execution?.cancel() } } }
    private lazy var name = ActionTextField(placeholder: "步骤备注") { [weak self] text in self?.modify { $0.name = text } }
    private let tabs = NSSegmentedControl(labels: ["脚本", "运行结果"], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var source = RulesTextArea { [weak self] text in
        guard let self else { return }; modify { $0.value = text }; result.string = "脚本已更改，请重新试运行。"; updateRunButton()
    }
    private let result = RulesTextArea(editable: false)
    private lazy var runButton = ActionButton(title: "试运行") { [weak self] in self?.run() }
    private lazy var timeout = ActionTextField(placeholder: "毫秒") { [weak self] text in
        guard let number = Int(text) else { return }; self?.modify { var options = $0.scriptOptions ?? ScriptOptions(); options.timeoutMilliseconds = number; $0.scriptOptions = options }
    }
    init(step: ModificationStep, response: Bool, environment: [String: String], onChange: @escaping (ModificationStep) -> Void) {
        self.step = step; self.response = response; self.environment = environment; self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab)
        source.textView.setAccessibilityLabel("JavaScript 脚本"); result.textView.setAccessibilityLabel("脚本运行结果")
        result.string = "尚未试运行。使用示例输入，不发送网络请求。"; result.isHidden = true
        let editors = NSView(); NativeUI.pin(source, to: editors); NativeUI.pin(result, to: editors)
        editors.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let helpButton = ActionButton(title: "API 帮助") { [weak self] in self?.showHelp() }
        helpButton.identifier = .init("scriptHelp")
        helpButton.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil); helpButton.imagePosition = .imageLeading
        let headingSpacer = NSView(); headingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NativeUI.stack([NativeUI.label("JavaScript", size: 12, secondary: true), headingSpacer, helpButton], vertical: false)
        let input = ActionButton(title: "示例输入…") { [weak self] in
            guard let self else { return }
            presentAsSheet(ScriptPreviewInputViewController(input: sample, response: response) { [weak self] value in self?.sample = value })
        }
        let buttonSpacer = NSView(); buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil); runButton.imagePosition = .imageLeading
        let actions = NativeUI.stack([input, buttonSpacer, runButton], vertical: false)
        let timeoutRow = NativeUI.stack([NativeUI.label("超时时间"), timeout, NativeUI.label("ms", secondary: true)], vertical: false)
        timeout.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let description = NativeUI.label("失败时停止当前流程，并在请求日志中记录错误。", size: 11, secondary: true)
        description.maximumNumberOfLines = 0; description.lineBreakMode = .byWordWrapping
        let stack = NativeUI.stack([name, tabs, heading, editors, actions, timeoutRow, description], spacing: 12)
        NativeUI.pin(stack, to: view)
        for wide in [name, tabs, heading, editors, actions] as [NSView] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        editors.setContentHuggingPriority(.defaultLow, for: .vertical)
        update(step: step, response: response, environment: environment)
    }
    override func viewWillDisappear() { super.viewWillDisappear(); execution?.cancel(); help.close() }
    func update(step: ModificationStep, response: Bool, environment: [String: String]) {
        if isViewLoaded {
            if self.step.value != step.value { result.string = "脚本已更改，请重新试运行。" }
            if self.environment != environment { result.string = "环境已更改，请重新试运行。" }
        }
        self.step = step; self.response = response; self.environment = environment
        guard isViewLoaded else { return }
        if name.stringValue != step.name { name.stringValue = step.name }
        source.string = step.value
        let milliseconds = (step.scriptOptions ?? ScriptOptions()).timeoutMilliseconds
        if timeout.integerValue != milliseconds { timeout.integerValue = milliseconds }
        updateRunButton()
    }
    private func modify(_ change: (inout ModificationStep) -> Void) { change(&step); onChange(step) }
    @objc private func changeTab() { source.isHidden = tabs.selectedSegment != 0; result.isHidden = tabs.selectedSegment == 0 }
    private func updateRunButton() { runButton.title = running ? "运行中…" : "试运行"; runButton.isEnabled = !running && !step.value.isEmpty }
    private func showHelp() {
        guard isPresented, let button = view.subviews.flatMap({ ($0 as? NSStackView)?.arrangedSubviews ?? [] }).compactMap({ $0 as? NSStackView }).flatMap(\.arrangedSubviews).first(where: { $0.identifier?.rawValue == "scriptHelp" }) else { return }
        help.behavior = .transient; help.contentViewController = ScriptAPIHelpViewController()
        help.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    private func run() {
        guard !running else { return }
        let current = step, sample = sample, environment = environment, response = response
        let control = ScriptExecutionControl(); execution = control; running = true; updateRunButton()
        Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) {
                do {
                    let request = try sample.request(); let draft = response ? try sample.response() : request
                    let output = try WorkflowScript.run(source: current.value, draft: draft, response: response, request: request, environment: environment, timeoutMilliseconds: (current.scriptOptions ?? ScriptOptions()).timeoutMilliseconds, control: control)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    return String(decoding: try encoder.encode(ScriptMessage(output, response: response)), as: UTF8.self)
                } catch { return "执行失败：\(error.localizedDescription)" }
            }.value
            guard let self else { return }; running = false; updateRunButton()
            guard current == step, self.environment == environment, isPresented else { return }
            result.string = output; tabs.selectedSegment = 1; changeTab()
        }
    }
}

@MainActor final class ScriptAPIHelpViewController: NSViewController {
    override func loadView() {
        let text = RulesTextArea(editable: false); text.borderType = .noBorder
        text.string = Self.text; text.textView.textContainerInset = NSSize(width: 20, height: 20)
        view = text; preferredContentSize = NSSize(width: 560, height: 620)
    }
    private static let text = """
    脚本 API

    脚本是一段同步 JavaScript 函数体。请求阶段 return request；响应阶段 return response。不会展开 {{$env.*}}，请直接读取 env。

    type Header = { name: string; value: string };
    type Request = {
      method: string;
      url: string;
      headers: Header[];
      body: string | null;
    };
    type Response = {
      status: number;
      headers: Header[];
      body: string | null;
    };
    const env: Record<string, string>;

    请求阶段：request 是前序步骤处理后的请求，response 为 null。响应阶段：response 是前序步骤处理后的响应，request 是只读的发出请求快照；env 始终只读。

    headers 是数组，保留原始大小写与重复 Header（例如 Set-Cookie）。比较名称时请忽略大小写。添加：headers.push({ name: 'X-Debug', value: 'true' })；删除：headers = headers.filter(h => h.name.toLowerCase() !== 'x-debug')。

    body 是完整的 UTF-8 文本，不会自动转换为 JSON。使用 JSON.parse / JSON.stringify 处理 JSON。空正文是空字符串；二进制、无法解码的正文或不可用的请求快照为 null；gzip / deflate 会先解压。返回 null 保留原正文，返回空字符串清空正文；修改文本后由代理更新长度与编码 Header。

    url 必须为完整 HTTP/HTTPS URL。method 不支持 CONNECT、TRACE。status 为 200–599 整数。Host、Content-Length、Transfer-Encoding、Connection、Upgrade、Trailer 由代理维护，可读取但不能修改。

    每个脚本默认 1000 ms（可设 50–5000 ms），同时受请求事务 30 秒时限约束。超时、抛错或返回格式无效会停止流程并记录错误。运行环境不提供 fetch、DOM、Node.js、定时器或 Promise 异步执行。

    // 响应阶段：修改 JSON
    const body = JSON.parse(response.body);
    body.data.debug = true;
    response.body = JSON.stringify(body);
    return response;
    """
}

struct ScriptPreviewInput: Sendable {
    var url = "https://api.example.com/orders/1"
    var method = "GET"
    var status = 200
    var requestHeaders = "[{\"name\":\"Content-Type\",\"value\":\"application/json\"}]"
    var responseHeaders = "[{\"name\":\"Content-Type\",\"value\":\"application/json\"}]"
    var requestBody = ""
    var responseBody = "{\"data\":{\"id\":1}}"
    func request() throws -> HTTPMessageDraft {
        var draft = HTTPMessageDraft(method: method, url: url, headers: try JSONDecoder().decode([HTTPField].self, from: Data(requestHeaders.utf8)))
        draft.bodyText = requestBody; return draft
    }
    func response() throws -> HTTPMessageDraft {
        var draft = HTTPMessageDraft(method: method, url: url, status: status, headers: try JSONDecoder().decode([HTTPField].self, from: Data(responseHeaders.utf8)))
        draft.bodyText = responseBody; return draft
    }
}

@MainActor final class ScriptPreviewInputViewController: NSViewController {
    private var input: ScriptPreviewInput
    private let response: Bool
    private let onChange: (ScriptPreviewInput) -> Void
    init(input: ScriptPreviewInput, response: Bool, onChange: @escaping (ScriptPreviewInput) -> Void) {
        self.input = input; self.response = response; self.onChange = onChange; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 540))
        let done = ActionButton(title: "完成") { [weak self] in guard let self else { return }; onChange(input); dismiss(nil) }; done.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NativeUI.stack([NativeUI.label("试运行输入", size: 18, weight: .bold), spacer, done], vertical: false)
        let fields = NativeUI.stack([], spacing: 10)
        addField("URL", keyPath: \.url, to: fields); addField("方法", keyPath: \.method, to: fields)
        addText("请求 Header 数组（JSON）", keyPath: \.requestHeaders, to: fields); addText("请求 Body（文本）", keyPath: \.requestBody, to: fields)
        if response {
            let status = ActionTextField(String(input.status), placeholder: "状态码") { [weak self] text in if let value = Int(text) { self?.input.status = value; if let self { self.onChange(self.input) } } }
            let row = NativeUI.stack([NativeUI.label("状态码"), status], vertical: false); fields.addArrangedSubview(row)
            addText("响应 Header 数组（JSON）", keyPath: \.responseHeaders, to: fields); addText("响应 Body（文本）", keyPath: \.responseBody, to: fields)
        }
        let scroll = NSScrollView(); let document = FlippedView(); scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        NativeUI.pin(fields, to: document, insets: NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0))
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let note = NativeUI.label("仅使用这些输入和当前环境，不发送网络请求。", size: 11, secondary: true)
        let stack = NativeUI.stack([heading, scroll, note], spacing: 14)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for wide in [heading, scroll] as [NSView] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        preferredContentSize = view.frame.size
    }
    private func addField(_ title: String, keyPath: WritableKeyPath<ScriptPreviewInput, String>, to stack: NSStackView) {
        let field = ActionTextField(input[keyPath: keyPath], placeholder: title) { [weak self] value in guard let self else { return }; input[keyPath: keyPath] = value; onChange(input) }
        field.setAccessibilityLabel(title)
        let row = NativeUI.stack([NativeUI.label(title), field], vertical: false)
        stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func addText(_ title: String, keyPath: WritableKeyPath<ScriptPreviewInput, String>, to stack: NSStackView) {
        stack.addArrangedSubview(NativeUI.label(title, size: 12))
        let text = RulesTextArea { [weak self] value in guard let self else { return }; input[keyPath: keyPath] = value; onChange(input) }; text.string = input[keyPath: keyPath]; text.textView.setAccessibilityLabel(title)
        stack.addArrangedSubview(text); text.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; text.heightAnchor.constraint(equalToConstant: 64).isActive = true
    }
}
