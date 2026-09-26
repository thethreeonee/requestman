import AppKit
import RequestmanCore

@MainActor
final class GeneralSettingsViewController: ObservedViewController {
    private let model: WorkspaceModel
    private lazy var mode = ActionPopUpButton(items: CaptureMode.allCases.map(\.title)) { [weak self] index in
        guard let self, CaptureMode.allCases.indices.contains(index) else { return }
        self.model.captureMode = CaptureMode.allCases[index]
    }
    private let browser = NSPopUpButton(frame: .zero, pullsDown: false)
    private let browserStatus = SettingsUI.note("")
    private var browserRow: NSView!
    private lazy var refreshButton = ActionButton(title: "刷新列表") { [weak self] in
        guard let self else { return }
        Task { @MainActor in await self.model.refreshBrowsers() }
    }
    private lazy var connection = ConnectionSettingsView(model: model)
    private let certificateStatus = NativeUI.label("未配置", secondary: true)
    private let certificateError = SettingsUI.note("")
    private lazy var setupButton = ActionButton(title: "设置证书…") { [weak self] in self?.showCertificateSetup() }
    private var browserOptions: [BrowserPickerOption] = []
    private weak var certificateSheet: CertificateSetupViewController?

    init(model: WorkspaceModel) {
        self.model = model
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        browser.target = self
        browser.action = #selector(selectBrowser)
        browser.autoenablesItems = false
        browser.imagePosition = .imageLeft
        browser.cell?.lineBreakMode = .byTruncatingMiddle
        browser.setAccessibilityLabel("浏览器")
        browser.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        browser.widthAnchor.constraint(equalToConstant: 360).isActive = true
        browserRow = SettingsUI.row("浏览器", browser)
        let refreshRow = NativeUI.stack([refreshButton, NSView()], vertical: false)
        let statusRow = NativeUI.stack([certificateStatus, setupButton], vertical: false, spacing: 12)
        let sections = [
            SettingsUI.section("启动", rows: [SettingsUI.row("启动方式", mode)], footer: "全局接管会修改系统 HTTP/HTTPS 代理；仅启动浏览器只为所选浏览器打开代理调试窗口。启动方式的修改将在下次启动时生效。"),
            SettingsUI.section("浏览器", rows: [browserRow, browserStatus, refreshRow], footer: "列出已安装的 Chrome 及同类 Chromium 浏览器。"),
            connection,
            SettingsUI.section("HTTPS 证书", rows: [SettingsUI.row("证书状态", statusRow), certificateError], footer: "配置并信任本机调试证书后，新建 HTTPS 连接可解密、修改并记录。")
        ]
        let stack = NativeUI.stack(sections, spacing: 18)
        stack.alignment = .leading
        sections.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        SettingsUI.scroll(stack, into: view)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDiscovery()
    }

    override func refresh() {
        mode.selectItem(at: CaptureMode.allCases.firstIndex(of: model.captureMode) ?? 0)
        mode.isEnabled = model.loaded && !model.isTransitioning
        let options = model.installedBrowsers.map { BrowserPickerOption(id: $0.id, title: model.browserDisplayName($0), applicationURL: $0.applicationURL) }
        if options != browserOptions {
            browser.removeAllItems()
            for option in options {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                let icon = NSWorkspace.shared.icon(forFile: option.applicationURL.path).copy() as? NSImage
                icon?.size = NSSize(width: 18, height: 18)
                item.image = icon
                item.representedObject = option.id
                browser.menu?.addItem(item)
            }
            browserOptions = options
        }
        browser.selectItem(at: options.firstIndex { $0.id == model.selectedBrowserID } ?? -1)
        browser.setAccessibilityValue(browser.selectedItem?.title ?? "")
        browser.isEnabled = model.loaded && !model.isTransitioning && !model.isDiscoveringBrowsers
        browserRow.isHidden = options.isEmpty
        browserStatus.isHidden = !options.isEmpty
        browserStatus.stringValue = model.isDiscoveringBrowsers ? "正在查找浏览器…" : "未找到已安装的 Chromium 浏览器。"
        refreshButton.isEnabled = !model.isTransitioning && !model.isDiscoveringBrowsers
        connection.refresh()
        certificateStatus.stringValue = model.certificateSetup.isConfigured ? "✓ 已完成配置" : "未配置"
        certificateStatus.textColor = model.certificateSetup.isConfigured ? .systemGreen : .secondaryLabelColor
        setupButton.isHidden = model.certificateSetup.isConfigured
        setupButton.isEnabled = !model.certificateSetup.isRunning
        certificateError.stringValue = model.certificateSetup.errorMessage ?? ""
        certificateError.isHidden = model.certificateSetup.errorMessage == nil
    }

    @objc private func selectBrowser() {
        guard let id = browser.selectedItem?.representedObject as? String else { return }
        model.selectedBrowserID = id
    }

    @objc private func applicationActivated() {
        guard viewIfLoaded?.window?.isVisible == true else { return }
        refreshDiscovery()
    }

    private func refreshDiscovery() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.refreshBrowsers()
            if self.certificateSheet == nil { await self.model.certificateSetup.refreshStatus() }
        }
    }

    private func showCertificateSetup() {
        guard certificateSheet == nil else { return }
        let controller = CertificateSetupViewController(model: model.certificateSetup)
        certificateSheet = controller
        presentAsSheet(controller)
    }
}

private struct BrowserPickerOption: Equatable {
    let id: String
    let title: String
    let applicationURL: URL
}
