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
    private lazy var decryption = HTTPSDecryptionSettingsView(model: model)
    private let certificateStatus = NativeUI.label("未配置", secondary: true)
    private let certificateError = SettingsUI.note("")
    private lazy var setupButton = ActionButton(title: "设置证书…") { [weak self] in self?.showCertificateSetup() }
    private lazy var importButton = ActionButton(title: "导入…") { [weak self] in
        guard let self else { return }
        WorkspaceTransfer.importFile(model: model, window: view.window)
    }
    private lazy var exportButton = ActionButton(title: "导出全部…") { [weak self] in
        guard let self else { return }
        WorkspaceTransfer.exportAll(model: model, window: view.window)
    }
    private lazy var clearWorkspaceButton = ActionButton(title: "清除工作区…") { [weak self] in
        self?.confirmClearWorkspace()
    }
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
        if #available(macOS 26.0, *) {
            browser.bezelStyle = .glass
        }
        browser.imagePosition = .imageLeft
        browser.cell?.lineBreakMode = .byTruncatingMiddle
        browser.setAccessibilityLabel("浏览器")
        browser.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        browser.widthAnchor.constraint(equalToConstant: 360).isActive = true
        browserRow = SettingsUI.row("浏览器", browser)
        let refreshRow = NativeUI.stack([refreshButton, NSView()], vertical: false)
        let statusRow = NativeUI.stack([certificateStatus, setupButton], vertical: false, spacing: 12)
        clearWorkspaceButton.hasDestructiveAction = true
        let sections = [
            SettingsUI.section("启动", rows: [SettingsUI.row("启动方式", mode)], footer: "全局接管会修改系统 HTTP/HTTPS 代理；仅启动浏览器只为所选浏览器打开代理调试窗口。启动方式的修改将在下次启动时生效。"),
            SettingsUI.section("浏览器", rows: [browserRow, browserStatus, refreshRow], footer: "列出已安装的 Chrome 及同类 Chromium 浏览器。"),
            connection,
            SettingsUI.section("HTTPS 证书", rows: [SettingsUI.row("证书状态", statusRow), certificateError], footer: "配置并信任本机调试证书后，新建 HTTPS 连接可解密、修改并记录。"),
            decryption,
            SettingsUI.section("导入导出", rows: [NativeUI.stack([importButton, exportButton], vertical: false)],
                               footer: "导出所有规则组、请求修改、环境及设置，不含证书。导入会添加规则组与请求修改；全量备份中的环境、设置和列宽将覆盖当前数据。"),
            NativeUI.stack([clearWorkspaceButton, NSView()], vertical: false)
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
        importButton.isEnabled = model.loaded && !model.isTransitioning
        clearWorkspaceButton.isEnabled = model.canClearWorkspace
        exportButton.isEnabled = model.loaded
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
        decryption.refresh()
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

    private func confirmClearWorkspace() {
        guard model.canClearWorkspace,
              let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清除工作区？"
        alert.informativeText = "将停止捕获，删除所有规则组、规则、环境和请求日志，并将代理与 HTTPS 解密配置恢复默认。证书、浏览器数据和应用偏好设置会保留。此操作无法撤销。"
        alert.addButton(withTitle: "取消").keyEquivalent = "\r"
        let clear = alert.addButton(withTitle: "清除工作区")
        clear.hasDestructiveAction = true
        clear.keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            Task { @MainActor in
                do { try await self.model.clearWorkspace() }
                catch { await NSAlert(error: error).beginSheetModal(for: window) }
            }
        }
    }
}

@MainActor
private final class HTTPSDecryptionSettingsView: NSView, NSTextViewDelegate {
    private let model: WorkspaceModel
    private let allRequests = NSSwitch()
    private let domains = DecryptionDomainsTextView()
    private let domainsScroll = DecryptionDomainsScrollView()
    private let errorLabel = SettingsUI.note("")
    private var displayedDomains: [String]?

