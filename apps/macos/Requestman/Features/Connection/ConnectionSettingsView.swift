import SwiftUI
import RequestmanCore

struct ConnectionSettingsView: View {
    @Bindable var model: WorkspaceModel
    private var useProxy: Binding<Bool> {
        Binding(get: { if case .httpProxy = model.document.proxy.upstream { true } else { false } }, set: {
            model.document.proxy.upstream = $0 ? .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152)) : .system
        })
    }
    var body: some View {
        Form {
            Section("本地代理") {
                LabeledContent("监听地址", value: "127.0.0.1")
                TextField("端口", value: $model.document.proxy.port, format: .number.grouping(.never))
                Text("修改监听与上游配置后，需要停止并重新开始捕获。").font(.caption).foregroundStyle(.secondary)
                Text("开始监听会将系统 HTTP 和 HTTPS 代理设为 Requestman，可能需要管理员授权；停止或退出时恢复原设置。仅接入遵循系统代理的应用。").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.isCapturing || model.isTransitioning)
            Section("Chrome 接入") {
                Button {
                    Task { await model.launchChromeAndCapture() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isLaunchingChrome { ProgressView().controlSize(.small) }
                        else { Image(systemName: "play.fill") }
                        Text(model.isCheckingUpstream ? "正在检查上游代理…" : (model.isLaunchingChrome ? "正在启动…" : "启动 Chrome 并开始监听"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.loaded || model.isTransitioning)
                Text("使用专用 Chrome 配置打开调试窗口。").font(.caption).foregroundStyle(.secondary)
                if let error = model.chromeLaunchError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                }
            }
            Section("连接方式") {
                Toggle("使用 HTTP 上游代理", isOn: useProxy)
                Text("开启后，请求经 Requestman 转发到上游。使用 Surge 时填写其 HTTP 代理地址与端口。").font(.caption).foregroundStyle(.secondary)
                if case .httpProxy(let endpoint) = model.document.proxy.upstream {
                    TextField("主机", text: Binding(get: { endpoint.host }, set: { model.document.proxy.upstream = .httpProxy(ProxyEndpoint(host: $0, port: endpoint.port)) }))
                    TextField("端口", value: Binding(get: { endpoint.port }, set: { model.document.proxy.upstream = .httpProxy(ProxyEndpoint(host: endpoint.host, port: $0)) }), format: .number.grouping(.never))
                }
            }.disabled(model.isCapturing || model.isTransitioning)
            Section("协议支持") {
                LabeledContent("HTTP/1.1", value: "请求与响应修改、Mock、记录")
                LabeledContent("HTTPS", value: "CONNECT 透传，尚未解密")
                Text("脚本、辅助请求、人工断点、HTTPS 解密与按应用透明接管尚未接入。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
