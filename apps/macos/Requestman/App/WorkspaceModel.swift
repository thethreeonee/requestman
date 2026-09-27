import AppKit
import Foundation
import Observation
import RequestmanCore
import RequestmanCertificates

@MainActor @Observable
final class WorkspaceModel {
    // Navigation requests reveal a window; each window keeps its own fixed content.
    var selection: WorkspaceSection = .rules {
        didSet { openSection?(selection) }
    }
    @ObservationIgnored var openSection: ((WorkspaceSection) -> Void)?
    var settingsSection: WorkspaceSettingsSection = .general
    var captureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "") ?? .systemProxy {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode") }
    }
    var document = WorkspaceDocument() {
        didSet {
            if loaded {
                scheduleSave()
                if document.proxy != oldValue.proxy { scheduleProxyConfiguration() }
            }
        }
    }
    var selectedWorkflowID: UUID?
    var selectedStepID: UUID?
    var editingResponse = false
    var selectedEnvironmentID: UUID?
    var isCapturing = false
    var isTransitioning = false {
        didSet {
            if oldValue, !isTransitioning, proxyConfigurationPending { scheduleProxyConfiguration() }
        }
    }
    var isLaunchingBrowser = false
    var isCheckingUpstream = false
    var isPreparingToQuit = false
    var installedBrowsers: [ChromiumBrowser] = []
    var isDiscoveringBrowsers = false
    var selectedBrowserID = UserDefaults.standard.string(forKey: "selectedBrowserID") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedBrowserID, forKey: "selectedBrowserID")
        }
    }
    var selectedBrowser: ChromiumBrowser? { installedBrowsers.first { $0.id == selectedBrowserID } }
    var captureButtonTitle: String {
        if isCapturing { return captureService.activeMode == .systemProxy ? "停止全局接管" : captureService.activeMode == .proxyOnly ? "停止代理" : "停止浏览器捕获" }
        if isCheckingUpstream { return "正在检查上游代理…" }
        if isLaunchingBrowser { return "正在启动浏览器…" }
        return captureMode == .systemProxy ? "开始全局接管" : captureMode == .proxyOnly ? "启动代理" : "启动 \(selectedBrowser?.name ?? "浏览器")"
    }
    var captureButtonHelp: String {
        if isCapturing { return captureService.activeMode == .systemProxy ? "恢复系统代理并停止捕获" : "停止代理与捕获" }
        return captureMode == .systemProxy ? "修改系统 HTTP/HTTPS 代理并开始捕获" : captureMode == .proxyOnly ? "启动代理，等待设备连接" : "通过代理参数启动 \(selectedBrowser?.name ?? "所选浏览器")"
    }

    var proxyConfigurationError: String?
    var activeProxyConfiguration: ExplicitProxyConfiguration?
    var listenPort: Int?
    var errorMessage: String?
    var saveState = "正在载入"
    var loaded = false
    var loadFailed = false
    var canClearWorkspace: Bool { !isTransitioning && (loaded || loadFailed) }
    let history = ExecutionHistoryModel()
    let certificateSetup: CertificateSetupModel
    @ObservationIgnored let captureService: any CaptureService
    @ObservationIgnored let ruleHitNotifications: (any RuleHitNotificationDelivering)?
    @ObservationIgnored let documentStore: WorkspaceDocumentStore
    @ObservationIgnored let browserLauncher = BrowserLauncher()
    @ObservationIgnored var activeBrowser: ChromiumBrowser?
    @ObservationIgnored var needsSystemProxyRecovery = false
    @ObservationIgnored var replayTasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var proxyConfigurationTask: Task<Void, Never>?
    @ObservationIgnored var proxyConfigurationPending = false
    @ObservationIgnored var revision = 0
    @ObservationIgnored var workspaceGeneration = 0

    init(captureService: any CaptureService,
         certificateSetup: CertificateSetupModel,
         documentStore: WorkspaceDocumentStore,
         ruleHitNotifications: (any RuleHitNotificationDelivering)? = nil) {
        self.captureService = captureService
        self.certificateSetup = certificateSetup
        self.documentStore = documentStore
        self.ruleHitNotifications = ruleHitNotifications
    }
}
