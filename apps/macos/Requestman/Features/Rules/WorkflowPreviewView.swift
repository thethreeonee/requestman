import AppKit
import RequestmanCore

@MainActor final class WorkflowPreviewViewController: NSViewController {
    private let workflow: RequestWorkflow
    private let environment: WorkspaceEnvironment?
    private var input = ScriptPreviewInput()
    private var running = false
    private var execution: ScriptExecutionControl?
    private lazy var url = ActionTextField(input.url, placeholder: "测试 URL") { [weak self] value in self?.input.url = value }
    private let result = RulesTextArea(editable: false)
    private lazy var runButton = ActionButton(title: "运行预览") { [weak self] in self?.run() }
    init(workflow: RequestWorkflow, environment: WorkspaceEnvironment?) {
        self.workflow = workflow; self.environment = environment; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        let done = ActionButton(title: "完成") { [weak self] in self?.execution?.cancel(); self?.dismiss(nil) }; done.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NativeUI.stack([NativeUI.label("预览流程", size: 18, weight: .bold), spacer, done], vertical: false)
        let sample = ActionButton(title: "请求与响应输入…") { [weak self] in
            guard let self else { return }
            presentAsSheet(ScriptPreviewInputViewController(input: input, response: true) { [weak self] value in self?.input = value; self?.url.stringValue = value.url })
        }
        let actions = NativeUI.stack([sample, runButton], vertical: false)
        result.string = "输入实际 URL 后运行预览。不会发送网络请求。"
        let stack = NativeUI.stack([heading, url, actions, result], spacing: 16)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24))
        for wide in [heading, url, result] as [NSView] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        result.setContentHuggingPriority(.defaultLow, for: .vertical)
        preferredContentSize = view.frame.size
    }
    override func viewWillDisappear() { super.viewWillDisappear(); execution?.cancel() }
    private func run() {
        guard !running else { return }
        let workflow = workflow, environment = environment, input = input
        let control = ScriptExecutionControl(); execution = control; running = true
        runButton.isEnabled = false; runButton.title = "运行中…"
        Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) {
                do {
                    var request = try input.request()
                    guard workflow.matches(method: request.method, url: request.url, headers: request.headers) else { return "此输入未命中匹配条件。" }
                    let id = UUID(), date = Date()
                    var trace = try WorkflowEngine.apply(workflow.requestSteps, response: false, to: &request, environment: environment?.values ?? [:], id: id, date: date, control: control)
                    var response = request.isMock ? request : try input.response()
                    trace += try WorkflowEngine.apply(workflow.responseSteps, response: true, to: &response, environment: environment?.values ?? [:], id: id, date: date, request: request, control: control)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    return trace.joined(separator: " → ") + "\n\n请求\n" + String(decoding: try encoder.encode(ScriptMessage(request, response: false)), as: UTF8.self)
                        + "\n\n响应\n" + String(decoding: try encoder.encode(ScriptMessage(response, response: true)), as: UTF8.self)
                } catch { return "无法执行：\(error.localizedDescription)" }
            }.value
            guard let self else { return }; result.string = output; running = false; runButton.isEnabled = true; runButton.title = "运行预览"
        }
    }
}
