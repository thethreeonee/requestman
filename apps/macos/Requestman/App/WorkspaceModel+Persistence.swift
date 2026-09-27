import AppKit
import RequestmanCore

extension WorkspaceModel {
    func load() async {
        guard !loaded, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            document = try await documentStore.load()
            selectedWorkflowID = document.projects.first?.workflows.first?.id
            selectedEnvironmentID = document.selectedEnvironmentID ?? document.environments.first?.id
            loaded = true; loadFailed = false; saveState = "已保存"
        } catch {
            loadFailed = true
            errorMessage = "工作区读取失败：\(error.localizedDescription)"; saveState = "读取失败"
        }
        do { try await captureService.recoverSystemProxy() }
        catch {
            needsSystemProxyRecovery = true
            errorMessage = "恢复上次的系统代理设置失败：\(error.localizedDescription)"
        }
        await reloadBrowsers()
    }
    func clearWorkspace() async throws {
        guard canClearWorkspace else { throw WorkflowError.invalid("请等待当前操作完成后再清除工作区") }
        let wasLoaded = loaded
        var cleared = false
        isTransitioning = true
        loaded = false
        defer { loaded = wasLoaded || cleared; isTransitioning = false }
        revision += 1
        saveTask?.cancel()
        proxyConfigurationTask?.cancel()
        proxyConfigurationTask = nil
        let previousSave = saveTask
        // Finish any already-started write/update before replacing its snapshot.
        await previousSave?.value
        do {
            try await captureService.stop()
            synchronizeCaptureState()
            if needsSystemProxyRecovery {
                try await captureService.recoverSystemProxy()
                needsSystemProxyRecovery = false
            }
            let empty = WorkspaceDocument()
            try await documentStore.save(empty)
            workspaceGeneration += 1
            document = empty
            proxyConfigurationPending = false
            proxyConfigurationError = nil
            selectedWorkflowID = nil
            selectedStepID = nil
            selectedEnvironmentID = nil
            editingResponse = false
            selection = .rules
            clearHistory()
            history.filter = CaptureRecordFilter()
            setRecordingPaused(false)
            errorMessage = nil
            saveState = "已保存"
            loadFailed = false
            cleared = true
            await captureService.update(document: empty)
        } catch {
            synchronizeCaptureState()
            // A failed load has no valid snapshot to save over the original file.
            if wasLoaded { scheduleSave() }
            throw WorkflowError.invalid("工作区未清除：\(error.localizedDescription)")
        }
    }
    func scheduleSave() {
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
    func importArchive(_ archive: WorkspaceArchive) async throws {
        guard loaded, !isTransitioning else { throw WorkflowError.invalid("请等待当前操作完成后再导入") }
        let merged = try archive.merging(into: document)
        let preferences = archive.scope == .workspace ? try archive.preferenceValues() : nil
        isTransitioning = true
        loaded = false
        defer { loaded = true; isTransitioning = false }
        revision += 1
        saveTask?.cancel()
        // Save first: a bad file or disk failure must leave the current workspace intact.
        do { try await documentStore.save(merged) }
        catch { scheduleSave(); throw error }
        let previousProxy = document.proxy
        document = merged
        if let preferences {
            UserDefaults.standard.setPersistentDomain(preferences, forName: WorkspaceTransfer.preferencesDomain)
            captureMode = CaptureMode(rawValue: preferences["captureMode"] as? String ?? "") ?? .systemProxy
            selectedBrowserID = preferences["selectedBrowserID"] as? String ?? ""
            NotificationCenter.default.post(name: WorkspaceTransfer.preferencesRestored, object: nil)
        }
        selectedEnvironmentID = document.selectedEnvironmentID ?? document.environments.first?.id
        selectedWorkflowID = document.projects.suffix(archive.document.projects.count).first?.workflows.first?.id ?? selectedWorkflowID
        selectedStepID = nil
        saveState = "已保存"
        await captureService.update(document: document)
        if document.proxy != previousProxy { scheduleProxyConfiguration() }
    }

}