    init(model: WorkspaceModel) {
        self.model = model
        super.init(frame: .zero)
        allRequests.target = self
        allRequests.action = #selector(toggleAllRequests)
        allRequests.setAccessibilityLabel("解密所有请求")
        domains.delegate = self
        domains.isRichText = false
        domains.allowsUndo = true
        domains.isAutomaticQuoteSubstitutionEnabled = false
        domains.isAutomaticDashSubstitutionEnabled = false
        domains.isAutomaticSpellingCorrectionEnabled = false
        domains.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        domains.textContainerInset = NSSize(width: 6, height: 6)
        domains.isVerticallyResizable = true
        domains.isHorizontallyResizable = false
        domains.minSize = .zero
        domains.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        domains.autoresizingMask = [.width]
        domains.textContainer?.widthTracksTextView = true
        domains.setAccessibilityLabel("HTTPS 解密域名")
        let scroll = domainsScroll
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.documentView = domains
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let section = SettingsUI.section("HTTPS 解密", rows: [
            SettingsUI.row("解密所有请求", allRequests),
            NativeUI.label("指定域名"), scroll, errorLabel
        ], footer: "多个域名用英文分号 ; 分隔。支持 *.example.com（不含根域名）。关闭全部解密后，留空则全部透传。")
        NativeUI.pin(section, to: self)
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let configuration = model.document.httpsDecryption
        allRequests.state = configuration.decryptAllRequests ? .on : .off
        allRequests.isEnabled = model.loaded && !model.isTransitioning
        domains.isEditable = allRequests.isEnabled && !configuration.decryptAllRequests
        domains.isSelectable = domains.isEditable
        domains.setAccessibilityEnabled(domains.isEditable)
        if !domains.isEditable, window?.firstResponder === domains { window?.makeFirstResponder(nil) }
        domains.textColor = domains.isEditable ? .textColor : .disabledControlTextColor
        let background: NSColor = domains.isEditable ? .textBackgroundColor : DecryptionDomainsScrollView.disabledBackgroundColor
        domains.backgroundColor = background
        domainsScroll.backgroundColor = background
        domainsScroll.contentView.backgroundColor = background
        if displayedDomains != configuration.domains {
            domains.string = configuration.domains.joined(separator: "; ")
            domains.undoManager?.removeAllActions()
            displayedDomains = configuration.domains
            errorLabel.isHidden = true
        }
    }

    func textDidChange(_ notification: Notification) {
        guard domains.isEditable, !domains.hasMarkedText() else { return }
        do {
            let values = try HTTPSDecryptionConfiguration.parseDomains(domains.string)
            displayedDomains = values
            model.document.httpsDecryption.domains = values
            errorLabel.isHidden = true
        } catch {
            errorLabel.stringValue = "未保存：" + error.localizedDescription
            errorLabel.isHidden = false
        }
    }

    @objc private func toggleAllRequests() {
        model.document.httpsDecryption.decryptAllRequests = allRequests.state == .on
        refresh()
    }
}

@MainActor
private final class DecryptionDomainsScrollView: NSScrollView {
    // On newer macOS versions, window/control backgrounds can resolve to the same
    // white as editable text. Blend an opaque fill to keep disabled fields visible.
    static let disabledBackgroundColor = NSColor(name: nil) { appearance in
        var color = NSColor.textBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.textBackgroundColor.blended(withFraction: 0.10, of: .labelColor) ?? .lightGray
        }
        return color
    }

    override func layout() {
        super.layout()
        if let text = documentView as? NSTextView {
            text.minSize = NSSize(width: 0, height: contentSize.height)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if contentView.documentRect.height <= contentView.bounds.height + 1 {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

@MainActor
private final class DecryptionDomainsTextView: NSTextView {
    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

private struct BrowserPickerOption: Equatable {
    let id: String
    let title: String
    let applicationURL: URL
}
