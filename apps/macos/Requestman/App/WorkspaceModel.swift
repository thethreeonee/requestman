import AppKit
import Foundation
import Observation
import RequestmanCore

@MainActor @Observable
final class WorkspaceModel {
    var selection: WorkspaceSection = .rules
    var settingsSection: WorkspaceSettingsSection = .connection
    var document = WorkspaceDocument() { didSet { if loaded { scheduleSave() } } }
    var selectedWorkflowID: UUID?
    var selectedStepID: UUID?
    var editingResponse = false
    var selectedEnvironmentID: UUID?
    var isCapturing = false
    var isTransitioning = false
    var isLaunchingChrome = false
    var isCheckingUpstream = false
    var isPreparingToQuit = false
    var chromeLaunchError: String?
    var listenPort: Int?
    var errorMessage: String?
    var saveState = "正在载入"
    var loaded = false
    let history = ExecutionHistoryModel()
    @ObservationIgnored private let captureService: any CaptureService
    @ObservationIgnored private let documentStore: WorkspaceDocumentStore
    @ObservationIgnored private let chromeLauncher = ChromeLauncher()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0

    init(captureService: any CaptureService = LocalCaptureService()) {
        self.captureService = captureService
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Requestman", isDirectory: true)
        documentStore = WorkspaceDocumentStore(url: directory.appendingPathComponent("workspace.json"))
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
        catch { errorMessage = "恢复上次的系统代理设置失败：\(error.localizedDescription)" }
    }
    func collectRecords() async {
        while !Task.isCancelled {
            if let batch = captureService.recordBuffer?.drain() { history.append(batch.records, dropped: batch.dropped) }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }
    func toggleCapture() async {
        guard loaded, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            if isCapturing { try await captureService.stop(); isCapturing = false; listenPort = nil }
            else { _ = try await startCaptureIfNeeded() }
        } catch {
            listenPort = captureService.activePort
            isCapturing = listenPort != nil
            errorMessage = error.localizedDescription
        }
    }
    private func startCaptureIfNeeded() async throws -> Int? {
        if isCapturing, let listenPort { return listenPort }
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
        let port = try await captureService.start(configuration: configuration, document: document)
        listenPort = port
        isCapturing = true
        return port
    }
    func launchChromeAndCapture() async {
        guard loaded, !isTransitioning else { return }
        isTransitioning = true
        isLaunchingChrome = true
        chromeLaunchError = nil
        let wasCapturing = isCapturing
        defer { isTransitioning = false; isLaunchingChrome = false }
        do {
            let applicationURL = try chromeLauncher.applicationURL()
            guard let port = try await startCaptureIfNeeded() else { return }
            await captureService.update(document: document)
            try await chromeLauncher.launch(applicationURL: applicationURL, proxyPort: port)
        } catch {
            chromeLaunchError = "无法启动 Chrome：\(error.localizedDescription)"
            listenPort = captureService.activePort
            isCapturing = listenPort != nil
            // Roll back only the listener started by this action. Existing capture keeps running.
            if !wasCapturing && isCapturing {
                do {
                    try await captureService.stop()
                    isCapturing = false
                    listenPort = nil
                } catch {
                    chromeLaunchError = "\(chromeLaunchError ?? "启动失败")\n停止监听失败：\(error.localizedDescription)"
                }
            }
        }
    }
    func prepareToQuit() async -> Bool {
        guard !isTransitioning, !isPreparingToQuit else { return false }
        isPreparingToQuit = true
        isTransitioning = true
        defer { isPreparingToQuit = false; isTransitioning = false }
        guard await flushSave() else { return false }
        do {
            try await captureService.stop()
            isCapturing = false
            listenPort = nil
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
        let step = ModificationStep(kind: kind)
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
    var search = ""
    var project = ""
    var environment = ""
    var outcome: CaptureRecord.Outcome?
    func append(_ batch: [CaptureRecord], dropped: Int) {
        guard !batch.isEmpty || dropped > 0 else { return }
        self.dropped += dropped
        records.insert(contentsOf: batch.reversed(), at: 0)
        if records.count > 500 { records.removeLast(records.count - 500) }
        if let selectedID, !records.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func clear() { records.removeAll(); selectedID = nil; dropped = 0 }
    var filtered: [CaptureRecord] {
        records.filter {
            (search.isEmpty || $0.url.localizedCaseInsensitiveContains(search) || $0.workflow.localizedCaseInsensitiveContains(search)) &&
            (project.isEmpty || $0.project == project) && (environment.isEmpty || $0.environment == environment) &&
            (outcome == nil || $0.outcome == outcome)
        }
    }
    var selected: CaptureRecord? { records.first { $0.id == selectedID } }
}
