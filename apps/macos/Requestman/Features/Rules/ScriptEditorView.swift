import AppKit
import RequestmanCore

@MainActor final class ScriptEditorViewController: NSViewController {
    private var step: ModificationStep
    private var response: Bool
    private var environment: [String: String]
    private var environmentTypes: [String: EnvironmentValueType]
    private let onChange: (ModificationStep) -> Void
    private weak var trial: ScriptPreviewInputViewController?
    private var sample = ScriptPreviewInput()
    private let help = NSPopover()
    var isPresented = true { didSet { if !isPresented { help.close(); trial?.cancelExecution() } } }
    private lazy var name = ActionTextField(placeholder: "步骤备注") { [weak self] text in self?.modify { $0.name = text } }
    private lazy var source = RulesTextArea(javaScript: true) { [weak self] text in
        guard let self else { return }; modify { $0.value = text }; updateRunButton()
    }
    private lazy var runButton = ActionButton(title: "试运行") { [weak self] in self?.showTrial() }
    private lazy var timeout = ActionTextField(placeholder: "毫秒") { [weak self] text in
        guard let number = Int(text) else { return }; self?.modify { var options = $0.scriptOptions ?? ScriptOptions(); options.timeoutMilliseconds = number; $0.scriptOptions = options }
    }
    init(step: ModificationStep, response: Bool, environment: [String: String], environmentTypes: [String: EnvironmentValueType] = [:], onChange: @escaping (ModificationStep) -> Void) {
        self.step = step; self.response = response; self.environment = environment; self.environmentTypes = environmentTypes; self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        source.textView.setAccessibilityLabel("JavaScript 脚本")
        source.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let helpButton = ActionButton(title: "API 帮助") { [weak self] in self?.showHelp() }
        helpButton.identifier = .init("scriptHelp")
        helpButton.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil); helpButton.imagePosition = .imageLeading
        let headingSpacer = NSView(); headingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NativeUI.stack([NativeUI.label("JavaScript", size: 12, secondary: true), headingSpacer, helpButton], vertical: false)
        let buttonSpacer = NSView(); buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil); runButton.imagePosition = .imageLeading
        let actions = NativeUI.stack([buttonSpacer, runButton], vertical: false)
        let timeoutRow = NativeUI.stack([NativeUI.label("超时时间"), timeout, NativeUI.label("ms", secondary: true)], vertical: false)
        timeout.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let stack = NativeUI.stack([name, heading, source, actions, timeoutRow], spacing: 12)
        NativeUI.pin(stack, to: view)
        for wide in [name, heading, source, actions] as [NSView] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        source.setContentHuggingPriority(.defaultLow, for: .vertical)
        update(step: step, response: response, environment: environment, environmentTypes: environmentTypes)
    }
    override func viewWillDisappear() { super.viewWillDisappear(); trial?.cancelExecution(); help.close() }
    func update(step: ModificationStep, response: Bool, environment: [String: String], environmentTypes: [String: EnvironmentValueType] = [:]) {
        self.step = step; self.response = response; self.environment = environment; self.environmentTypes = environmentTypes
        guard isViewLoaded else { return }
        if name.stringValue != step.name { name.stringValue = step.name }
        source.string = step.value
        let milliseconds = (step.scriptOptions ?? ScriptOptions()).timeoutMilliseconds
        if timeout.integerValue != milliseconds { timeout.integerValue = milliseconds }
        updateRunButton()
    }
    private func modify(_ change: (inout ModificationStep) -> Void) { change(&step); onChange(step) }
    private func updateRunButton() { runButton.isEnabled = !step.value.isEmpty }
    private func showHelp() {
        guard isPresented, let button = view.subviews.flatMap({ ($0 as? NSStackView)?.arrangedSubviews ?? [] }).compactMap({ $0 as? NSStackView }).flatMap(\.arrangedSubviews).first(where: { $0.identifier?.rawValue == "scriptHelp" }) else { return }
        help.behavior = .transient; help.contentViewController = ScriptAPIHelpViewController()
        help.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    private func showTrial() {
        guard isPresented, presentedViewControllers?.isEmpty != false else { return }
        view.window?.makeFirstResponder(nil)
        let controller = ScriptPreviewInputViewController(input: sample, response: response, step: step, environment: environment, environmentTypes: environmentTypes) { [weak self] value in
            self?.sample = value
        }
        trial = controller
        presentAsSheet(controller)
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
    const env: Record<string, string | number | boolean | unknown[] | Record<string, unknown>>;

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

struct ScriptPreviewInput: Equatable, Sendable {
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
    private let step: ModificationStep?
    private let environment: [String: String]
    private let environmentTypes: [String: EnvironmentValueType]
    private let onChange: (ScriptPreviewInput) -> Void
    private var execution: ScriptExecutionControl?
    private var executionID: UUID?
    private let result = RulesTextArea(editable: false)
    private lazy var runButton = ActionButton(title: "运行") { [weak self] in self?.run() }
    init(input: ScriptPreviewInput, response: Bool, step: ModificationStep? = nil,
         environment: [String: String] = [:], environmentTypes: [String: EnvironmentValueType] = [:], onChange: @escaping (ScriptPreviewInput) -> Void) {
        self.input = input; self.response = response; self.step = step
        self.environment = environment; self.environmentTypes = environmentTypes; self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let size = step == nil ? NSSize(width: 600, height: 540) : NSSize(width: 900, height: 620)
        view = NSView(frame: NSRect(origin: .zero, size: size))
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height)
        ])
        let done = ActionButton(title: step == nil ? "完成" : "关闭") { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(nil); cancelExecution(); onChange(input); dismiss(nil)
        }
        done.keyEquivalent = "\u{1b}"
        let heading = NativeUI.label(step == nil ? "请求与响应输入" : "试运行脚本", size: 18, weight: .bold)
        let fields = NativeUI.stack([], spacing: 10)
        addField("URL", keyPath: \.url, to: fields); addField("方法", keyPath: \.method, to: fields)
        addText("请求 Header 数组（JSON）", keyPath: \.requestHeaders, to: fields)
        addText("请求 Body（文本）", keyPath: \.requestBody, to: fields)
        if response {
            let status = ActionTextField(String(input.status), placeholder: "状态码") { [weak self] text in
                if let value = Int(text) { self?.updateInput { $0.status = value } }
            }
            status.setAccessibilityLabel("状态码")
            let row = NativeUI.stack([NativeUI.label("状态码"), status], vertical: false)
            fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            addText("响应 Header 数组（JSON）", keyPath: \.responseHeaders, to: fields)
            addText("响应 Body（文本）", keyPath: \.responseBody, to: fields)
        }
        let scroll = NSScrollView(); let document = FlippedView()
        scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(fields); fields.translatesAutoresizingMaskIntoConstraints = false; fields.clipsToBounds = false
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
            // Measure the gutter from the scroll view, so either system scroller style keeps the same field edge.
            fields.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -24),
            fields.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
            fields.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -10),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        // Extend only the viewport into the existing page margin; keep the form's visible edge unchanged.
        let inputViewport = NSView(); inputViewport.clipsToBounds = false
        NativeUI.pin(scroll, to: inputViewport, insets: NSEdgeInsets(top: 0, left: -6, bottom: -6, right: 0))
        inputViewport.setContentHuggingPriority(.defaultLow, for: .vertical)
        let content: NSView
        if step != nil {
            result.textView.setAccessibilityLabel("脚本运行结果")
            result.string = "设置左侧示例输入，然后点击“运行”。"
            let inputs = NativeUI.stack([NativeUI.label("示例输入", weight: .semibold), inputViewport])
            inputs.clipsToBounds = false
            let outputs = NativeUI.stack([NativeUI.label("运行结果", weight: .semibold), result])
            let divider = NativeUI.separator()
            let columns = NativeUI.stack([inputs, divider, outputs], vertical: false, spacing: 24)
            columns.clipsToBounds = false
            // The input scroll view includes the left gutter; the right gutter is ordinary column spacing.
            columns.setCustomSpacing(0, after: inputs)
            columns.setHuggingPriority(.init(1), for: .vertical)
            inputs.setHuggingPriority(.init(1), for: .vertical)
            outputs.setHuggingPriority(.init(1), for: .vertical)
            NSLayoutConstraint.activate([
                inputs.widthAnchor.constraint(equalTo: outputs.widthAnchor, constant: 24),
                inputs.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.5, constant: -0.5),
                inputViewport.widthAnchor.constraint(equalTo: inputs.widthAnchor),
                result.widthAnchor.constraint(equalTo: outputs.widthAnchor),
                inputs.heightAnchor.constraint(equalTo: columns.heightAnchor),
                outputs.heightAnchor.constraint(equalTo: columns.heightAnchor),
                divider.heightAnchor.constraint(equalTo: columns.heightAnchor),
                divider.widthAnchor.constraint(equalToConstant: 1)
            ])
            result.setContentHuggingPriority(.defaultLow, for: .vertical)
            content = columns
        } else { content = inputViewport }
        let note = NativeUI.label("仅使用这些输入和当前环境，不发送网络请求。", size: 11, secondary: true)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var actions: [NSView] = [spacer]
        if step != nil {
            runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            runButton.imagePosition = .imageLeading
            runButton.keyEquivalent = "\r"; runButton.keyEquivalentModifierMask = [.command]
            actions.append(runButton)
        }
        actions.append(done)
        let footer = NativeUI.stack(actions, vertical: false)
        footer.setHuggingPriority(.required, for: .vertical)
        let stack = NativeUI.stack([heading, content, note, footer], spacing: 14)
        stack.clipsToBounds = false
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for wide in [content, footer] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        preferredContentSize = size
    }
    override func viewWillDisappear() { super.viewWillDisappear(); cancelExecution() }
    func cancelExecution() {
        execution?.cancel(); execution = nil; executionID = nil
        if isViewLoaded { runButton.isEnabled = true; runButton.title = "运行" }
    }
    private func updateInput(_ change: (inout ScriptPreviewInput) -> Void) {
        let previous = input; change(&input)
        guard input != previous else { return }
        onChange(input)
        if step != nil {
            cancelExecution()
            result.string = "输入已更改，请重新运行。"
        }
    }
    private func run() {
        view.window?.makeFirstResponder(nil)
        guard let step, executionID == nil else { return }
        let sample = input, environment = environment, environmentTypes = environmentTypes, response = response
        let control = ScriptExecutionControl(), id = UUID()
        execution = control; executionID = id
        runButton.isEnabled = false; runButton.title = "运行中…"; result.string = "正在运行…"
        Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) {
                do {
                    let request = try sample.request(); let draft = response ? try sample.response() : request
                    let output = try WorkflowScript.run(source: step.value, draft: draft, response: response,
                        request: request, environment: environment,
                        timeoutMilliseconds: (step.scriptOptions ?? ScriptOptions()).timeoutMilliseconds, control: control, environmentTypes: environmentTypes)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    return String(decoding: try encoder.encode(ScriptMessage(output, response: response)), as: UTF8.self)
                } catch { return "执行失败：\(error.localizedDescription)" }
            }.value
            guard let self, executionID == id else { return }
            execution = nil; executionID = nil
            result.string = output; runButton.isEnabled = true; runButton.title = "运行"
        }
    }
    private func addField(_ title: String, keyPath: WritableKeyPath<ScriptPreviewInput, String>, to stack: NSStackView) {
        let field = ActionTextField(input[keyPath: keyPath], placeholder: title) { [weak self] value in
            self?.updateInput { $0[keyPath: keyPath] = value }
        }
        field.setAccessibilityLabel(title)
        field.cell?.usesSingleLineMode = true; field.cell?.wraps = false; field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NativeUI.stack([NativeUI.label(title), field], vertical: false)
        stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func addText(_ title: String, keyPath: WritableKeyPath<ScriptPreviewInput, String>, to stack: NSStackView) {
        stack.addArrangedSubview(NativeUI.label(title, size: 12))
        let text = RulesTextArea(roundedInput: true) { [weak self] value in self?.updateInput { $0[keyPath: keyPath] = value } }
        text.string = input[keyPath: keyPath]; text.textView.setAccessibilityLabel(title)
        stack.addArrangedSubview(text); text.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        text.heightAnchor.constraint(equalToConstant: 64).isActive = true
    }
}
