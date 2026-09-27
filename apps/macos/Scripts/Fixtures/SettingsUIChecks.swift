import AppKit
import Observation
import RequestmanCore
import RequestmanCertificates

struct ChromiumBrowser {
    let id: String
    let name: String
    let applicationURL: URL
}

@MainActor @Observable
final class WorkspaceModel {
    var settingsSection: WorkspaceSettingsSection = .general
    var captureMode: CaptureMode = .systemProxy
    var document = WorkspaceDocument()
    func importArchive(_ archive: WorkspaceArchive) async throws { preconditionFailure("Unexpected file import") }
    var clearCount = 0
    func clearWorkspace() async throws {
        guard canClearWorkspace else { return }
        clearCount += 1
    }
    var loaded = true
    var loadFailed = false
    var canClearWorkspace: Bool { !isTransitioning && (loaded || loadFailed) }
    var isTransitioning = false
    var installedBrowsers: [ChromiumBrowser] = []
    var selectedBrowserID = ""
    var isDiscoveringBrowsers = false
    var proxyConfigurationError: String?
    var isCapturing = false
    var listenPort: Int?
    var activeProxyConfiguration: ExplicitProxyConfiguration?
    var selectedEnvironmentID: UUID?
    var certificateSetup = CertificateSetupModel(service: ReadOnlyCertificateFixture())
    func browserDisplayName(_ browser: ChromiumBrowser) -> String { browser.name }
    func refreshBrowsers() async {}
    func addEnvironment() {
        let environment = WorkspaceEnvironment(name: "新环境")
        document.environments.append(environment)
        selectedEnvironmentID = environment.id
        if document.selectedEnvironmentID == nil { document.selectedEnvironmentID = environment.id }
    }
}

private struct ReadOnlyCertificateFixture: CertificateService {
    var configured = false
    var fails = false
    func status() async throws -> CertificateStatus {
        if fails { throw LocalCertificateError.missingPrivateKey }
        return configured ? CertificateStatus(generated: true, installed: true, trusted: true) : .missing
    }
    func migrateAuthorization(allowingUI: Bool) async throws -> CertificateStatus { preconditionFailure("Unexpected migration") }
    func generate() async throws -> CertificateStatus { preconditionFailure("Unexpected certificate generation") }
    func regenerate() async throws -> CertificateStatus { preconditionFailure("Unexpected regeneration") }
    func install() async throws -> CertificateStatus { preconditionFailure("Unexpected installation") }
    func trust() async throws -> CertificateStatus { preconditionFailure("Unexpected trust") }
}

@main @MainActor
struct SettingsUIChecks {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkSharedInputs()
        let model = WorkspaceModel()
        let windowController = WorkspaceSettingsWindowController(model: model)
        let window = windowController.window!
        let controller = window.contentViewController as! WorkspaceSettingsViewController
        controller.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(window.contentView!.bounds.width == 800)
        precondition(window.contentView!.bounds.height == 540)
        precondition(window.toolbarStyle == .unified && window.titleVisibility == .hidden)
        precondition(window.toolbar?.items.contains { $0.view is ToolbarSectionControl } == true)
        checkFormGeometry(in: controller.view)

