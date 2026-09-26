import AppKit
import RequestmanCore

@MainActor
final class ConnectionSettingsView: NSView {
    private let model: WorkspaceModel
    private lazy var port = ActionTextField(placeholder: "端口") { [weak self] value in
        guard let self, let number = Int(value) else { return }
        self.model.document.proxy.port = number
    }
    private lazy var host = ActionTextField(placeholder: "主机") { [weak self] value in
        guard let self, case .httpProxy(var endpoint) = self.model.document.proxy.upstream else { return }
        endpoint.host = value
        self.model.document.proxy.upstream = .httpProxy(endpoint)
    }
    private lazy var upstreamPort = ActionTextField(placeholder: "端口") { [weak self] value in
        guard let self, let number = Int(value), case .httpProxy(var endpoint) = self.model.document.proxy.upstream else { return }
        endpoint.port = number
        self.model.document.proxy.upstream = .httpProxy(endpoint)
    }
    private let proxySwitch = NSSwitch()
    private var upstreamRows: [NSView] = []
    private let errorLabel = SettingsUI.note("")
    private let httpsLabel = NativeUI.label("", secondary: true)

    init(model: WorkspaceModel) {
        self.model = model
        super.init(frame: .zero)
        proxySwitch.target = self
        proxySwitch.action = #selector(toggleProxy)
        proxySwitch.setAccessibilityLabel("使用 HTTP 上游代理")
        port.widthAnchor.constraint(equalToConstant: 140).isActive = true
        upstreamPort.widthAnchor.constraint(equalToConstant: 140).isActive = true
        host.widthAnchor.constraint(equalToConstant: 260).isActive = true
        port.setAccessibilityLabel("本地代理端口")
        host.setAccessibilityLabel("上游代理主机")
        upstreamPort.setAccessibilityLabel("上游代理端口")
        upstreamRows = [SettingsUI.row("主机", host), SettingsUI.row("端口", upstreamPort)]
        errorLabel.textColor = .systemRed
        let sections = [
            SettingsUI.section("本地代理", rows: [SettingsUI.row("监听地址", NativeUI.label("127.0.0.1", secondary: true)), SettingsUI.row("端口", port)], footer: "修改系统代理可能需要管理员授权。"),
            SettingsUI.section("连接方式", rows: [SettingsUI.row("使用 HTTP 上游代理", proxySwitch)] + upstreamRows, footer: "可接入 Surge 等 HTTP 代理，需填写地址与端口。"),
            errorLabel,
            SettingsUI.section("协议支持", rows: [SettingsUI.row("HTTP/1.1", NativeUI.label("请求与响应修改、Mock、记录", secondary: true)), SettingsUI.row("HTTPS", httpsLabel)], footer: "暂不支持异步脚本、辅助请求、断点及按应用透明接管。")
        ]
        let stack = NativeUI.stack(sections, spacing: 18)
        stack.alignment = .leading
        sections.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NativeUI.pin(stack, to: self)
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let editable = model.loaded && !model.isTransitioning
        port.isEnabled = editable
        host.isEnabled = editable
        upstreamPort.isEnabled = editable
        proxySwitch.isEnabled = editable
        SettingsUI.sync(port, String(model.document.proxy.port))
        if case .httpProxy(let endpoint) = model.document.proxy.upstream {
            proxySwitch.state = .on
            upstreamRows.forEach { $0.isHidden = false }
            SettingsUI.sync(host, endpoint.host)
            SettingsUI.sync(upstreamPort, String(endpoint.port))
        } else {
            proxySwitch.state = .off
            upstreamRows.forEach { $0.isHidden = true }
        }
        errorLabel.stringValue = model.proxyConfigurationError ?? ""
        errorLabel.isHidden = model.proxyConfigurationError == nil
        httpsLabel.stringValue = model.certificateSetup.isConfigured ? "解密、修改、Mock、记录" : "仅透传，需配置 HTTPS 证书"
    }

    @objc private func toggleProxy() {
        model.document.proxy.upstream = proxySwitch.state == .on
            ? .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152)) : .system
    }
}
