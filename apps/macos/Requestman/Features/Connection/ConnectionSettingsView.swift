import AppKit
import CoreImage
import SystemConfiguration
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
    private let lanSwitch = NSSwitch()
    private let listenAddress = NativeUI.label("", secondary: true)
    private var upstreamRows: [NSView] = []
    private let errorLabel = SettingsUI.note("")
    private let httpsLabel = NativeUI.label("", secondary: true)

    init(model: WorkspaceModel) {
        self.model = model
        super.init(frame: .zero)
        lanSwitch.target = self
        lanSwitch.action = #selector(toggleLAN)
        lanSwitch.setAccessibilityLabel("允许局域网设备连接")
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
            SettingsUI.section("本地代理", rows: [SettingsUI.row("监听地址", listenAddress), SettingsUI.row("端口", port),
                SettingsUI.row("允许局域网设备连接", lanSwitch)], footer: "局域网连接使用 IPv4。开启后，手机可通过 Mac 的局域网 IP 和此端口接入。"),
            SettingsUI.section("连接方式", rows: [SettingsUI.row("使用 HTTP 上游代理", proxySwitch)] + upstreamRows, footer: "本机与手机请求共用此 HTTP 上游代理，可接入 Surge 等。地址从这台 Mac 访问；关闭时使用系统网络路由。"),
            errorLabel,
            SettingsUI.section("协议支持", rows: [SettingsUI.row("HTTP/1.1 / HTTP/2", NativeUI.label("请求与响应修改、Mock、记录；两端保持同协议", secondary: true)), SettingsUI.row("HTTPS", httpsLabel)], footer: "暂不支持异步脚本、辅助请求、断点及按应用透明接管。")
        ]
        let stack = NativeUI.stack(sections, spacing: 18)
        stack.alignment = .leading
        sections.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NativeUI.pin(stack, to: self)
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let editable = model.loaded && !model.isTransitioning
        lanSwitch.isEnabled = editable
        lanSwitch.state = model.document.proxy.allowLAN ? .on : .off
        listenAddress.stringValue = model.document.proxy.allowLAN ? "0.0.0.0（本机与局域网）" : "127.0.0.1（仅本机）"
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

    @objc private func toggleLAN() { model.document.proxy.allowLAN = lanSwitch.state == .on }

    @objc private func toggleProxy() {
        model.document.proxy.upstream = proxySwitch.state == .on
            ? .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152)) : .system
    }
}

