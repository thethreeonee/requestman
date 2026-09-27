import AppKit
import RequestmanCore

extension WorkspaceModel {
    var replayUnavailableReason: String? {
        if isTransitioning { return "捕获正在切换状态，请稍后重试" }
        return isCapturing ? nil : "请先启动捕获，再重放请求"
    }

    func replay(_ record: CaptureRecord, editing: Bool, presenter: NSViewController) {
        do {
            let draft = try RequestReplayDraft(record: record)
            if editing {
                guard presenter.presentedViewControllers?.isEmpty != false else { return }
                presenter.presentAsSheet(RequestReplayEditor(draft: draft) { [weak self] request in
                    guard let self else { throw CancellationError() }
                    try await sendReplay(request)
                })
            } else {
                Task {
                    do { try await sendReplay(draft) }
                    catch { errorMessage = "重放失败：\(error.localizedDescription)" }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelReplay(_ id: UUID) {
        replayTasks[id]?.cancel()
        Task { await captureService.cancelReplay(id) }
    }

    private func sendReplay(_ request: RequestReplayDraft) async throws {
        if let reason = replayUnavailableReason { throw WorkflowError.invalid(reason) }
        history.beginReplay(request)
        selection = .requests
        let task = Task { [captureService, document] in
            await captureService.update(document: document)
            try Task.checkCancellation()
            try await captureService.replay(request)
        }
        replayTasks[request.id] = task
        defer { replayTasks.removeValue(forKey: request.id) }
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            let cancelled = task.isCancelled || error is CancellationError
            history.failReplaySubmission(request.id, error: error, cancelled: cancelled)
            if !cancelled { throw error }
        }
    }

    func browserDisplayName(_ browser: ChromiumBrowser) -> String {
        installedBrowsers.filter { $0.name == browser.name }.count > 1
            ? "\(browser.name)（\(browser.applicationURL.deletingLastPathComponent().path)）" : browser.name
    }

    func refreshBrowsers() async {
        guard !isDiscoveringBrowsers, !isTransitioning else { return }
        await reloadBrowsers()
    }
    func reloadBrowsers() async {
        isDiscoveringBrowsers = true
        defer { isDiscoveringBrowsers = false }
        let browsers = await ChromiumBrowserCatalog.installedBrowsers()
        guard !Task.isCancelled else { return }
        installedBrowsers = browsers
        if selectedBrowser == nil { selectedBrowserID = browsers.first?.id ?? "" }
    }
    func collectRecords() async {
        while !Task.isCancelled {
            if let batch = captureService.recordBuffer?.drain() { history.append(batch.records, dropped: batch.dropped) }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }
    func collectRuleHitNotifications() async {
        while !Task.isCancelled {
            if captureService.activePort != nil, let buffer = captureService.ruleHitNotificationBuffer {
                for notification in buffer.drain() {
                    guard !Task.isCancelled else { return }
                    guard buffer.isCurrent(notification) else { continue }
                    // One serial consumer prevents an older revision replacing a newer body.
                    await ruleHitNotifications?.deliver(notification, from: buffer)
                }
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }
    func toggleCapture() async {
        guard loaded, !isTransitioning, isCapturing || captureMode != .browser || !isDiscoveringBrowsers else { return }
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
        await ruleHitNotifications?.prepareAuthorization()
        let port = try await captureService.start(configuration: configuration, document: document, mode: mode)
        listenPort = port
        activeProxyConfiguration = captureService.activeConfiguration
        isCapturing = true
        return port
    }
    func synchronizeCaptureState() {
        activeProxyConfiguration = captureService.activeConfiguration
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
        guard !history.isViewingFile else { return }
        history.paused = paused; captureService.recordBuffer?.setPaused(paused)
    }
    func clearHistory() { captureService.recordBuffer?.clear(); history.clear() }

    func scheduleProxyConfiguration() {
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
                activeProxyConfiguration = captureService.activeConfiguration
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
}
