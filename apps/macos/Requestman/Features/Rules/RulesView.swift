import AppKit
import SwiftUI
import RequestmanCore

struct ProjectSidebarView: View {
    @Bindable var model: WorkspaceModel
    @Binding var search: String
    @State private var collapsedProjects: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedWorkflowID) {
                ForEach($model.document.projects) { $project in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsedProjects.contains(project.id) },
                        set: { expanded in
                            if expanded { collapsedProjects.remove(project.id) }
                            else { collapsedProjects.insert(project.id) }
                        }
                    )) {
                        ForEach(project.workflows.filter(matchesSearch)) { workflow in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(workflow.name).lineLimit(1)
                                    Text("\(workflow.method) · \(workflow.urlPrefix)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } icon: {
                                Image(systemName: workflow.enabled ? "doc.text" : "pause.circle")
                            }
                            .tag(workflow.id)
                            .contextMenu {
                                Button("复制") { model.duplicateWorkflow(workflow, projectID: project.id) }
                                Button("删除", role: .destructive) { model.deleteWorkflow(workflow.id) }
                            }
                        }
                        Button("添加请求修改", systemImage: "plus") {
                            model.addWorkflow(projectID: project.id)
                        }.buttonStyle(.borderless)
                    } label: {
                        Label {
                            TextField("项目名称", text: $project.name).textFieldStyle(.plain)
                        } icon: { Image(systemName: "folder") }
                    }
                    .contextMenu {
                        Button("添加请求修改") { model.addWorkflow(projectID: project.id) }
                        Button("删除项目", role: .destructive) {
                            let id = project.id
                            model.document.projects.removeAll { $0.id == id }
                            if model.workflow == nil {
                                model.selectedWorkflowID = nil
                                model.selectedStepID = nil
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            ProjectSidebarControls(search: $search, addRequest: addRequest, addProject: model.addProject)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .disabled(!model.loaded)
    }

    private func addRequest() {
        let project = model.document.projects.first {
            $0.workflows.contains { $0.id == model.selectedWorkflowID }
        } ?? model.document.projects.first
        search = ""
        if let project {
            collapsedProjects.remove(project.id)
            model.addWorkflow(projectID: project.id)
        } else {
            model.addProject()
        }
    }

    private func matchesSearch(_ workflow: RequestWorkflow) -> Bool {
        search.isEmpty || workflow.name.localizedCaseInsensitiveContains(search)
            || workflow.urlPrefix.localizedCaseInsensitiveContains(search)
    }
}

private struct ProjectSidebarControls: NSViewRepresentable {
    @Binding var search: String
    let addRequest: () -> Void
    let addProject: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ControlsView {
        let view = ControlsView()
        view.searchField.delegate = context.coordinator
        view.addButton.target = context.coordinator
        view.addButton.action = #selector(Coordinator.showMenu(_:))
        return view
    }

    func updateNSView(_ view: ControlsView, context: Context) {
        context.coordinator.parent = self
        if view.searchField.stringValue != search { view.searchField.stringValue = search }
        view.searchField.isEnabled = context.environment.isEnabled
        view.addButton.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ControlsView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: nsView.fittingSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ProjectSidebarControls
        init(parent: ProjectSidebarControls) { self.parent = parent }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            let request = menu.addItem(withTitle: "添加请求", action: #selector(addRequest), keyEquivalent: "")
            request.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            request.target = self
            let project = menu.addItem(withTitle: "添加项目", action: #selector(addProject), keyEquivalent: "")
            project.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            project.target = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
        }

        @objc func addRequest() { parent.addRequest() }
        @objc func addProject() { parent.addProject() }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.search = field.stringValue
        }
    }

    final class ControlsView: NSView {
        let searchField = NSSearchField()
        let addButton = NSButton()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            searchField.controlSize = .large
            searchField.placeholderString = "搜索请求修改"
            searchField.setAccessibilityLabel("搜索请求修改")
            searchField.sendsSearchStringImmediately = true
            searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            addButton.title = ""
            addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加")
            addButton.imagePosition = .imageOnly
            addButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            addButton.setButtonType(.momentaryPushIn)
            addButton.controlSize = .large
            if #available(macOS 26.0, *) {
                addButton.bezelStyle = .glass
                addButton.borderShape = .circle
            } else {
                addButton.bezelStyle = .circular
            }
            addButton.toolTip = "添加"
            addButton.setAccessibilityLabel("添加")

            for control in [addButton, searchField] as [NSControl] {
                control.translatesAutoresizingMaskIntoConstraints = false
                addSubview(control)
            }
            // Align AppKit alignment rects instead of mixing SwiftUI and AppKit frames.
            NSLayoutConstraint.activate([
                searchField.heightAnchor.constraint(equalToConstant: searchField.intrinsicContentSize.height),
                searchField.topAnchor.constraint(equalTo: topAnchor),
                searchField.bottomAnchor.constraint(equalTo: bottomAnchor),
                searchField.trailingAnchor.constraint(equalTo: trailingAnchor),
                searchField.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 10),
                addButton.leadingAnchor.constraint(equalTo: leadingAnchor),
                addButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
                addButton.heightAnchor.constraint(equalTo: searchField.heightAnchor),
                addButton.widthAnchor.constraint(equalTo: addButton.heightAnchor)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

struct RulesView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Group {
            if let workflow = model.workflow {
                FlowEditorView(model: model, workflow: Binding(get: { model.workflow ?? workflow }, set: model.updateWorkflow))
            } else {
                ContentUnavailableView {
                    Label("编排一次，自动处理每次请求", systemImage: "point.3.connected.trianglepath.dotted")
                } description: { Text("在项目中创建请求修改，设置匹配条件，再添加请求和响应步骤。") }
                actions: { Button("新建项目", action: model.addProject).disabled(!model.loaded) }
            }
        }
        .disabled(!model.loaded)
        .onChange(of: model.selectedWorkflowID) { _, _ in model.selectedStepID = nil }
    }
}

private struct FlowEditorView: View {
    @Bindable var model: WorkspaceModel
    @Binding var workflow: RequestWorkflow
    @State private var showsPreview = false
    @State private var showsInspector = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("名称", text: $workflow.name)
                Toggle("启用请求修改", isOn: $workflow.enabled)
                Picker("方法", selection: $workflow.method) {
                    ForEach(["*", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                }
                TextField("匹配 URL 前缀", text: $workflow.urlPrefix)
            }
            .formStyle(.columns)
            .textFieldStyle(.roundedBorder)
            .padding(20)
            HStack {
                Text(model.projectName).foregroundStyle(.secondary)
                Button("预览流程", systemImage: "play") { showsPreview = true }
                Button("步骤详情", systemImage: "sidebar.right") { showsInspector.toggle() }
                    .help(showsInspector ? "隐藏步骤详情" : "显示步骤详情")
                Spacer()
            }.padding(.horizontal, 20).padding(.bottom, 12)
            HStack(spacing: 16) {
                lane(response: false)
                lane(response: true)
            }.padding([.horizontal, .bottom], 20)
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: $showsInspector) {
            StepInspectorView(model: model, workflow: $workflow)
                .inspectorColumnWidth(min: 270, ideal: 315, max: 390)
        }
        .onChange(of: model.selectedStepID) { _, id in
            if id != nil { showsInspector = true }
        }
        .sheet(isPresented: $showsPreview) { WorkflowPreviewView(workflow: workflow, environment: model.document.environment) }
    }

    private func lane(response: Bool) -> some View {
        let steps = response ? workflow.responseSteps : workflow.requestSteps
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(response ? "服务器 → Chrome" : "Chrome → 服务器")
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: stepSelection(response: response)) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(step.kind.title)
                                Text(step.name.isEmpty ? (step.value.isEmpty ? "点击配置" : step.value) : step.name)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if !step.enabled { Image(systemName: "pause.circle").accessibilityLabel("已停用") }
                        }.tag(step.id)
                    }
                }.listStyle(.inset)
                Menu("添加步骤", systemImage: "plus") {
                    ForEach(ModificationKind.allCases.filter { $0.supports(response: response) }, id: \.self) { kind in
                        Button(kind.title) { model.addStep(kind, response: response) }
                    }
                }.fixedSize()
                Text(response ? "返回 Chrome" : "发送到目标 / 返回 Mock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Label(response ? "响应流程" : "请求流程", systemImage: response ? "arrow.left" : "arrow.right")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepSelection(response: Bool) -> Binding<UUID?> {
        Binding(
            get: { model.editingResponse == response ? model.selectedStepID : nil },
            set: { id in
                if let id {
                    model.editingResponse = response
                    model.selectedStepID = id
                } else if model.editingResponse == response {
                    model.selectedStepID = nil
                }
            }
        )
    }
}