@MainActor
final class MobileConnectionViewController: ObservedViewController {
    private let model: WorkspaceModel
    private let address = NSPopUpButton(frame: .zero, pullsDown: false)
    private let port = NSTextField(string: "")
    private let state = NativeUI.label("", size: 12, secondary: true)
    private let stateIcon = NSImageView()
    private let addressNote = SettingsUI.note("")
    private let qr = NSImageView()
    private let certificateNote = SettingsUI.note("")
    private var addresses: [LocalNetwork.Address] = []
    private var currentURL: URL?
    private var renderedURL: URL?
    private var qrRow: NSStackView!
    private var certificateFallback: NSStackView!
    private var helpPopover: NSPopover?
    private weak var certificateSheet: CertificateSetupViewController?
    private lazy var copyLink = ActionButton(title: "复制安装链接") { [weak self] in
        guard let url = self?.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    private lazy var refreshAddresses = ActionButton(title: "") { [weak self] in self?.discover() }
    private lazy var setupCertificate = ActionButton(title: "设置证书…") { [weak self] in
        guard let self, self.certificateSheet == nil, self.view.window?.attachedSheet == nil else { return }
        let controller = CertificateSetupViewController(model: self.model.certificateSetup)
        self.certificateSheet = controller
        self.presentAsSheet(controller)
    }
    private lazy var help = ActionButton(title: "连接帮助") { [weak self] in self?.showHelp() }
    private lazy var done = ActionButton(title: "完成") { [weak self] in self?.dismiss(nil) }

    init(model: WorkspaceModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 490))
        view.widthAnchor.constraint(equalToConstant: 560).isActive = true
        address.target = self; address.action = #selector(selectAddress)
        address.setAccessibilityLabel("服务器（这台 Mac）")
        address.identifier = .init("mobile.server")
        address.heightAnchor.constraint(equalToConstant: 28).isActive = true
        port.isEditable = false; port.isSelectable = true
        port.setAccessibilityLabel("端口")
        port.identifier = .init("mobile.port")
        port.widthAnchor.constraint(equalToConstant: 80).isActive = true
        port.heightAnchor.constraint(equalToConstant: 28).isActive = true
        refreshAddresses.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新 Mac 地址")
        refreshAddresses.imagePosition = .imageOnly
        refreshAddresses.toolTip = "刷新 Mac 地址"
        refreshAddresses.setAccessibilityLabel("刷新 Mac 地址")
        stateIcon.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        stateIcon.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        stateIcon.setAccessibilityElement(false)
        state.identifier = .init("mobile.status")
        qr.identifier = .init("mobile.qr")
        qr.setAccessibilityLabel("手机证书安装指引二维码")
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 96).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 96).isActive = true
        done.keyEquivalent = "\r"
        copyLink.controlSize = .small
        help.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        help.imagePosition = .imageLeading

        let header = NativeUI.stack([
            NativeUI.label("连接手机", size: 20, weight: .semibold),
            NativeUI.label("依次完成以下三步，即可查看手机请求。", secondary: true)
        ], spacing: 6)
        let status = NativeUI.stack([stateIcon, state], vertical: false, spacing: 5)
        status.setContentHuggingPriority(.required, for: .horizontal)
        let first = step(1, title: "准备网络", trailing: status, rows: [
            NativeUI.label("手机与 Mac 连接同一局域网。")
        ])

        let addressControl = NativeUI.stack([address, refreshAddresses], vertical: false, spacing: 6)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let serverField = NativeUI.stack([NativeUI.label("服务器（这台 Mac）"), addressControl], spacing: 5)
        addressControl.widthAnchor.constraint(equalTo: serverField.widthAnchor).isActive = true
        let portField = NativeUI.stack([NativeUI.label("端口"), port], spacing: 5)
        let fields = NativeUI.stack([serverField, portField], vertical: false, spacing: 12)
        fields.alignment = .top
        let second = step(2, title: "在手机上设置代理", rows: [
            NativeUI.label("手机 Wi-Fi 设置 → HTTP 代理 → 手动", secondary: true),
            fields, addressNote
        ])

        let qrInstructions = NativeUI.stack([
            NativeUI.label("用手机扫码打开安装指引", weight: .medium),
            SettingsUI.note("按页面提示安装证书，并开启信任。"), copyLink,
            SettingsUI.note("仅查看 HTTP 请求可跳过此步。")
        ], spacing: 7)
        qrRow = NativeUI.stack([qr, qrInstructions], vertical: false, spacing: 18)
        qrRow.alignment = .centerY
        qrInstructions.widthAnchor.constraint(equalTo: qrRow.widthAnchor, constant: -114).isActive = true
        for row in qrInstructions.arrangedSubviews where row is NSTextField {
            row.widthAnchor.constraint(equalTo: qrInstructions.widthAnchor).isActive = true
        }
        certificateFallback = NativeUI.stack([
            certificateNote, setupCertificate, SettingsUI.note("仅查看 HTTP 请求可跳过此步。")
        ], spacing: 8)
        certificateNote.widthAnchor.constraint(equalTo: certificateFallback.widthAnchor).isActive = true
        let third = step(3, title: "安装并信任证书", rows: [qrRow, certificateFallback])
        let footer = NativeUI.stack([help, NSView(), done], vertical: false)
        let content = NativeUI.stack([header, first, separator(), second, separator(), third, separator(), footer], spacing: 16)
        for row in content.arrangedSubviews { row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        NativeUI.pin(content, to: view, insets: NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24))
        discover()
    }

    private func step(_ number: Int, title: String, trailing: NSView? = nil, rows: [NSView]) -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "\(number).circle.fill", accessibilityDescription: "第 \(number) 步")!)
        icon.symbolConfiguration = .init(pointSize: 25, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let headingLabel = NativeUI.label(title, size: 14, weight: .semibold)
        let heading = NativeUI.stack([headingLabel, NSView()] + (trailing.map { [$0] } ?? []), vertical: false)
        if let trailing { trailing.trailingAnchor.constraint(equalTo: heading.trailingAnchor).isActive = true }
        let body = NativeUI.stack([heading] + rows, spacing: 9)
        for row in body.arrangedSubviews { row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        let row = NativeUI.stack([icon, body], vertical: false, spacing: 12)
        row.alignment = .top
        heading.heightAnchor.constraint(equalTo: icon.heightAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -40).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let line = NSBox(); line.boxType = .separator
        return line
    }

    private func discover() {
        let selected = addresses.indices.contains(address.indexOfSelectedItem) ? addresses[address.indexOfSelectedItem].host : nil
        addresses = LocalNetwork.addresses()
        // Use the system's interface names; en0 is not necessarily Wi-Fi.
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var names: [String: String] = [:]
        for interface in interfaces {
            if let name = SCNetworkInterfaceGetBSDName(interface) as String?,
               let title = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[name] = title
            }
        }
        address.removeAllItems()
        address.addItems(withTitles: addresses.map { value in
            names[value.interface].map { "\(value.host)（\($0)）" } ?? value.host
        })
        if addresses.isEmpty { address.addItem(withTitle: "暂无可用地址") }
        if let index = addresses.firstIndex(where: { $0.host == selected }) { address.selectItem(at: index) }
        refresh()
    }

    @objc private func selectAddress() { refresh() }

    override func refresh() {
        let listening = model.loaded && model.isCapturing && model.listenPort != nil
            && model.activeProxyConfiguration?.allowLAN == true && !model.isTransitioning
        let selected = addresses.indices.contains(address.indexOfSelectedItem) ? addresses[address.indexOfSelectedItem] : nil
        port.stringValue = listening ? model.listenPort.map(String.init) ?? "—" : "—"
        address.isEnabled = listening && !addresses.isEmpty
        state.stringValue = listening ? "Mac 代理已启动" : (model.isTransitioning ? "正在更新监听…" : "局域网监听已停止")
        stateIcon.contentTintColor = listening ? .systemGreen : .secondaryLabelColor
        addressNote.stringValue = selected == nil
            ? "未找到 Mac 地址，请检查网络后刷新。"
            : "多块网卡时，选择手机能访问的 Mac 地址。"
        currentURL = listening && model.certificateSetup.isConfigured
            ? selected.flatMap { value in model.listenPort.map { value.setupURL(port: $0) } } : nil
        if currentURL != renderedURL {
            renderedURL = currentURL
            qr.image = currentURL.flatMap { Self.qrImage($0.absoluteString) }
        }
        qrRow.isHidden = currentURL == nil
        certificateFallback.isHidden = currentURL != nil
        copyLink.isEnabled = currentURL != nil
        copyLink.toolTip = currentURL?.absoluteString
        setupCertificate.isHidden = !listening || model.certificateSetup.isConfigured
        setupCertificate.isEnabled = !model.certificateSetup.isRunning
        certificateNote.stringValue = !listening ? "监听恢复后，可继续安装证书。"
            : (!model.certificateSetup.isConfigured ? "先设置这台 Mac 的证书，再用手机扫码安装。" : "选择可用的 Mac 地址后显示安装二维码。")
        preferredContentSize = NSSize(width: 560, height: view.fittingSize.height)
    }

    private func showHelp() {
        if let helpPopover, helpPopover.isShown { helpPopover.close(); return }
        let controller = NSViewController()
        controller.view = NSView()
        let content = NativeUI.stack([
            NativeUI.label("连接帮助", size: 14, weight: .semibold),
            SettingsUI.note("连接不上：确认手机与 Mac 的网络可互通，路由器未隔离设备，且防火墙允许 Requestman 入站连接。Mac 地址变化后，需更新手机代理设置。"),
            SettingsUI.note("iPhone：安装描述文件后，前往“通用 → 关于本机 → 证书信任设置”开启完全信任。Mac 上的信任不会自动同步到手机。"),
            SettingsUI.note("Android：安装 CA 证书。部分 App 需要在调试配置中信任用户 CA；证书绑定的 App 可能无法解密。"),
            SettingsUI.note("完成后：回到请求日志查看手机请求，可点击设备来源设置别名。使用结束后，将手机 Wi-Fi 代理关闭。"),
            SettingsUI.note("只抓取经过 HTTP 代理的流量，手机共用 Mac 配置的上游代理。")
        ], spacing: 12)
        for row in content.arrangedSubviews { row.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        NativeUI.pin(content, to: controller.view, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        helpPopover = popover
        popover.show(relativeTo: help.bounds, of: help, preferredEdge: .maxY)
    }

    private static func qrImage(_ value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let padded = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -4, dy: -4)))
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
