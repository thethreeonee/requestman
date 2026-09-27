import AppKit
import RequestmanCore
import RequestmanCertificates

// Compile the real WorkspaceModel against side-effect-free host adapters.
enum WorkspaceSettingsSection { case general, environments }
enum WorkspaceTransfer {
    static let preferencesDomain = "Requestman.Reset.Checks"
    static let preferencesRestored = Notification.Name("Requestman.Reset.Checks")
}
struct ChromiumBrowser {
    let id: String
    let name: String
    let applicationURL: URL
}
enum ChromiumBrowserCatalog {
    static func installedBrowsers() async -> [ChromiumBrowser] {
        // Match the loaded preference so discovery never writes real UserDefaults.
        [ChromiumBrowser(id: UserDefaults.standard.string(forKey: "selectedBrowserID") ?? "",
                         name: "Fixture", applicationURL: URL(fileURLWithPath: "/fixture"))]
    }
}
struct BrowserLauncher {
    func validate(_ browser: ChromiumBrowser) throws { preconditionFailure("Unexpected browser validation") }
    func launch(browser: ChromiumBrowser, proxyPort: Int) async throws { preconditionFailure("Unexpected browser launch") }
}
@MainActor final class RequestReplayEditor: NSViewController {
    init(draft: RequestReplayDraft, send: @escaping (RequestReplayDraft) async throws -> Void) {
        preconditionFailure("Unexpected replay editor during workspace reset")
    }
    required init?(coder: NSCoder) { preconditionFailure("Unexpected replay editor decoding") }
}
@MainActor enum UpstreamProxyPrompt {
    static func choose(endpoint: ProxyEndpoint, reason: String, window: NSWindow?) async -> UpstreamFailureDecision {
        preconditionFailure("Unexpected upstream prompt")
    }
}
struct ResetCertificateService: CertificateService {
    func status() async throws -> CertificateStatus { preconditionFailure("Unexpected certificate access") }
    func migrateAuthorization(allowingUI: Bool) async throws -> CertificateStatus { preconditionFailure("Unexpected certificate access") }
    func generate() async throws -> CertificateStatus { preconditionFailure("Unexpected certificate access") }
    func regenerate() async throws -> CertificateStatus { preconditionFailure("Unexpected certificate access") }
    func install() async throws -> CertificateStatus { preconditionFailure("Unexpected certificate access") }
    func trust() async throws -> CertificateStatus { preconditionFailure("Unexpected certificate access") }
}
@MainActor final class LocalCaptureService: CaptureService {
    let availability = CaptureAvailability.available
    let recordBuffer: CaptureRecordBuffer? = CaptureRecordBuffer()
    var activePort: Int? = 9090
    var activeMode: CaptureMode? = .browser
    var stopFails = false
    var stopCount = 0
    var updates: [WorkspaceDocument] = []
    var suspendedUpdate: CheckedContinuation<Void, Never>?
    var suspendNextUpdate = false
    init() {}
    func start(configuration: CaptureConfiguration) async throws { preconditionFailure("Unexpected capture start") }
    func update(document: WorkspaceDocument) async {
        if suspendNextUpdate {
            suspendNextUpdate = false
            await withCheckedContinuation { suspendedUpdate = $0 }
        }
        updates.append(document)
    }
    func stop() async throws {
        stopCount += 1
        if stopFails { throw WorkflowError.invalid("fixture stop failed") }
        activePort = nil
        activeMode = nil
    }
}

