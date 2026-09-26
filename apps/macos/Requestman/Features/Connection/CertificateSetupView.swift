import AppKit
import RequestmanCertificates

@MainActor
final class CertificateSetupViewController: ObservedViewController {
    private let model: CertificateSetupModel
    private let heading = NativeUI.label("HTTPS 证书设置", size: 17, weight: .bold)
    private let introduction = SettingsUI.note("")
    private let checking = SettingsUI.note("正在检查现有证书…")
    private let errorLabel = SettingsUI.note("")
    private let reconnect = SettingsUI.note("已有透传连接需重新连接；请刷新页面，必要时重新打开调试浏览器。")
    private let details = SettingsUI.note("")
    private var detailSection: NSStackView!
    private let disclosure = NSButton()
    private let steps = [CertificateStepRow("生成证书", detail: "私钥保存在本机钥匙串。"),
                         CertificateStepRow("安装证书", detail: "安装到当前用户的钥匙串。"),
                         CertificateStepRow("信任证书", detail: "为当前用户信任 HTTPS 用途。")]
    private lazy var keychain = ActionButton(title: "打开钥匙串访问") {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") { NSWorkspace.shared.open(url) }
    }
    private lazy var close = ActionButton(title: "关闭") { [weak self] in
        guard let self, !self.model.isRunning else { return }
        self.dismiss(self)
    }
    private lazy var retry = ActionButton(title: "继续设置") { [weak self] in
        guard let self else { return }
        Task { @MainActor in
            if self.model.canRegenerate { await self.model.regenerate() }
            else { await self.model.run() }
        }
    }
    private var hasStarted = false

    init(model: CertificateSetupModel) {
        self.model = model
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 390))
        errorLabel.isSelectable = true
        details.isSelectable = true
        introduction.font = .systemFont(ofSize: 13)
        disclosure.setButtonType(.onOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggleDetails)
        disclosure.setAccessibilityLabel("证书详情")
        let detailHeader = NativeUI.stack([disclosure, NativeUI.label("证书详情"), NSView()], vertical: false, spacing: 6)
        detailSection = NativeUI.stack([detailHeader, details], spacing: 8)
        details.widthAnchor.constraint(equalTo: detailSection.widthAnchor).isActive = true
        close.keyEquivalent = "\u{1b}"
        retry.keyEquivalent = "\r"
        let actions = NativeUI.stack([keychain, NSView(), close, retry], vertical: false, spacing: 10)
        let header = NativeUI.stack([heading, introduction], spacing: 8)
        introduction.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        let progress = NativeUI.stack(steps, spacing: 18)
        let content = NativeUI.stack([header, progress, checking, errorLabel, reconnect, detailSection, actions], spacing: 20)
        content.alignment = .leading
        for row in content.arrangedSubviews { row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        NativeUI.pin(content, to: view, insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24))
        view.widthAnchor.constraint(equalToConstant: 480).isActive = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasStarted else { return }
        hasStarted = true
        Task { @MainActor in await model.run() }
    }

    override func refresh() {
        let complete = model.phase == .complete
        heading.stringValue = complete ? "HTTPS 证书已配置" : "HTTPS 证书设置"
        introduction.stringValue = complete ? "证书已信任，新建 HTTPS 连接将自动解密。" : "自动生成、安装并信任本机调试证书。系统请求授权时，请按提示确认。"
        steps[0].update(complete: model.status?.generated == true, active: model.phase == .generating)
        steps[1].update(complete: model.status?.installed == true, active: model.phase == .installing)
        steps[2].update(complete: model.status?.trusted == true, active: model.phase == .trusting || model.phase == .verifying)
        checking.isHidden = model.phase != .checking
        errorLabel.stringValue = model.errorMessage ?? ""
        errorLabel.isHidden = model.errorMessage == nil
        errorLabel.textColor = model.phase == .cancelled ? .secondaryLabelColor : .systemRed
        reconnect.isHidden = !complete
        if let status = model.status, let fingerprint = status.fingerprint {
            detailSection.isHidden = false
            var lines = [status.displayName]
            if let expiry = status.expiresAt { lines.append("有效期至 \(expiry.formatted(date: .numeric, time: .omitted))") }
            lines.append("SHA-256：\(fingerprint)")
            details.stringValue = lines.joined(separator: "\n")
        } else { detailSection.isHidden = true }
        details.isHidden = disclosure.state != .on
        close.title = complete ? "完成" : "关闭"
        close.isEnabled = !model.isRunning
        keychain.isHidden = model.phase != .failed
        retry.title = model.canRegenerate ? "重新生成证书" : "继续设置"
        retry.isHidden = model.isRunning || !(model.canRegenerate || model.phase == .failed || model.phase == .cancelled)
        retry.isEnabled = !model.isRunning
        preferredContentSize = NSSize(width: 480, height: max(340, view.fittingSize.height))
    }

    @objc private func toggleDetails() { refresh() }
}

@MainActor
private final class CertificateStepRow: NSStackView {
    private let icon = NSImageView()
    private let progress = NSProgressIndicator()

    init(_ title: String, detail: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 12
        let indicator = NSView()
        indicator.widthAnchor.constraint(equalToConstant: 20).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 20).isActive = true
        NativeUI.pin(icon, to: indicator)
        progress.style = .spinning
        progress.controlSize = .small
        NativeUI.pin(progress, to: indicator)
        addArrangedSubview(indicator)
        addArrangedSubview(NativeUI.stack([NativeUI.label(title, weight: .semibold), SettingsUI.note(detail)], spacing: 4))
    }

    required init?(coder: NSCoder) { nil }

    func update(complete: Bool, active: Bool) {
        icon.image = NSImage(systemSymbolName: complete ? "checkmark.circle.fill" : "circle", accessibilityDescription: complete ? "已完成" : "待完成")
        icon.contentTintColor = complete ? .systemGreen : .secondaryLabelColor
        icon.isHidden = active
        progress.isHidden = !active
        if active { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }
}