        precondition(button("导入…", in: controller.view).isEnabled)
        precondition(button("导出全部…", in: controller.view).isEnabled)
        let clear = button("清除工作区…", in: controller.view)
        precondition(clear.isEnabled && clear.hasDestructiveAction)
        let clearRow = clear.superview as! NSStackView
        let generalStack = clearRow.superview as! NSStackView
        precondition(generalStack.arrangedSubviews.last === clearRow, "Clear workspace belongs at the very bottom")
        clear.performClick(nil)
        precondition(model.clearCount == 0, "Opening confirmation must not clear the workspace")
        let cancelSheet = window.attachedSheet!
        let cancel = button("取消", in: cancelSheet.contentView!)
        precondition(cancelSheet.defaultButtonCell === cancel.cell)
        cancel.performClick(nil)
        try await Task.sleep(for: .milliseconds(300))
        precondition(model.clearCount == 0)
        clear.performClick(nil)
        let confirm = button("清除工作区", in: window.attachedSheet!.contentView!)
        precondition(confirm.hasDestructiveAction && confirm.keyEquivalent.isEmpty)
        confirm.performClick(nil)
        try await Task.sleep(for: .milliseconds(300))
        precondition(model.clearCount == 1)
        let port = field("本地代理端口", in: controller.view)
        precondition(port.bounds.width == 140 && abs(port.bounds.height - 32) < 0.5)
        port.onChange("9191")
        precondition(model.document.proxy.port == 9191)
        model.isTransitioning = true
        try await Task.sleep(for: .milliseconds(50))
        precondition(!port.isEnabled)
        precondition(!button("导入…", in: controller.view).isEnabled)
        precondition(!clear.isEnabled)
        model.isTransitioning = false

