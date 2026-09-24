import SwiftUI

struct ConnectionSettingsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Form {
            Section {
                Toggle("使用 HTTP 上游代理", isOn: $model.usesHTTPProxy)
                if model.usesHTTPProxy {
                    TextField("主机", text: $model.proxyHost)
                    TextField("端口", text: $model.proxyPort)
                    if let message = model.connectionValidationMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("连接方式")
            } footer: {
                Text("关闭时沿用系统路由，仍可能经过 Surge 增强模式。开启时计划将真实请求交给指定代理；请按 Surge 实际监听地址填写。")
            }

            Section("当前状态") {
                LabeledContent("流量捕获", value: "尚未接入")
                LabeledContent("HTTPS 解密", value: "尚未接入")
                Text("此处为配置草稿，仅在本次运行中保留，不会修改系统代理、Surge 设置或证书。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
