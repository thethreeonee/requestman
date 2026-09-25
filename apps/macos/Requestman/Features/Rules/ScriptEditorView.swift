import SwiftUI
import RequestmanCore

struct ScriptEditorView: View {
    @Binding var step: ModificationStep
    let isPresented: Bool
    let response: Bool
    let environment: [String: String]
    @State private var tab = 0
    @State private var showsHelp = false
    @State private var showsInput = false
    @State private var running = false
    @State private var execution: ScriptExecutionControl?
    @State private var result = "尚未试运行。使用示例输入，不发送网络请求。"
    @State private var sample = ScriptPreviewInput()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("步骤备注", text: $step.name).textFieldStyle(.roundedBorder)
            Picker("内容", selection: $tab) {
                Text("脚本").tag(0); Text("运行结果").tag(1)
            }.pickerStyle(.segmented)
            HStack {
                Text("JavaScript").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("API 帮助", systemImage: "questionmark.circle") { showsHelp = true }
                    .popover(isPresented: $showsHelp) { ScriptAPIHelpView() }
            }
            if tab == 0 {
                TextEditor(text: $step.value)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)
                    .frame(minHeight: 180, maxHeight: .infinity)
                    .accessibilityLabel("JavaScript 脚本")
            } else {
                ScrollView {
                    Text(result).font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(minHeight: 180, maxHeight: .infinity)
            }
            HStack {
                Button("示例输入…") { showsInput = true }
                Spacer()
                Button(running ? "运行中…" : "试运行", systemImage: "play.fill") { run() }
                    .disabled(running || step.value.isEmpty)
            }
            HStack {
                Text("超时时间")
                TextField("毫秒", value: timeout, format: .number.grouping(.never)).frame(width: 80)
                Text("ms").foregroundStyle(.secondary)
            }
            Text("失败时停止当前流程，并在请求日志中记录错误。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsInput) { ScriptPreviewInputView(input: $sample, response: response) }
        .onDisappear { execution?.cancel() }
        .onChange(of: isPresented) { _, value in if !value { showsHelp = false } }
        .onChange(of: step.value) { _, _ in result = "脚本已更改，请重新试运行。" }
        .onChange(of: environment) { _, _ in result = "环境已更改，请重新试运行。" }
    }
    private var timeout: Binding<Int> {
        Binding(get: { (step.scriptOptions ?? ScriptOptions()).timeoutMilliseconds }, set: {
            var options = step.scriptOptions ?? ScriptOptions(); options.timeoutMilliseconds = $0; step.scriptOptions = options
        })
    }
    private func run() {
        let current = step, sample = sample, environment = environment, response = response
        let control = ScriptExecutionControl()
        execution = control
        running = true
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                do {
                    let request = try sample.request()
                    let draft = response ? try sample.response() : request
                    let output = try WorkflowScript.run(source: current.value, draft: draft, response: response, request: request,
                        environment: environment, timeoutMilliseconds: (current.scriptOptions ?? ScriptOptions()).timeoutMilliseconds, control: control)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    return String(decoding: try encoder.encode(ScriptMessage(output, response: response)), as: UTF8.self)
                } catch { return "执行失败：\(error.localizedDescription)" }
            }.value
            running = false
            guard current == step, self.environment == environment else { return }
            result = output; tab = 1
        }
    }
}

struct ScriptAPIHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("脚本 API").font(.title2.bold())
                Text("脚本是一段同步 JavaScript 函数体。请求阶段 return request；响应阶段 return response。不会展开 {{env.*}}，请直接读取 env。")
                Text("""
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
                """).font(.system(.callout, design: .monospaced))
                Text("请求阶段：request 是前序步骤处理后的请求，response 为 null。响应阶段：response 是前序步骤处理后的响应，request 是只读的发出请求快照；env 始终只读。")
                Text("headers 是数组，保留原始大小写与重复 Header（例如 Set-Cookie）。比较名称时请忽略大小写。添加：headers.push({ name: 'X-Debug', value: 'true' })；删除：headers = headers.filter(h => h.name.toLowerCase() !== 'x-debug')。")
                Text("body 是完整的 UTF-8 文本，不会自动转换为 JSON。使用 JSON.parse / JSON.stringify 处理 JSON。空正文是空字符串；二进制、无法解码的正文或不可用的请求快照为 null；gzip / deflate 会先解压。返回 null 保留原正文，返回空字符串清空正文；修改文本后由代理更新长度与编码 Header。")
                Text("url 必须为完整 HTTP/HTTPS URL。method 不支持 CONNECT、TRACE。status 为 200–599 整数。Host、Content-Length、Transfer-Encoding、Connection、Upgrade、Trailer 由代理维护，可读取但不能修改。")
                Text("每个脚本默认 1000 ms（可设 50–5000 ms），同时受请求事务 30 秒时限约束。超时、抛错或返回格式无效会停止流程并记录错误。运行环境不提供 fetch、DOM、Node.js、定时器或 Promise 异步执行。")
                Text("""
                // 响应阶段：修改 JSON
                const body = JSON.parse(response.body);
                body.data.debug = true;
                response.body = JSON.stringify(body);
                return response;
                """).font(.system(.callout, design: .monospaced))
            }.padding(20).textSelection(.enabled)
        }.frame(width: 560, height: 620)
    }
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

struct ScriptPreviewInputView: View {
    @Binding var input: ScriptPreviewInput
    let response: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack { Text("试运行输入").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Form {
                TextField("URL", text: $input.url)
                TextField("方法", text: $input.method)
                TextField("请求 Header 数组（JSON）", text: $input.requestHeaders, axis: .vertical)
                TextField("请求 Body（文本）", text: $input.requestBody, axis: .vertical)
                if response {
                    TextField("状态码", value: $input.status, format: .number.grouping(.never))
                    TextField("响应 Header 数组（JSON）", text: $input.responseHeaders, axis: .vertical)
                    TextField("响应 Body（文本）", text: $input.responseBody, axis: .vertical)
                }
            }.formStyle(.grouped)
            Text("仅使用这些输入和当前环境，不发送网络请求。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 600, height: 480)
    }
}