@main @MainActor struct WorkspaceResetChecks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = WorkspaceDocumentStore(url: directory.appendingPathComponent("workspace.json"))
        let service = LocalCaptureService()
        let model = WorkspaceModel(captureService: service, certificateSetup: CertificateSetupModel(service: ResetCertificateService()),
                                   documentStore: store)
        var original = WorkspaceDocument()
        var project = WorkflowProject()
        project.workflows = [RequestWorkflow()]
        original.projects = [project]
        original.environments = [WorkspaceEnvironment(name: "test")]
        original.selectedEnvironmentID = original.environments[0].id
        original.proxy.port = 9191
        original.httpsDecryption.decryptAllRequests = false
        original.httpsDecryption.domains = ["example.test"]
        model.document = original
        model.loaded = true
        model.isCapturing = true
        model.listenPort = 9090
        model.selectedWorkflowID = project.workflows[0].id
        model.selectedStepID = UUID()
        model.selectedEnvironmentID = original.selectedEnvironmentID
        let record = CaptureRecord(method: "GET", url: "http://example.test")
        model.history.append([record], dropped: 2)
        model.history.selectedID = record.id
        model.history.filter.search = "test"
        service.recordBuffer!.append(record)
        model.setRecordingPaused(true)
        try await store.save(original)

        model.isTransitioning = true
        do { try await model.clearWorkspace(); preconditionFailure("Busy reset must fail") } catch {}
        precondition(service.stopCount == 0 && model.document == original)
        model.isTransitioning = false

        service.stopFails = true
        do { try await model.clearWorkspace(); preconditionFailure("Stop failure must abort reset") } catch {}
        let unchanged = try await store.load()
        precondition(unchanged == original && model.document == original)
        precondition(model.isCapturing && model.history.records.count == 1 && model.loaded && !model.isTransitioning)

        service.stopFails = false
        // Hold an old autosave inside CaptureService.update while reset starts.
        service.suspendNextUpdate = true
        model.document = original
        while service.suspendedUpdate == nil { try await Task.sleep(for: .milliseconds(20)) }
        let reset = Task { try await model.clearWorkspace() }
        try await Task.sleep(for: .milliseconds(40))
        precondition(!model.loaded && model.isTransitioning && model.document == original)
        service.suspendedUpdate?.resume()
        service.suspendedUpdate = nil
        try await reset.value
        precondition(model.document == WorkspaceDocument())
        precondition(model.selectedWorkflowID == nil && model.selectedStepID == nil && model.selectedEnvironmentID == nil)
        precondition(!model.isCapturing && model.listenPort == nil && !model.history.paused)
        precondition(model.history.records.isEmpty && model.history.selectedID == nil && model.history.dropped == 0)
        precondition(model.history.filter == CaptureRecordFilter() && service.recordBuffer!.drain().records.isEmpty)
        precondition(service.updates.last == WorkspaceDocument())
        try await Task.sleep(for: .milliseconds(450))
        let saved = try await store.load()
        precondition(saved == WorkspaceDocument(), "Old autosaves must never restore cleared data")

        // A regular file in the parent path makes saving fail without touching user data.
        let blocked = directory.appendingPathComponent("blocked")
        try Data("fixture".utf8).write(to: blocked)
        let failingService = LocalCaptureService()
        let failing = WorkspaceModel(captureService: failingService,
                                     certificateSetup: CertificateSetupModel(service: ResetCertificateService()),
                                     documentStore: WorkspaceDocumentStore(url: blocked.appendingPathComponent("workspace.json")))
        failing.document = original
        failing.loaded = true
        failing.history.append([record], dropped: 0)
        do { try await failing.clearWorkspace(); preconditionFailure("Disk failure must abort reset") } catch {}
        precondition(failing.document == original && failing.history.records.count == 1)
        precondition(failing.loaded && !failing.isTransitioning && !failing.isCapturing)
        var legacy = original
        legacy.version = 2
        for (name, bytes) in [("old-version", try JSONEncoder().encode(legacy)),
                              ("corrupt", Data("invalid JSON".utf8))] {
            let url = directory.appendingPathComponent(name + ".json")
            try bytes.write(to: url)
            let recoveryStore = WorkspaceDocumentStore(url: url)
            let recoveryService = LocalCaptureService()
            let recovery = WorkspaceModel(captureService: recoveryService,
                                          certificateSetup: CertificateSetupModel(service: ResetCertificateService()),
                                          documentStore: recoveryStore)
            precondition(!recovery.canClearWorkspace)
            await recovery.load()
            precondition(!recovery.loaded && recovery.canClearWorkspace)
            recoveryService.stopFails = true
            do { try await recovery.clearWorkspace(); preconditionFailure("Stop failure must preserve unreadable data") } catch {}
            try await Task.sleep(for: .milliseconds(450))
            let preserved = try Data(contentsOf: url)
            precondition(preserved == bytes && !recovery.loaded && recovery.canClearWorkspace,
                         "Failed recovery must neither enable editing nor autosave an empty snapshot")
            recoveryService.stopFails = false
            try await recovery.clearWorkspace()
            let restored = try await recoveryStore.load()
            precondition(recovery.loaded && recovery.canClearWorkspace && recovery.errorMessage == nil)
            precondition(restored == WorkspaceDocument())
        }
        print("Workspace reset checks passed: busy boundary, stop/save failures, persisted empty workspace, logs, stale autosaves, old-version/corrupt-file recovery. No real proxy or certificate access.")
    }
}