private struct StepInspectorView: View {
    @Bindable var model: WorkspaceModel
    @Binding var workflow: RequestWorkflow
    private var steps: [ModificationStep] { model.editingResponse ? workflow.responseSteps : workflow.requestSteps }

    var body: some View {
        if let stepID = model.selectedStepID,
           let index = steps.firstIndex(where: { $0.id == stepID }) {
            let binding = Binding<ModificationStep>(
                get: { steps.first { $0.id == stepID } ?? ModificationStep(kind: .setHeader) },
                set: { value in
                    if model.editingResponse {
                        if let position = workflow.responseSteps.firstIndex(where: { $0.id == stepID }) {
                            workflow.responseSteps[position] = value
                        }
                    } else if let position = workflow.requestSteps.firstIndex(where: { $0.id == stepID }) {
                        workflow.requestSteps[position] = value
                    }
                }
            )
            Form {
                Section("\(model.editingResponse ? "响应" : "请求")流程 · 步骤 \(index + 1)") {
                    LabeledContent("动作", value: binding.wrappedValue.kind.title)
                    StepFields(step: binding)
                }
                Section("顺序") {
                    HStack {
                        Button("上移", systemImage: "arrow.up") { move(index, offset: -1) }.disabled(index == 0)
                        Button("下移", systemImage: "arrow.down") { move(index, offset: 1) }.disabled(index == steps.count - 1)
                    }
                    Button("删除步骤", role: .destructive) {
                        if model.editingResponse { workflow.responseSteps.removeAll { $0.id == stepID } }
                        else { workflow.requestSteps.removeAll { $0.id == stepID } }
                        model.selectedStepID = nil
                    }
                }
                Section("动态值") {
                    LabeledContent("环境变量", value: "{{env.apiKey}}")
                    LabeledContent("请求标识", value: "{{$uuid}}")
                    LabeledContent("Unix 时间戳", value: "{{$timestamp}}")
                }.font(.caption).textSelection(.enabled)
            }.formStyle(.grouped)
        } else {
            ContentUnavailableView("选择一个步骤", systemImage: "slider.horizontal.3", description: Text("配置请求或响应的修改动作。"))
        }
    }

