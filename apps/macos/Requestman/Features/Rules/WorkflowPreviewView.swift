import SwiftUI
import RequestmanCore

struct WorkflowPreviewView: View {
    let workflow: RequestWorkflow
    let environment: WorkspaceEnvironment?
    @Environment(\.dismiss) private var dismiss
    @State private var result = "输入实际 URL 后运行预览。不会发送网络请求。"
    @State private var input = ScriptPreviewInput()
    @State private var showsInput = false
    @State private var running = false
    @State private var execution: ScriptExecutionControl?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("预览流程").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            TextField("测试 URL", text: $input.url).textFieldStyle(.roundedBorder)
            HStack {
                Button("请求与响应输入…") { showsInput = true }
                Button(running ? "运行中…" : "运行预览") { run() }.disabled(running)
            }
            ScrollView { Text(result).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
        }.padding(24).frame(width: 680, height: 500)
        .onDisappear { execution?.cancel() }
        .sheet(isPresented: $showsInput) { ScriptPreviewInputView(input: $input, response: true) }
    }
    private func run() {
        let workflow = workflow, environment = environment, input = input
        let control = ScriptExecutionControl()
        execution = control
        running = true
        Task {
            result = await Task.detached(priority: .userInitiated) {
                do {
                    guard workflow.matches(method: input.method, url: input.url) else { return "此输入未命中匹配条件。" }
                    var request = try input.request()
                    let id = UUID(), date = Date()
                    var trace = try WorkflowEngine.apply(workflow.requestSteps, response: false, to: &request, environment: environment?.values ?? [:], id: id, date: date, control: control)
                    var response = request.isMock ? request : try input.response()
                    trace += try WorkflowEngine.apply(workflow.responseSteps, response: true, to: &response, environment: environment?.values ?? [:], id: id, date: date, request: request, control: control)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    return trace.joined(separator: " → ") + "\n\n请求\n" + String(decoding: try encoder.encode(ScriptMessage(request, response: false)), as: UTF8.self)
                        + "\n\n响应\n" + String(decoding: try encoder.encode(ScriptMessage(response, response: true)), as: UTF8.self)
                } catch { return "无法执行：\(error.localizedDescription)" }
            }.value
            running = false
        }
    }
}