        let general = controller.children.first as! GeneralSettingsViewController
        model.loaded = false
        general.refresh()
        precondition(!clear.isEnabled, "Initial loading must keep reset disabled")
        model.loadFailed = true
        general.refresh()
        precondition(clear.isEnabled && !button("导入…", in: general.view).isEnabled)
        clear.performClick(nil)
        precondition(window.attachedSheet != nil, "Failed loading must still allow reset confirmation")
        button("清除工作区", in: window.attachedSheet!.contentView!).performClick(nil)
        try await Task.sleep(for: .milliseconds(300))
        precondition(model.clearCount == 2)
        model.loaded = true
        model.loadFailed = false
        general.refresh()
        let lan = descendants(general.view).compactMap { $0 as? NSSwitch }.first { $0.accessibilityLabel() == "允许局域网设备连接" }!
        precondition(lan.state == .off)
        lan.state = .on
        NSApplication.shared.sendAction(lan.action!, to: lan.target, from: lan)
        precondition(model.document.proxy.allowLAN)
        let captureMode = descendants(general.view).compactMap { $0 as? ActionPopUpButton }.first { $0.itemTitles.contains("仅启动代理") }!
        captureMode.onChange(CaptureMode.allCases.firstIndex(of: .proxyOnly)!)
        precondition(model.captureMode == .proxyOnly)
        let guide = MobileConnectionViewController(model: model)
        let guideWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 490), styleMask: [.titled], backing: .buffered, defer: false)
        guideWindow.isReleasedWhenClosed = false; guideWindow.contentViewController = guide
        guide.loadViewIfNeeded(); guide.refresh()
        let qr = descendants(guide.view).compactMap { $0 as? NSImageView }.first { $0.identifier?.rawValue == "mobile.qr" }!
        let guidePort = descendants(guide.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "mobile.port" }!
        precondition(qr.image == nil && qr.isHiddenOrHasHiddenAncestor)
        precondition(guidePort.stringValue == "—")
        model.isCapturing = true; model.listenPort = 9191; model.activeProxyConfiguration = model.document.proxy
        guide.refresh()
        precondition(qr.isHiddenOrHasHiddenAncestor && !button("设置证书…", in: guide.view).isHiddenOrHasHiddenAncestor)
        model.certificateSetup = CertificateSetupModel(service: ReadOnlyCertificateFixture(configured: true))
        await model.certificateSetup.refreshStatus()
        guide.refresh()
        guideWindow.setContentSize(guide.preferredContentSize)
        guide.view.layoutSubtreeIfNeeded()
        precondition(descendants(guide.view).allSatisfy { !($0 is NSScrollView) })
        precondition(guide.preferredContentSize.height < 560, "The three steps must fit a compact dialog")
        precondition(guidePort.stringValue == "9191" && !guidePort.isEditable && guidePort.isSelectable)
        let server = descendants(guide.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "服务器（这台 Mac）" }!
        precondition(server.bounds.width > 200)
        if !LocalNetwork.addresses().isEmpty {
            precondition(qr.image != nil && !qr.isHiddenOrHasHiddenAncestor)
            precondition(button("复制安装链接", in: guide.view).toolTip!.hasSuffix(":9191/requestman"))
            model.document.proxy.port = 9292
            guide.refresh()
            precondition(guidePort.stringValue == "9191", "The guide must show the actual port, not the settings draft")
            if server.numberOfItems > 1 {
                server.selectItem(at: 1)
                NSApplication.shared.sendAction(server.action!, to: server.target, from: server)
                precondition(button("复制安装链接", in: guide.view).toolTip!.contains(LocalNetwork.addresses()[1].host))
            }
        }
        if let prefix = ProcessInfo.processInfo.environment["REQUESTMAN_SETTINGS_SNAPSHOT"] {
            for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let preview = MobileConnectionViewController(model: model)
                let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 490), styleMask: [.titled], backing: .buffered, defer: false)
                previewWindow.isReleasedWhenClosed = false
                previewWindow.appearance = NSAppearance(named: appearance)
                previewWindow.contentViewController = preview
                preview.loadViewIfNeeded(); preview.refresh()
                previewWindow.setContentSize(preview.preferredContentSize)
                preview.view.wantsLayer = true
                preview.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    preview.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                preview.view.layoutSubtreeIfNeeded()
                preview.view.displayIfNeeded()
                let bitmap = preview.view.bitmapImageRepForCachingDisplay(in: preview.view.bounds)!
                preview.view.cacheDisplay(in: preview.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(prefix)-mobile-\(style).png"))
                previewWindow.close()
            }
        }
        model.isTransitioning = true
        guide.refresh()
        precondition(qr.image == nil && qr.isHiddenOrHasHiddenAncestor && !server.isEnabled)
        model.isTransitioning = false
        model.activeProxyConfiguration?.allowLAN = false
        guide.refresh()
        precondition(qr.image == nil && qr.isHiddenOrHasHiddenAncestor, "Failed LAN reconfiguration must not advertise an inactive endpoint")
        precondition(guide.preferredContentSize.height < 560)
        guideWindow.close(); model.isCapturing = false; model.listenPort = nil; model.activeProxyConfiguration = nil
        model.document.proxy.port = 9191
        let decryptAll = descendants(general.view).compactMap { $0 as? NSSwitch }.first { $0.accessibilityLabel() == "解密所有请求" }!
        let domains = descendants(general.view).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "HTTPS 解密域名" }!
        precondition(decryptAll.state == .on && !domains.isEditable)
        precondition(!domains.isSelectable && domains.textColor == .disabledControlTextColor)
        precondition(domains.enclosingScrollView!.borderType == .bezelBorder)
        decryptAll.state = .off
        NSApplication.shared.sendAction(decryptAll.action!, to: decryptAll.target, from: decryptAll)
        precondition(!model.document.httpsDecryption.decryptAllRequests && domains.isEditable)
        precondition(domains.isSelectable && domains.backgroundColor == .textBackgroundColor)
        general.view.layoutSubtreeIfNeeded()
        precondition(domains.bounds.width > 500 && domains.enclosingScrollView!.contentSize.height >= 100,
                     "The multiline domain editor must fill its native scroll view")
        window.makeFirstResponder(domains)
        domains.insertText("  api.example.com ;  *.example.test  ", replacementRange: NSRange(location: 0, length: 0))
        precondition(model.document.httpsDecryption.domains == ["api.example.com", "*.example.test"])
        domains.insertText("https://invalid.test", replacementRange: NSRange(location: 0, length: domains.string.utf16.count))
        general.refresh()
        precondition(model.document.httpsDecryption.domains == ["api.example.com", "*.example.test"])
        precondition(domains.string == "https://invalid.test", "Invalid domain drafts must remain available for correction")
        precondition(descendants(general.view).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue.hasPrefix("未保存：域名格式无效") })
        checkFormGeometry(in: general.view)
        domains.insertText("localhost", replacementRange: NSRange(location: 0, length: domains.string.utf16.count))
        precondition(model.document.httpsDecryption.domains == ["localhost"])
        decryptAll.state = .on
        NSApplication.shared.sendAction(decryptAll.action!, to: decryptAll.target, from: decryptAll)
        precondition(model.document.httpsDecryption.decryptAllRequests && !domains.isEditable)
        precondition(!domains.isSelectable && window.firstResponder !== domains,
                     "Enabling all-request decryption must disable and unfocus the domain editor")
        precondition(model.document.httpsDecryption.domains == ["localhost"], "The all-requests switch must preserve the domain list")
        model.document.httpsDecryption.domains = ["imported.test", "*.second.test"]
        general.refresh()
        precondition(domains.string == "imported.test; *.second.test", "Imported settings must display semicolon-separated domains")
        checkDomainScrolling(general, model: model, domains: domains)
        try checkDomainBackground(general, model: model, domains: domains)
        checkFormGeometry(in: general.view)
        model.captureMode = .browser
        model.installedBrowsers = [ChromiumBrowser(id: "test.browser", name: "Chromium Test Browser", applicationURL: URL(fileURLWithPath: "/System/Applications/Safari.app"))]
        model.selectedBrowserID = "test.browser"
        model.certificateSetup = CertificateSetupModel(service: ReadOnlyCertificateFixture(configured: true))
        await model.certificateSetup.refreshStatus()
        general.refresh()
        checkFormGeometry(in: general.view)
        try snapshotForm(in: general.view, name: "general")
        for fixture in [ReadOnlyCertificateFixture(), ReadOnlyCertificateFixture(fails: true),
                        ReadOnlyCertificateFixture(configured: true)] {
            model.certificateSetup = CertificateSetupModel(service: fixture)
            await model.certificateSetup.refreshStatus()
            general.refresh()
            checkFormGeometry(in: general.view)
            let setup = button("设置证书…", in: general.view)
            precondition(setup.isHidden == fixture.configured)
        }
        model.document.proxy.upstream = .httpProxy(ProxyEndpoint(host: "127.0.0.1", port: 6152))
        model.proxyConfigurationError = String(repeating: "上游代理连接失败，请检查地址与端口。", count: 8)
        general.refresh()
        checkFormGeometry(in: general.view)
        let scroll = descendants(general.view).compactMap { $0 as? NSScrollView }.first!
        precondition(scroll.documentView!.bounds.height > scroll.contentSize.height, "Long forms must scroll instead of compressing their sections")
        try snapshotForm(in: general.view, name: "expanded")
        model.document.proxy.upstream = .system
        model.proxyConfigurationError = nil
        model.installedBrowsers = []
        general.refresh()
        checkFormGeometry(in: general.view)

        model.settingsSection = .environments
        controller.refresh()
        let environments = controller.children.first as! EnvironmentsViewController
        environments.refresh()
        button("新建环境", in: environments.view).performClick(nil)
        environments.refresh()
        precondition(model.document.environments.count == 1)
        let firstID = model.document.environments[0].id
        let name = field("环境名称", in: environments.view)
        name.onChange("staging")
        environments.refresh()
        precondition(model.document.environments[0].name == "staging")
        button("添加变量", in: environments.view).performClick(nil)
        environments.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        let variableName = field("变量名称", in: environments.view)
        let variableValue = field("变量值", in: environments.view)
        variableName.selectText(nil)
        let nameEditor = variableName.currentEditor() as! NSTextView
        nameEditor.insertText("apiKey", replacementRange: NSRange(location: 0, length: nameEditor.string.utf16.count))
        nameEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        precondition(variableValue.currentEditor() != nil, "Tab must move from a variable name to its value")
        let valueEditor = variableValue.currentEditor() as! NSTextView
        valueEditor.insertText("secret-value", replacementRange: NSRange(location: 0, length: valueEditor.string.utf16.count))
        valueEditor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        precondition(variableName.currentEditor() != nil, "Shift-Tab must return to the variable name")
        (variableName.currentEditor() as! NSTextView).doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(variableName.currentEditor() == nil, "Return must finish single-line editing")
        environments.refresh()
        precondition(model.document.environments[0].values["apiKey"] == "secret-value")
        precondition(field("变量值", in: environments.view).stringValue == "secret-value")
        let nameBox = descendants(environments.view).compactMap { $0 as? NSBox }.first { $0.title == "名称" }!
        precondition(descendants(nameBox).compactMap { $0 as? ActionTextField }.count == 1)
        let type = descendants(environments.view).compactMap { $0 as? ActionPopUpButton }.first { $0.accessibilityLabel() == "变量数据类型" }!
        precondition(type.itemTitles == ["字符串", "数值", "布尔", "数组", "对象"])
        for (kind, value) in [(EnvironmentValueType.number, "123"), (.boolean, "true"), (.array, "[1, false]"), (.object, #"{"enabled":true}"#)] {
            type.onChange(EnvironmentValueType.allCases.firstIndex(of: kind)!)
            variableValue.onChange(value)
            environments.refresh()
            precondition(model.document.environments[0].variables[0].type == kind)
            precondition(model.document.environments[0].variables[0].value == value)
        }
        variableValue.onChange("invalid JSON")
        precondition(model.document.environments[0].variables[0].value == #"{"enabled":true}"#)
        precondition(variableValue.stringValue == "invalid JSON")
        checkFormGeometry(in: environments.view)
        type.onChange(0)
        variableValue.onChange("secret-value")
        checkFormGeometry(in: environments.view)
        try snapshotForm(in: environments.view, name: "environment")
        model.addEnvironment()
        environments.refresh()
        precondition(model.document.selectedEnvironmentID == firstID)
        precondition(model.selectedEnvironmentID != firstID)
        let secondName = field("环境名称", in: environments.view)
        let savedName = model.document.environments[1].name
        secondName.selectText(nil)
        let secondNameEditor = secondName.currentEditor() as! NSTextView
        secondNameEditor.insertText(" staging ", replacementRange: NSRange(location: 0, length: secondNameEditor.string.utf16.count))
        precondition(model.document.environments[1].name == savedName, "Duplicate names must not reach the workspace")
        secondNameEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        environments.refresh()
        precondition(secondName.stringValue == " staging ", "Keep the invalid draft available for correction after editing ends")
        let nameError = descendants(environments.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "环境名称已存在" }!
        precondition(!nameError.isHidden)
        checkFormGeometry(in: environments.view)
        button("添加变量", in: environments.view).performClick(nil)
        environments.refresh()
        let rebuiltName = field("环境名称", in: environments.view)
        precondition(rebuiltName.stringValue == " staging ", "Rebuilding variable rows must preserve the invalid name draft")
        rebuiltName.onChange("production")
        environments.refresh()
        precondition(model.document.environments[1].name == "production")
        precondition(rebuiltName.stringValue == "production" && nameError.isHidden)
        rebuiltName.onChange("production")
        precondition(nameError.isHidden, "An environment must not conflict with its own name")
        precondition(!descendants(environments.view).compactMap { $0 as? NSButton }.contains { $0.title == "切换到此环境" || $0.title == "正在使用" })
        precondition(model.document.selectedEnvironmentID == firstID, "Editing another environment must not activate it")
        window.contentView?.layoutSubtreeIfNeeded()
        let split = environments.children.first as! NSSplitViewController
        split.splitView.setPosition(220, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(split.splitView.subviews[0].frame.width >= 180)
        precondition(split.splitView.subviews[0].frame.width <= 240)
        precondition(split.splitView.subviews[1].frame.width >= 420)
        precondition(abs(split.view.bounds.width - environments.view.bounds.width) < 1)
        button("删除环境", in: environments.view).performClick(nil)
        environments.refresh()
        precondition(model.document.environments.count == 1)
        precondition(model.document.selectedEnvironmentID == firstID)
        precondition(model.selectedEnvironmentID == firstID)
        button("删除变量", in: environments.view, accessibility: true).performClick(nil)
        environments.refresh()
        precondition(model.document.environments[0].variables.isEmpty)
        model.loaded = false
        environments.refresh()
        precondition(!field("环境名称", in: environments.view).isEnabled)
        let certificate = CertificateSetupViewController(model: model.certificateSetup)
        _ = certificate.view
        certificate.refresh()
        precondition(certificate.view.fittingSize.width == 480)
        precondition(!model.certificateSetup.isRunning)
        checkOutsideClickEditing()
        print("Settings AppKit checks OK: form containment and non-overlap, browser/certificate states, HTTPS decryption switch/domain validation/import refresh, upstream expansion and wrapped errors, scrolling, window, toolbar, proxy binding, environment name/typed variables/validation/delete, split geometry, read-only state and certificate construction (no App or certificate changes)")
    }

    private static func checkDomainBackground(_ general: GeneralSettingsViewController, model: WorkspaceModel,
                                             domains: NSTextView) throws {
        let scroll = domains.enclosingScrollView!
        let window = general.view.window!
        let originalAppearance = window.appearance
        let original = model.document.httpsDecryption
        defer {
            window.appearance = originalAppearance
            model.document.httpsDecryption = original
            general.refresh()
        }
        model.document.httpsDecryption.domains = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            var samples: [CGFloat] = []
            for disabled in [false, true] {
                model.document.httpsDecryption.decryptAllRequests = disabled
                general.refresh()
                general.view.layoutSubtreeIfNeeded()
                scroll.displayIfNeeded()
                let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                precondition(color.alphaComponent > 0.99, "Domain background must cover the viewport")
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                samples.append(brightness)
                if let prefix = ProcessInfo.processInfo.environment["REQUESTMAN_SETTINGS_SNAPSHOT"] {
                    let style = appearance == .aqua ? "light" : "dark"
                    let state = disabled ? "disabled" : "editable"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(prefix)-domain-\(style)-\(state).png"))
                }
            }
            print("Domain background pixels \(appearance.rawValue): editable=\(samples[0]), disabled=\(samples[1])")
        }
    }

    private static func checkDomainScrolling(_ general: GeneralSettingsViewController, model: WorkspaceModel,
                                            domains: NSTextView) {
        let inner = domains.enclosingScrollView!
        let outer = descendants(general.view).compactMap { $0 as? NSScrollView }.first { $0 !== inner }!
        let original = model.document.httpsDecryption
        let outerOrigin = outer.contentView.bounds.origin
        defer {
            model.document.httpsDecryption = original
            general.refresh()
            outer.contentView.scroll(to: outerOrigin)
            outer.reflectScrolledClipView(outer.contentView)
        }
        // Exercise both disabled and editable fields, including shrink after overflow.
        for disabled in [true, false] {
            model.document.httpsDecryption.decryptAllRequests = disabled
            for count in [0, 1, 80, 1] {
                model.document.httpsDecryption.domains = (0..<count).map { "host\($0).example.test" }
                general.refresh()
                domains.layoutManager!.ensureLayout(for: domains.textContainer!)
                general.view.layoutSubtreeIfNeeded()
                outer.contentView.scroll(to: .zero)
                outer.reflectScrolledClipView(outer.contentView)
                inner.contentView.scroll(to: .zero)
                inner.reflectScrolledClipView(inner.contentView)
                let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: -40, wheel2: 0, wheel3: 0)!
                domains.scrollWheel(with: NSEvent(cgEvent: wheel)!)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if count < 2 {
                    precondition(outer.contentView.bounds.minY > 0 && abs(inner.contentView.bounds.minY) < 1,
                                 "Fitting domain text must forward scrolling to settings, even when disabled")
                } else {
                    precondition(inner.contentView.bounds.minY > 0 && abs(outer.contentView.bounds.minY) < 1,
                                 "Overflowing domain text must retain internal scrolling")
                }
            }
        }
    }

    private static func checkSharedInputs() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var changes: [String] = []
        var submissions = 0
        let field = ActionTextField { changes.append($0) }
        field.onSubmit = { submissions += 1 }
        field.frame = NSRect(x: 20, y: 150, width: 300, height: 32)
        window.contentView!.addSubview(field)
        field.selectText(nil)
        let editor = field.currentEditor() as! NSTextView
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        precondition(!field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        precondition(editor.hasMarkedText() && submissions == 0, "Return must leave IME composition to AppKit")
        editor.insertText("中文", replacementRange: editor.markedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(submissions == 1 && changes.last == "中文" && field.currentEditor() == nil)
        field.stringValue = "programmatic"
        precondition(changes.last == "中文", "Model refresh must not send a user-edit callback")

        changes = []
        let combo = ActionComboBox(suggestions: ["Accept", "Host"]) { changes.append($0) }
        combo.frame = NSRect(x: 20, y: 100, width: 300, height: 32)
        window.contentView!.addSubview(combo)
        combo.selectText(nil)
        let comboEditor = combo.currentEditor() as! NSTextView
        comboEditor.insertText("  X-Custom  ", replacementRange: NSRange(location: 0, length: 0))
        let count = changes.count
        comboEditor.setSelectedRange(NSRange(location: 2, length: 8))
        combo.setSuggestions(["Content-Type", "Host"])
        precondition(combo.stringValue == "  X-Custom  " && changes.count == count)
        precondition(comboEditor.selectedRange() == NSRange(location: 2, length: 8), "Candidate refresh must retain the editing selection")
        comboEditor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: comboEditor.selectedRange())
        combo.setSuggestions(["Accept", "Content-Type"])
        precondition(comboEditor.hasMarkedText(), "Candidate refresh must retain IME composition")
        comboEditor.insertText("名称", replacementRange: comboEditor.markedRange())
        window.makeFirstResponder(nil)
        combo.selectItem(at: 1)
        combo.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: combo))
        precondition(combo.stringValue == "Content-Type" && changes.last == "Content-Type")

        let readOnly = ActionTextArea(editable: false)
        readOnly.string = "read-only"
        readOnly.isEnabled = false; readOnly.isEnabled = true
        precondition(!readOnly.textView.isEditable && readOnly.textView.isSelectable,
                     "Re-enabling a read-only viewer must not turn it into an editor")
        print("Shared input checks passed: IME-safe Return, commit, programmatic refresh, ComboBox draft/selection/IME preservation and read-only state")
    }

    private static func checkOutsideClickEditing() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = window.contentView!
        var saved = ""
        let field = ActionTextField { saved = $0 }
        field.frame = NSRect(x: 20, y: 120, width: 180, height: 24)
        root.addSubview(field)
        field.selectText(nil)
        let editor = field.currentEditor() as! NSTextView
        editor.insertText("latest value", replacementRange: NSRange(location: 0, length: 0))
        func click(_ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NativeTextEditing.finishEditingOutside(click(NSPoint(x: 40, y: 130)))
        precondition(field.currentEditor() != nil, "Clicking inside the field must retain its editor")
        NSApplication.shared.sendEvent(click(NSPoint(x: 350, y: 30)))
        precondition(field.currentEditor() == nil && saved == "latest value",
                     "A background click must commit the value and remove focus")

        var receivedClick = false
        let target = ActionButton(title: "提交检查") {
            precondition(field.currentEditor() == nil && saved == "before action",
                         "Editing must finish before the clicked view handles its action")
            receivedClick = true
        }
        target.frame = NSRect(x: 250, y: 110, width: 100, height: 50)
        root.addSubview(target)
        field.selectText(nil)
        let nextEditor = field.currentEditor() as! NSTextView
        nextEditor.insertText("before action", replacementRange: NSRange(location: 0, length: nextEditor.string.utf16.count))
        let actionEvent = click(NSPoint(x: 280, y: 130))
        // Hidden windows do not dispatch control tracking. Observe the unchanged
        // event, then exercise the native action after all local monitors finish.
        // AppKit does not promise registration order for those monitors.
        var forwardedEvent: NSEvent?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if event === actionEvent { forwardedEvent = event }
            }
            return event
        }!
        NSApplication.shared.sendEvent(actionEvent)
        NSEvent.removeMonitor(monitor)
        precondition(forwardedEvent === actionEvent, "Editing must preserve the original mouse event")
        target.performClick(nil)
        precondition(receivedClick, "Ending editing must not swallow the original mouse event")

        let multiline = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 80))
        root.addSubview(multiline)
        window.makeFirstResponder(multiline)
        multiline.insertText("first", replacementRange: NSRange(location: 0, length: 0))
        multiline.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(multiline.string == "first\n" && window.firstResponder === multiline,
                     "Return must keep its normal newline behavior in multiline editors")
        NSApplication.shared.sendEvent(click(NSPoint(x: 350, y: 30)))
        precondition(window.firstResponder !== multiline, "A background click must also end multiline editing")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func snapshotForm(in view: NSView, name: String) throws {
        guard let prefix = ProcessInfo.processInfo.environment["REQUESTMAN_SETTINGS_SNAPSHOT"],
              let root = view.window?.contentView,
              let scroll = descendants(view).compactMap({ $0 as? NSScrollView }).last(where: { !($0.documentView is NSTextView) }),
              let document = scroll.documentView else { return }
        // Include the window backing when capturing transparent native controls.
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let origin = scroll.contentView.bounds.origin
        defer { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        for (position, y) in [("top", CGFloat.zero), ("bottom", max(0, document.bounds.height - scroll.contentSize.height))] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            root.layoutSubtreeIfNeeded()
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(prefix)-\(name)-\(position).png"))
        }
    }
    private static func checkFormGeometry(in view: NSView) {
        view.layoutSubtreeIfNeeded()
        let boxes = descendants(view).compactMap { $0 as? NSBox }.filter { $0.boxType == .primary && !$0.isHiddenOrHasHiddenAncestor }
        precondition(!boxes.isEmpty)
        for box in boxes {
            let content = box.contentView!
            let contentFrame = content.convert(content.bounds, to: box)
            precondition(contentFrame.minY >= 11.5 && box.bounds.maxY - contentFrame.maxY >= 11.5,
                         "Settings group \(box.title) must keep vertical content padding after rows hide")
            if !box.title.isEmpty {
                let section = box.superview as! NSStackView
                let header = section.arrangedSubviews.first!
                precondition(header !== box, "Group headings must be outside the box")
                let headingFrame = header.convert(header.bounds, to: section)
                let boxFrame = box.convert(box.bounds, to: section)
                let gap = max(headingFrame.minY - boxFrame.maxY, boxFrame.minY - headingFrame.maxY)
                precondition(gap >= 7.5, "Settings group \(box.title) must have space below its heading")
            }
            precondition(content.bounds.height + 0.5 >= content.fittingSize.height,
                         "Settings group \(box.title) clips its content: \(content.bounds.height) < \(content.fittingSize.height)")
            for control in descendants(content).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                let frame = control.convert(control.bounds, to: box)
                precondition(frame.height + 0.5 >= max(0, control.intrinsicContentSize.height),
                             "Settings group \(box.title) compresses a visible control")
                precondition(box.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Settings group \(box.title) must contain its controls")
                precondition(!frame.intersects(box.titleRect), "Settings group \(box.title) overlaps its title")
            }
        }
        for stack in descendants(view).compactMap({ $0 as? NSStackView }) where stack.orientation == .vertical && !stack.isHiddenOrHasHiddenAncestor {
            let frames = stack.arrangedSubviews.filter { !$0.isHidden }.map { $0.convert($0.bounds, to: stack) }
            for (first, second) in zip(frames, frames.dropFirst()) {
                precondition(!first.intersects(second), "Settings rows, groups and footers must not overlap")
            }
        }
    }
    private static func field(_ name: String, in view: NSView) -> ActionTextField {
        descendants(view).compactMap { $0 as? ActionTextField }.first { $0.accessibilityLabel() == name }!
    }
    private static func button(_ name: String, in view: NSView, accessibility: Bool = false) -> NSButton {
        descendants(view).compactMap { $0 as? NSButton }.first { accessibility ? $0.accessibilityLabel() == name : $0.title == name }!
    }
}
