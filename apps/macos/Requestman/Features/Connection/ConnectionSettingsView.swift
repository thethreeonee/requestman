import SwiftUI
import RequestmanCore

struct ConnectionSettingsView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsCertificateSetup = false
    private var useProxy: Binding<Bool> {
        Binding(get: { if case .httpProxy = model.document.proxy.upstream { true } else { false } }, set: {
            model.document.proxy.upstream = $0 ? .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152)) : .system
        })
    }
    var body: some View {
        Form {
            Section {
                LabeledContent("监听地址", value: "127.0.0.1")
                TextField("端口", value: $model.document.proxy.port, format: .number.grouping(.never))
            } header: {
                Text("本地代理")
            } footer: {
                Text("修改系统代理可能需要管理员授权。").font(.footnote)
            }.disabled(!model.loaded || model.isTransitioning)
            Section {
                Toggle("使用 HTTP 上游代理", isOn: useProxy)
                if case .httpProxy(let endpoint) = model.document.proxy.upstream {
                    TextField("主机", text: Binding(get: { endpoint.host }, set: { model.document.proxy.upstream = .httpProxy(ProxyEndpoint(host: $0, port: endpoint.port)) }))
                    TextField("端口", value: Binding(get: { endpoint.port }, set: { model.document.proxy.upstream = .httpProxy(ProxyEndpoint(host: endpoint.host, port: $0)) }), format: .number.grouping(.never))
                }
            } header: {
                Text("连接方式")
            } footer: {
                Text("可接入 Surge 等 HTTP 代理，需填写地址与端口。").font(.footnote)
            }.disabled(!model.loaded || model.isTransitioning)
            if let error = model.proxyConfigurationError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Section {
                LabeledContent("HTTP/1.1", value: "请求与响应修改、Mock、记录")
                LabeledContent("HTTPS") {
                    HStack(spacing: 12) {
                        Text(model.certificateSetup.isConfigured
                             ? "解密、修改、Mock、记录"
                             : "仅透传，需配置证书")
                            .foregroundStyle(.secondary)
                        if model.certificateSetup.isConfigured {
                            Label("已完成配置", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("设置证书…") { showsCertificateSetup = true }
                                .disabled(model.certificateSetup.isRunning)
                        }
                    }
                }
            } header: {
                Text("协议支持")
            } footer: {
                Text("暂不支持脚本、辅助请求、断点及按应用透明接管。").font(.footnote)
            }
        }.formStyle(.grouped)
            .task { await model.certificateSetup.refreshStatus() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !showsCertificateSetup {
                    Task { await model.certificateSetup.refreshStatus() }
                }
            }
            .sheet(isPresented: $showsCertificateSetup) {
                CertificateSetupView(model: model.certificateSetup)
            }
    }
}
