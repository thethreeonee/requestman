import SwiftUI
import RequestmanCore

struct StepInspectorView: View {
    @Bindable var model: WorkspaceModel
    var isPresented = true

    var body: some View {
        if let workflow = model.workflow, let selected = model.selectedStep,
           let index = (model.editingResponse ? workflow.responseSteps : workflow.requestSteps).firstIndex(where: { $0.id == selected.id }) {
            let binding = Binding<ModificationStep>(get: { model.selectedStep ?? selected }, set: { value in
                guard var current = model.workflow else { return }
                if model.editingResponse, let position = current.responseSteps.firstIndex(where: { $0.id == value.id }) { current.responseSteps[position] = value }
                if !model.editingResponse, let position = current.requestSteps.firstIndex(where: { $0.id == value.id }) { current.requestSteps[position] = value }
                model.updateWorkflow(current)
            })
            VStack(alignment: .leading, spacing: 16) {
                Text("\(model.editingResponse ? "响应" : "请求")阶段 · 第 \(index + 1) 步").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(selected.kind.title).font(.title2.bold())
                    Spacer()
                    Toggle("启用", isOn: binding.enabled).toggleStyle(.switch).fixedSize()
                }
                if selected.kind == .script {
                    ScriptEditorView(step: binding, isPresented: isPresented, response: model.editingResponse, environment: model.document.environment?.values ?? [:])
                        .id(selected.id)
                } else {
                    Form {
                        StepFields(step: binding)
                        Section("动态值") {
                            Text("{{env.apiKey}}\n{{$uuid}}\n{{$timestamp}}")
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }.formStyle(.grouped)
                }
                Divider()
                HStack {
                    Button("上移", systemImage: "arrow.up") { move(index, offset: -1) }.disabled(index == 0)
                    Button("下移", systemImage: "arrow.down") { move(index, offset: 1) }
                        .disabled(index + 1 == (model.editingResponse ? workflow.responseSteps.count : workflow.requestSteps.count))
                    Spacer()
                    Button("删除", systemImage: "trash", role: .destructive) {
                        guard var current = model.workflow else { return }
                        if model.editingResponse { current.responseSteps.removeAll { $0.id == selected.id } }
                        else { current.requestSteps.removeAll { $0.id == selected.id } }
                        model.updateWorkflow(current); model.selectedStepID = nil
                    }
                }.controlSize(.small)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("选择一个步骤", systemImage: "slider.horizontal.3", description: Text("配置请求或响应的修改动作。"))
        }
    }

    private func move(_ index: Int, offset: Int) {
        guard var workflow = model.workflow else { return }
        if model.editingResponse { workflow.responseSteps.swapAt(index, index + offset) }
        else { workflow.requestSteps.swapAt(index, index + offset) }
        model.updateWorkflow(workflow)
    }
}

private struct StepFields: View {
    @Binding var step: ModificationStep
    var body: some View {
        if [.setHeader, .removeHeader].contains(step.kind) {
            LabeledContent("Header 名称") { HeaderNameField(name: $step.name).frame(minWidth: 170) }
            if step.kind == .setHeader {
                Text("不存在时添加；存在时覆盖。名称不区分大小写，同名多项会替换为一项。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if WorkflowEngine.managedHeaders.contains(step.name.lowercased()) {
                Text("此 Header 由代理维护。请通过目标地址或 Body 步骤修改。")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        if [.mock, .setStatus, .redirect].contains(step.kind) {
            TextField("状态码", value: $step.status, format: .number.grouping(.never))
        }
        if ![.removeHeader, .setStatus].contains(step.kind) {
            if [.replaceBody, .mock].contains(step.kind) {
                Text("Body · 文本 / 模板").font(.callout)
                TextEditor(text: $step.value).font(.system(.body, design: .monospaced)).frame(minHeight: 200)
            } else {
                TextField("值 / 模板", text: $step.value, axis: .vertical).lineLimit(2...6)
            }
        }
    }
}
