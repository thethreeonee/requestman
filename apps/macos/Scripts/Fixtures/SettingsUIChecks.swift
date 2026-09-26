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
    var loaded = true
    var isTransitioning = false
    var installedBrowsers: [ChromiumBrowser] = []
    var selectedBrowserID = ""
    var isDiscoveringBrowsers = false
    var proxyConfigurationError: String?
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
    func status() async throws -> CertificateStatus { configured ? CertificateStatus(generated: true, installed: true, trusted: true) : .missing }
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

        let port = field("本地代理端口", in: controller.view)
        precondition(port.bounds.width == 140 && port.bounds.height > 0)
        port.onChange("9191")
        precondition(model.document.proxy.port == 9191)
        model.isTransitioning = true
        try await Task.sleep(for: .milliseconds(50))
        precondition(!port.isEnabled)
        model.isTransitioning = false

        let general = controller.children.first as! GeneralSettingsViewController
        model.captureMode = .browser
        model.installedBrowsers = [ChromiumBrowser(id: "test.browser", name: "Chromium Test Browser", applicationURL: URL(fileURLWithPath: "/System/Applications/Safari.app"))]
        model.selectedBrowserID = "test.browser"
        model.certificateSetup = CertificateSetupModel(service: ReadOnlyCertificateFixture(configured: true))
        await model.certificateSetup.refreshStatus()
        general.refresh()
        checkFormGeometry(in: general.view)
        try snapshotForm(in: general.view, name: "general")
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
        field("变量名称", in: environments.view).onChange("apiKey")
        field("变量值", in: environments.view).onChange("secret-value")
        environments.refresh()
        precondition(model.document.environments[0].values["apiKey"] == "secret-value")
        precondition(field("变量值", in: environments.view).stringValue == "secret-value")
        checkFormGeometry(in: environments.view)
        try snapshotForm(in: environments.view, name: "environment")
        model.addEnvironment()
        environments.refresh()
        precondition(model.document.selectedEnvironmentID == firstID)
        precondition(model.selectedEnvironmentID != firstID)
        button("切换到此环境", in: environments.view).performClick(nil)
        environments.refresh()
        precondition(model.document.selectedEnvironmentID == model.selectedEnvironmentID)
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
        precondition(model.document.selectedEnvironmentID == nil)
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
        print("Settings AppKit checks OK: form containment and non-overlap, browser/certificate states, upstream expansion and wrapped errors, scrolling, window, toolbar, proxy binding, environment editing/switch/delete, split geometry, read-only state and certificate construction (no App or certificate changes)")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func snapshotForm(in view: NSView, name: String) throws {
        guard let prefix = ProcessInfo.processInfo.environment["REQUESTMAN_SETTINGS_SNAPSHOT"],
              let root = view.window?.contentView,
              let scroll = descendants(view).compactMap({ $0 as? NSScrollView }).last,
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
            precondition(content.bounds.height + 0.5 >= content.fittingSize.height,
                         "Settings group \(box.title) clips its content: \(content.bounds.height) < \(content.fittingSize.height)")
            for control in descendants(content).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                let frame = control.convert(control.bounds, to: box)
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
