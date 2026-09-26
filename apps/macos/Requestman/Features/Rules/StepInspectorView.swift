import AppKit
import RequestmanCore

@MainActor final class StepInspectorViewController: ObservedViewController {
    let model: WorkspaceModel
    var isPresented = true { didSet { script?.isPresented = isPresented } }
    private var stepID: UUID?
    private let stage = NativeUI.label("", size: 12, secondary: true)
    private let titleLabel = NativeUI.label("", size: 18, weight: .bold)
    private lazy var enabled = RulesSwitch { [weak self] value in self?.modify { $0.enabled = value } }
    private var header: HeaderNameField?
    private var status: ActionTextField?
    private var value: RulesTextArea?
    private var managedWarning: NSTextField?
    private var script: ScriptEditorViewController?
    private lazy var up = ActionButton(title: "上移") { [weak self] in self?.move(-1) }
    private lazy var down = ActionButton(title: "下移") { [weak self] in self?.move(1) }
    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView() }
    override func refresh() {
        let selected = model.selectedStep
        if stepID != selected?.id || view.subviews.isEmpty { rebuild(selected) }
        guard let selected, let workflow = model.workflow else { return }
        let steps = model.editingResponse ? workflow.responseSteps : workflow.requestSteps
        let index = steps.firstIndex { $0.id == selected.id } ?? 0
        stage.stringValue = "\(model.editingResponse ? "响应" : "请求")阶段 · 第 \(index + 1) 步"
        titleLabel.stringValue = selected.kind.title; enabled.state = selected.enabled ? .on : .off
        if header?.stringValue != selected.name { header?.stringValue = selected.name }
        if status?.integerValue != selected.status { status?.integerValue = selected.status }
        value?.string = selected.value
        managedWarning?.isHidden = !WorkflowEngine.managedHeaders.contains(selected.name.lowercased())
        up.isEnabled = model.loaded && index > 0; down.isEnabled = model.loaded && index + 1 < steps.count
        enabled.isEnabled = model.loaded; header?.isEnabled = model.loaded; status?.isEnabled = model.loaded
        value?.textView.isEditable = model.loaded
        script?.update(step: selected, response: model.editingResponse, environment: model.document.environment?.values ?? [:])
    }
    private func rebuild(_ selected: ModificationStep?) {
        script?.isPresented = false; script?.removeFromParent(); script = nil
        header = nil; status = nil; value = nil; managedWarning = nil
        view.subviews.forEach { $0.removeFromSuperview() }; stepID = selected?.id
        guard let selected else {
            let empty = NativeUI.stack([NativeUI.label("选择一个步骤", size: 20, weight: .semibold), NativeUI.label("配置请求或响应的修改动作。", secondary: true)], spacing: 10)
            view.addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: view.centerXAnchor), empty.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NativeUI.stack([titleLabel, spacer, NativeUI.label("启用"), enabled], vertical: false)
        let content: NSView
        if selected.kind == .script {
            let controller = ScriptEditorViewController(step: selected, response: model.editingResponse, environment: model.document.environment?.values ?? [:]) { [weak self] step in self?.replace(step) }
            controller.isPresented = isPresented; addChild(controller); script = controller; content = controller.view
        } else {
            let fields = NativeUI.stack([], spacing: 14)
            if [.setHeader, .removeHeader].contains(selected.kind) {
                let control = HeaderNameField(name: selected.name) { [weak self] value in self?.modify { $0.name = value } }; header = control
                let row = NativeUI.stack([NativeUI.label("Header 名称"), control], vertical: false, spacing: 14)
                control.setContentHuggingPriority(.defaultLow, for: .horizontal)
                control.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
                fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                if selected.kind == .setHeader {
                    let detail = NativeUI.label("不存在时添加；存在时覆盖。名称不区分大小写，同名多项会替换为一项。", size: 11, secondary: true)
                    detail.maximumNumberOfLines = 0; detail.lineBreakMode = .byWordWrapping; fields.addArrangedSubview(detail)
                }
                let warning = NativeUI.label("此 Header 由代理维护。请通过目标地址或 Body 步骤修改。", size: 11)
                warning.textColor = .systemRed; warning.maximumNumberOfLines = 0; warning.lineBreakMode = .byWordWrapping
                managedWarning = warning; fields.addArrangedSubview(warning)
            }
            if [.mock, .setStatus, .redirect].contains(selected.kind) {
                let field = ActionTextField(String(selected.status), placeholder: "状态码") { [weak self] value in if let number = Int(value) { self?.modify { $0.status = number } } }; status = field
                let row = NativeUI.stack([NativeUI.label("状态码"), field], vertical: false)
                fields.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            }
            if ![.removeHeader, .setStatus].contains(selected.kind) {
                let body = [.replaceBody, .mock].contains(selected.kind)
                fields.addArrangedSubview(NativeUI.label(body ? "Body · 文本 / 模板" : "值 / 模板"))
                let area = RulesTextArea { [weak self] text in self?.modify { $0.value = text } }; value = area
                area.textView.setAccessibilityLabel(body ? "Body · 文本 / 模板" : "值 / 模板")
                fields.addArrangedSubview(area)
                area.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
                area.heightAnchor.constraint(equalToConstant: body ? 200 : 60).isActive = true
            }
            let box = NSBox(); box.titlePosition = .noTitle; box.contentViewMargins = NSSize(width: 12, height: 14); box.contentView = NSView()
            NativeUI.pin(fields, to: box.contentView!)
            let dynamic = NativeUI.label("{{env.apiKey}}\n{{$uuid}}\n{{$timestamp}}")
            dynamic.font = .monospacedSystemFont(ofSize: 12, weight: .regular); dynamic.maximumNumberOfLines = 0; dynamic.isSelectable = true
            let dynamicBox = NSBox(); dynamicBox.title = "动态值"; dynamicBox.contentViewMargins = NSSize(width: 12, height: 12); dynamicBox.contentView = NSView()
            NativeUI.pin(dynamic, to: dynamicBox.contentView!)
            let fill = NSView(); fill.setContentHuggingPriority(.defaultLow, for: .vertical)
            let stack = NativeUI.stack([box, dynamicBox, fill], spacing: 16)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            dynamicBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            content = stack
        }
        let footerSpacer = NSView(); footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let remove = ActionButton(title: "删除") { [weak self] in self?.remove() }
        for (button, symbol) in [(up, "arrow.up"), (down, "arrow.down"), (remove, "trash")] { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading; button.controlSize = .small }
        let footer = NativeUI.stack([up, down, footerSpacer, remove], vertical: false)
        let divider = NativeUI.separator()
        let stack = NativeUI.stack([stage, heading, content, divider, footer], spacing: 16)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for wide in [heading, content, divider, footer] { wide.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    private func modify(_ update: (inout ModificationStep) -> Void) { guard model.loaded, var step = model.selectedStep else { return }; update(&step); replace(step) }
    private func replace(_ step: ModificationStep) {
        guard model.loaded, var workflow = model.workflow else { return }
        if model.editingResponse, let index = workflow.responseSteps.firstIndex(where: { $0.id == step.id }) { workflow.responseSteps[index] = step }
        if !model.editingResponse, let index = workflow.requestSteps.firstIndex(where: { $0.id == step.id }) { workflow.requestSteps[index] = step }
        model.updateWorkflow(workflow)
    }
    func move(_ offset: Int) {
        guard model.loaded, var workflow = model.workflow else { return }
        var steps = model.editingResponse ? workflow.responseSteps : workflow.requestSteps
        guard let index = steps.firstIndex(where: { $0.id == model.selectedStepID }), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
        if model.editingResponse { workflow.responseSteps = steps } else { workflow.requestSteps = steps }; model.updateWorkflow(workflow)
    }
    private func remove() {
        guard model.loaded, var workflow = model.workflow else { return }
        if model.editingResponse { workflow.responseSteps.removeAll { $0.id == model.selectedStepID } } else { workflow.requestSteps.removeAll { $0.id == model.selectedStepID } }
        model.updateWorkflow(workflow); model.selectedStepID = nil
    }
}
