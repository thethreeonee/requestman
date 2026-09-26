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
    let certificateSetup = CertificateSetupModel(service: ReadOnlyCertificateFixture())
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
    func status() async throws -> CertificateStatus { .missing }
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

        let port = field("本地代理端口", in: controller.view)
        precondition(port.bounds.width == 140 && port.bounds.height > 0)
        port.onChange("9191")
        precondition(model.document.proxy.port == 9191)
        model.isTransitioning = true
        try await Task.sleep(for: .milliseconds(50))
        precondition(!port.isEnabled)
        model.isTransitioning = false

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
        print("Settings AppKit checks OK: window, toolbar, proxy binding, environment editing/switch/delete, split geometry, read-only state and certificate construction (no App or certificate changes)")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func field(_ name: String, in view: NSView) -> ActionTextField {
        descendants(view).compactMap { $0 as? ActionTextField }.first { $0.accessibilityLabel() == name }!
    }
    private static func button(_ name: String, in view: NSView, accessibility: Bool = false) -> NSButton {
        descendants(view).compactMap { $0 as? NSButton }.first { accessibility ? $0.accessibilityLabel() == name : $0.title == name }!
    }
}
