import AppKit
import SwiftUI
import RequestmanCore

struct FlowEditorView: View {
    @Bindable var model: WorkspaceModel
    @Binding var workflow: RequestWorkflow
    @State private var showsPreview = false
    private let stepHeight: CGFloat = 56
    private let stepVerticalInset: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(model.projectName).font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("请求修改名称", text: $workflow.name).font(.title.bold()).textFieldStyle(.plain)
                Toggle("已启用", isOn: $workflow.enabled).toggleStyle(.switch).fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("匹配目标").gridColumnAlignment(.trailing)
                        FlowMatchPicker(title: "匹配目标", options: WorkflowMatchTarget.allCases.map { ($0.title, $0) }, selection: $workflow.matchTarget)
                            .frame(width: 130)
                        HStack(spacing: 8) {
                            Text("方法").fixedSize()
                            FlowMatchPicker(title: "方法", options: ["*", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].map { ($0 == "*" ? "全部" : $0, $0) }, selection: $workflow.method)
                                .frame(width: 105)
                            Spacer(minLength: 0)
                        }
                    }
                    GridRow {
                        Text("匹配规则")
                        FlowMatchPicker(title: "匹配规则", options: WorkflowMatchRule.allCases.map { ($0.title, $0) }, selection: $workflow.matchRule)
                            .frame(width: 130)
                        TextField(workflow.matchTarget == .url ? "https://api.example.com/orders/*" : "*.example.com", text: $workflow.matchPattern)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("匹配值")
                    }
                }
                if let error = WorkflowMatcher.validationError(rule: workflow.matchRule, pattern: workflow.matchPattern) {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text(workflow.matchTarget == .host ? "仅匹配域名，不包含协议、端口和路径；不区分大小写。" : "匹配完整 URL，区分大小写。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                lane(response: false)
                lane(response: true)
            }
            Button("预览流程", systemImage: "play") { showsPreview = true }
        }
        .padding(24)
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showsPreview) { WorkflowPreviewView(workflow: workflow, environment: model.document.environment) }
    }

    private func lane(response: Bool) -> some View {
        let steps = response ? workflow.responseSteps : workflow.requestSteps
        return VStack(alignment: .leading, spacing: 12) {
            Label(response ? "响应阶段" : "请求阶段", systemImage: response ? "arrow.left" : "arrow.right").font(.headline)
            Text(response ? "服务器 → 客户端" : "客户端 → 服务器").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                List {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(step, index: index, response: response)
                            .listRowInsets(EdgeInsets(top: stepVerticalInset, leading: 0, bottom: stepVerticalInset, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(step.enabled ? "停用" : "启用") { modify(step.id, response: response) { $0.enabled.toggle() } }
                                Button("删除步骤", role: .destructive) { remove(step.id, response: response) }
                            }
                    }
                    .onMove { from, to in
                        if response { workflow.responseSteps.move(fromOffsets: from, toOffset: to) }
                        else { workflow.requestSteps.move(fromOffsets: from, toOffset: to) }
                    }
                }
                .listStyle(.plain)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, stepHeight + stepVerticalInset * 2)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(max(steps.count, 1)) * (stepHeight + stepVerticalInset * 2), 400))
                .onMoveCommand { direction in
                    guard !steps.isEmpty, direction == .up || direction == .down else { return }
                    let current = model.editingResponse == response
                        ? steps.firstIndex { $0.id == model.selectedStepID } : nil
                    let next = current.map { min(max($0 + (direction == .down ? 1 : -1), 0), steps.count - 1) }
                        ?? (direction == .down ? 0 : steps.count - 1)
                    select(steps[next].id, response: response)
                }
                Menu("添加步骤", systemImage: "plus") {
                    ForEach(ModificationKind.allCases.filter { $0.supports(response: response) }, id: \.self) { kind in
                        Button(kind.title) { model.addStep(kind, response: response) }
                    }
                }.fixedSize()
            }
            .padding(10)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func stepRow(_ step: ModificationStep, index: Int, response: Bool) -> some View {
        let isSelected = model.editingResponse == response && model.selectedStepID == step.id
        return Button {
            select(step.id, response: response)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Text("\(index + 1)")
                    .monospacedDigit()
                    .frame(width: 26, height: 28)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 5) {
                    Text(step.kind.title).lineLimit(1).help(step.kind.title)
                    Text(summary(step)).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(summary(step))
                }
                Spacer(minLength: 0)
                if !step.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
            }
            .foregroundStyle(.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: stepHeight)
            .background(isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2).fill(.blue).frame(width: 3).padding(.vertical, 8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
    private func summary(_ step: ModificationStep) -> String {
        if step.kind == .script { return step.name.isEmpty ? "JavaScript" : step.name }
        if step.kind == .setStatus { return String(step.status) }
        return step.name.isEmpty ? (step.value.isEmpty ? "点击配置" : step.value) : step.name
    }
    private func select(_ id: UUID, response: Bool) {
        model.editingResponse = response
        model.selectedStepID = id
    }
    private func modify(_ id: UUID, response: Bool, action: (inout ModificationStep) -> Void) {
        if response, let index = workflow.responseSteps.firstIndex(where: { $0.id == id }) { action(&workflow.responseSteps[index]) }
        if !response, let index = workflow.requestSteps.firstIndex(where: { $0.id == id }) { action(&workflow.requestSteps[index]) }
    }
    private func remove(_ id: UUID, response: Bool) {
        if response { workflow.responseSteps.removeAll { $0.id == id } }
        else { workflow.requestSteps.removeAll { $0.id == id } }
        if model.selectedStepID == id { model.selectedStepID = nil }
    }
}

/// Let the native control fill the grid column instead of centering an intrinsic-width picker.
private struct FlowMatchPicker<Value: Equatable>: NSViewRepresentable {
    let title: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, options: options) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectOption(_:))
        button.autoenablesItems = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.options = options
        let titles = options.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(at: options.firstIndex { $0.value == selection } ?? -1)
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(button.selectedItem?.title ?? "")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Value>
        var options: [(title: String, value: Value)]

        init(selection: Binding<Value>, options: [(title: String, value: Value)]) {
            self.selection = selection
            self.options = options
        }

        @objc func selectOption(_ sender: NSPopUpButton) {
            guard sender.isEnabled, options.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = options[sender.indexOfSelectedItem].value
        }
    }
}
