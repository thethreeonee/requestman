import AppKit
import SwiftUI
import RequestmanCertificates

struct CertificateSetupView: View {
    @Bindable var model: CertificateSetupModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.phase == .complete ? "HTTPS 证书已配置" : "HTTPS 证书设置")
                    .font(.title2.bold())
                Text(model.phase == .complete
                     ? "证书已信任，新建 HTTPS 连接将自动解密。"
                     : "自动生成、安装并信任本机调试证书。系统请求授权时，请按提示确认。")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 18) {
                step("生成证书", detail: "私钥保存在本机钥匙串。",
                     complete: model.status?.generated == true, active: model.phase == .generating)
                step("安装证书", detail: "安装到当前用户的钥匙串。",
                     complete: model.status?.installed == true, active: model.phase == .installing)
                step("信任证书", detail: "为当前用户信任 HTTPS 用途。",
                     complete: model.status?.trusted == true,
                     active: model.phase == .trusting || model.phase == .verifying)
            }

            if model.phase == .checking {
                Label("正在检查现有证书…", systemImage: "magnifyingglass")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.footnote)
                    .foregroundStyle(model.phase == .cancelled ? Color.secondary : .red)
                    .textSelection(.enabled)
            }
            if model.phase == .complete {
                Text("已有透传连接需重新连接；请刷新页面，必要时重新打开调试浏览器。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let status = model.status, let fingerprint = status.fingerprint {
                DisclosureGroup("证书详情") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.displayName)
                        if let expiry = status.expiresAt {
                            Text("有效期至 \(expiry.formatted(date: .numeric, time: .omitted))")
                        }
                        Text("SHA-256：\(fingerprint)").textSelection(.enabled)
                    }.font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }

            HStack {
                if model.phase == .failed {
                    Button("打开钥匙串访问") { openKeychainAccess() }
                }
                Spacer()
                Button(model.phase == .complete ? "完成" : "关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                if model.canRegenerate && !model.isRunning {
                    Button("重新生成证书") { Task { await model.regenerate() } }
                        .keyboardShortcut(.defaultAction)
                } else if model.phase == .failed || model.phase == .cancelled {
                    Button("继续设置") { Task { await model.run() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isRunning)
        .task { await model.run() }
    }

    private func step(_ title: String, detail: String, complete: Bool, active: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(complete ? Color.green : .secondary)
                }
            }.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func openKeychainAccess() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.open(url)
        }
    }
}