    private func move(_ index: Int, offset: Int) {
        if model.editingResponse { workflow.responseSteps.swapAt(index, index + offset) }
        else { workflow.requestSteps.swapAt(index, index + offset) }
    }
}

private struct StepFields: View {
    @Binding var step: ModificationStep
    var body: some View {
        Toggle("启用步骤", isOn: $step.enabled)
        if [.setHeader, .removeHeader].contains(step.kind) {
            TextField("Header 名称", text: $step.name)
        }
        if [.mock, .setStatus, .redirect].contains(step.kind) {
            TextField("状态码", value: $step.status, format: .number.grouping(.never))
        }
        if ![.removeHeader, .setStatus].contains(step.kind) {
            if [.replaceBody, .mock].contains(step.kind) {
                LabeledContent("Body · 文本 / 模板") {
                    TextEditor(text: $step.value)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                }.labeledContentStyle(.automatic)
            } else {
                TextField("值 / 模板", text: $step.value, axis: .vertical).lineLimit(2...6)
            }
        }
    }
}

private struct WorkflowPreviewView: View {
    let workflow: RequestWorkflow
    let environment: WorkspaceEnvironment?
    @Environment(\.dismiss) private var dismiss
    @State private var result = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("预览流程").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("使用匹配地址和当前环境计算步骤，不发送网络请求。响应步骤基于空的 200 响应预览。").font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(result).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
        }.padding(24).frame(width: 630, height: 440).task {
            do {
                let id = UUID(), date = Date()
                var draft = HTTPMessageDraft(method: workflow.method == "*" ? "GET" : workflow.method, url: workflow.urlPrefix)
                var trace = try WorkflowEngine.apply(workflow.requestSteps, response: false, to: &draft, environment: environment?.values ?? [:], id: id, date: date)
                result = "\(draft.method) \(draft.url)\n" + draft.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
                if !draft.isMock { draft = HTTPMessageDraft(method: draft.method, url: draft.url) }
                trace += try WorkflowEngine.apply(workflow.responseSteps, response: true, to: &draft, environment: environment?.values ?? [:], id: id, date: date)
                result += "\n\n响应 \(draft.status)\n" + draft.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
                result += "\n\(draft.replacementBody ?? "Body 流式透传")\n\n" + trace.joined(separator: " → ")
            } catch { result = "无法执行：\(error.localizedDescription)" }
        }
    }
}
