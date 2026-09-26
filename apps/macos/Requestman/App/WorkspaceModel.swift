import AppKit
import Foundation
import Observation
import RequestmanCore
import RequestmanCertificates

@MainActor @Observable
final class WorkspaceModel {
    var selection: WorkspaceSection = .rules
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
        if isCapturing { return captureService.activeMode == .systemProxy ? "停止全局接管" : "停止浏览器捕获" }
        if isCheckingUpstream { return "正在检查上游代理…" }
        if isLaunchingBrowser { return "正在启动浏览器…" }
        return captureMode == .systemProxy ? "开始全局接管" : "启动 \(selectedBrowser?.name ?? "浏览器")"
    }
    var captureButtonHelp: String {
        if isCapturing { return captureService.activeMode == .systemProxy ? "恢复系统代理并停止捕获" : "停止浏览器捕获" }
        return captureMode == .systemProxy ? "修改系统 HTTP/HTTPS 代理并开始捕获" : "通过代理参数启动 \(selectedBrowser?.name ?? "所选浏览器")"
    }

    func browserDisplayName(_ browser: ChromiumBrowser) -> String {
        installedBrowsers.filter { $0.name == browser.name }.count > 1
            ? "\(browser.name)（\(browser.applicationURL.deletingLastPathComponent().path)）" : browser.name
    }

    func refreshBrowsers() async {
        guard !isDiscoveringBrowsers, !isTransitioning else { return }
        await reloadBrowsers()
    }
    private func reloadBrowsers() async {
        isDiscoveringBrowsers = true
        defer { isDiscoveringBrowsers = false }
        let browsers = await ChromiumBrowserCatalog.installedBrowsers()
        guard !Task.isCancelled else { return }
        installedBrowsers = browsers
        if selectedBrowser == nil { selectedBrowserID = browsers.first?.id ?? "" }
    }
    var proxyConfigurationError: String?
    var listenPort: Int?
    var errorMessage: String?
    var saveState = "正在载入"
    var loaded = false
    let history = ExecutionHistoryModel()
    let certificateSetup: CertificateSetupModel
    @ObservationIgnored private let captureService: any CaptureService
    @ObservationIgnored private let documentStore: WorkspaceDocumentStore
    @ObservationIgnored private let browserLauncher = BrowserLauncher()
    @ObservationIgnored private var activeBrowser: ChromiumBrowser?
    @ObservationIgnored private var needsSystemProxyRecovery = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var proxyConfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var proxyConfigurationPending = false
    @ObservationIgnored private var revision = 0

    init(captureService: (any CaptureService)? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Requestman", isDirectory: true)
        documentStore = WorkspaceDocumentStore(url: directory.appendingPathComponent("workspace.json"))
        let certificates = LocalCertificateService(
            directoryURL: directory.appendingPathComponent("Certificates", isDirectory: true)
        )
        certificateSetup = CertificateSetupModel(service: certificates)
        self.captureService = captureService ?? LocalCaptureService(certificateProvider: certificates)
    }
    func load() async {
        guard !loaded, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            document = try await documentStore.load()
            selectedWorkflowID = document.projects.first?.workflows.first?.id
            selectedEnvironmentID = document.selectedEnvironmentID ?? document.environments.first?.id
            loaded = true; saveState = "已保存"
        } catch { errorMessage = "工作区读取失败：\(error.localizedDescription)"; saveState = "读取失败" }
        do { try await captureService.recoverSystemProxy() }
        catch {
            needsSystemProxyRecovery = true
            errorMessage = "恢复上次的系统代理设置失败：\(error.localizedDescription)"
        }
        await reloadBrowsers()
    }
    func collectRecords() async {
        while !Task.isCancelled {
            if let batch = captureService.recordBuffer?.drain() { history.append(batch.records, dropped: batch.dropped) }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }
    func toggleCapture() async {
        guard loaded, !isTransitioning, isCapturing || captureMode == .systemProxy || !isDiscoveringBrowsers else { return }
        isTransitioning = true
        defer { isTransitioning = false; isLaunchingBrowser = false }
        do {
            if isCapturing {
                try await captureService.stop()
                synchronizeCaptureState()
                return
            }
            if needsSystemProxyRecovery {
                // Finish recovery of an earlier global session before starting either mode.
                try await captureService.recoverSystemProxy()
                needsSystemProxyRecovery = false
            }
            let mode = captureMode
            var browser: ChromiumBrowser?
            if mode == .browser {
                isLaunchingBrowser = true
                let requestedBrowserID = selectedBrowserID
                await reloadBrowsers()
                guard let selectedBrowser else {
                    throw WorkflowError.invalid("未找到可用的浏览器，请在通用设置中选择浏览器。")
                }
                guard requestedBrowserID.isEmpty || selectedBrowser.id == requestedBrowserID else {
                    throw WorkflowError.invalid("所选浏览器已不可用，请在通用设置中重新选择。")
                }
                try browserLauncher.validate(selectedBrowser)
                browser = selectedBrowser
            }
            guard let port = try await startCapture(mode: mode) else { return }
            if let browser {
                do {
                    try await browserLauncher.launch(browser: browser, proxyPort: port)
                    activeBrowser = browser
                } catch {
                    let launchError = error
                    do { try await captureService.stop() }
                    catch {
                        throw WorkflowError.invalid("无法启动 \(browser.name)：\(launchError.localizedDescription)\n停止监听失败：\(error.localizedDescription)")
                    }
                    throw WorkflowError.invalid("无法启动 \(browser.name)：\(launchError.localizedDescription)")
                }
            }
        } catch {
            synchronizeCaptureState()
            errorMessage = error.localizedDescription
        }
    }
    private func startCapture(mode: CaptureMode) async throws -> Int? {
        let window = NSApp.keyWindow
        let configuration: ExplicitProxyConfiguration
        do {
            configuration = try await CaptureStartupPreflight.prepare(configuration: document.proxy) { endpoint in
                isCheckingUpstream = true
                defer { isCheckingUpstream = false }
                try await captureService.checkUpstream(endpoint)
            } decide: { endpoint, reason in
                await UpstreamProxyPrompt.choose(endpoint: endpoint, reason: reason, window: window)
            }
        } catch is CancellationError {
            // Only preflight cancellation is silent; later transport failures still roll back.
            return nil
        }
        if document.proxy != configuration { document.proxy = configuration }
        let port = try await captureService.start(configuration: configuration, document: document, mode: mode)
        listenPort = port
        isCapturing = true
        return port
    }
    private func synchronizeCaptureState() {
        listenPort = captureService.activePort
        isCapturing = listenPort != nil
        if !isCapturing { activeBrowser = nil }
    }
    func prepareToQuit() async -> Bool {
        guard !isTransitioning, !isPreparingToQuit else { return false }
        isPreparingToQuit = true
        isTransitioning = true
        defer { isPreparingToQuit = false; isTransitioning = false }
        guard await flushSave() else { return false }
        do {
            try await captureService.stop()
            synchronizeCaptureState()
            return true
        } catch {
            errorMessage = "系统代理恢复失败，暂未退出，请重试停止捕获：\(error.localizedDescription)"
            return false
        }
    }
    func setRecordingPaused(_ paused: Bool) {
        history.paused = paused; captureService.recordBuffer?.setPaused(paused)
    }
    func clearHistory() { captureService.recordBuffer?.clear(); history.clear() }
    private func scheduleProxyConfiguration() {
        proxyConfigurationPending = true
        proxyConfigurationError = nil
        proxyConfigurationTask?.cancel()
        proxyConfigurationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // Only debounce tasks are cancellable; a started system-proxy transaction must finish.
            proxyConfigurationTask = nil
            guard !isTransitioning else { return }
            proxyConfigurationPending = false
            guard isCapturing else { return }
            isTransitioning = true
            defer { isTransitioning = false }
            do {
                let previousPort = listenPort
                listenPort = try await captureService.reconfigure(configuration: document.proxy, document: document)
                if captureService.activeMode == .browser, listenPort != previousPort,
                   let port = listenPort, let browser = activeBrowser {
                    // The current session keeps its browser even if next-start preferences changed.
                    do { try await browserLauncher.launch(browser: browser, proxyPort: port) }
                    catch {
                        proxyConfigurationError = "代理端口已更新，但无法启动 \(browser.name)：\(error.localizedDescription)"
                        return
                    }
                }
                proxyConfigurationError = nil
            } catch {
                synchronizeCaptureState()
                proxyConfigurationError = "代理配置未生效：\(error.localizedDescription)"
            }
        }
    }
    private func scheduleSave() {
        revision += 1
        let currentRevision = revision
        saveTask?.cancel(); saveState = "正在保存…"
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let snapshot = document
            await captureService.update(document: snapshot)
            guard !Task.isCancelled else { return }
            do {
                try await documentStore.save(snapshot)
                if revision == currentRevision { saveState = "已保存" }
            } catch { saveState = "保存失败"; errorMessage = error.localizedDescription }
        }
    }
    @discardableResult
    func flushSave() async -> Bool {
        guard loaded else { return true }
        revision += 1
        saveTask?.cancel()
        do { try await documentStore.save(document); await captureService.update(document: document); saveState = "已保存"; return true }
        catch { errorMessage = error.localizedDescription; saveState = "保存失败"; return false }
    }
    var selectedStep: ModificationStep? {
        guard let workflow else { return nil }
        return (editingResponse ? workflow.responseSteps : workflow.requestSteps).first { $0.id == selectedStepID }
    }
    var workflow: RequestWorkflow? { document.projects.flatMap(\.workflows).first { $0.id == selectedWorkflowID } }
    var projectName: String { document.projects.first { $0.workflows.contains { $0.id == selectedWorkflowID } }?.name ?? "" }
    func updateWorkflow(_ workflow: RequestWorkflow) {
        for p in document.projects.indices {
            if let w = document.projects[p].workflows.firstIndex(where: { $0.id == workflow.id }) {
                document.projects[p].workflows[w] = workflow; return
            }
        }
    }
    func addProject() { let p = WorkflowProject(); document.projects.append(p); addWorkflow(projectID: p.id) }
    func addWorkflow(projectID: UUID) {
        guard let i = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let workflow = RequestWorkflow(); document.projects[i].workflows.append(workflow)
        selectedWorkflowID = workflow.id; selectedStepID = nil
    }
    func addWorkflow(matchingURL url: String) {
        guard loaded else { return }
        if document.projects.isEmpty { document.projects.append(WorkflowProject()) }
        let index = document.projects.firstIndex { $0.workflows.contains { $0.id == selectedWorkflowID } } ?? 0
        var workflow = RequestWorkflow()
        workflow.matchTarget = .url
        workflow.matchRule = .equals
        workflow.matchPattern = url
        document.projects[index].workflows.append(workflow)
        selectedWorkflowID = workflow.id
        selectedStepID = nil
        editingResponse = false
        history.selectedID = nil
        selection = .rules
    }
    func deleteWorkflow(_ id: UUID) {
        for i in document.projects.indices { document.projects[i].workflows.removeAll { $0.id == id } }
        if selectedWorkflowID == id { selectedWorkflowID = nil; selectedStepID = nil }
    }
    func duplicateWorkflow(_ workflow: RequestWorkflow, projectID: UUID) {
        guard let i = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        var copy = workflow; copy.id = UUID(); copy.name += " 副本"
        copy.requestSteps = copy.requestSteps.map { var step = $0; step.id = UUID(); return step }
        copy.responseSteps = copy.responseSteps.map { var step = $0; step.id = UUID(); return step }
        document.projects[i].workflows.append(copy); selectedWorkflowID = copy.id
    }
    func addStep(_ kind: ModificationKind, response: Bool) {
        guard var workflow else { return }
        var step = ModificationStep(kind: kind)
        if kind == .script { step.value = response ? "// 修改响应后返回 response\nreturn response;" : "// 修改请求后返回 request\nreturn request;" }
        if response { workflow.responseSteps.append(step) } else { workflow.requestSteps.append(step) }
        updateWorkflow(workflow); editingResponse = response; selectedStepID = step.id
    }
    func addEnvironment() {
        let env = WorkspaceEnvironment(name: "新环境"); document.environments.append(env); selectedEnvironmentID = env.id
        if document.selectedEnvironmentID == nil { document.selectedEnvironmentID = env.id }
    }
}

@MainActor @Observable
final class ExecutionHistoryModel {
    private(set) var records: [CaptureRecord] = []
    private(set) var dropped = 0
    var paused = false
    var selectedID: UUID?
    var filter = CaptureRecordFilter()
    func append(_ batch: [CaptureRecord], dropped: Int) {
        guard !batch.isEmpty || dropped > 0 else { return }
        self.dropped += dropped
        records.insert(contentsOf: batch.reversed(), at: 0)
        if records.count > 500 { records.removeLast(records.count - 500) }
        if let selectedID, !records.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func clear() { records.removeAll(); selectedID = nil; dropped = 0 }
    var filtered: [CaptureRecord] { records.filter { filter.matches($0) } }
    var selected: CaptureRecord? { records.first { $0.id == selectedID } }
}
