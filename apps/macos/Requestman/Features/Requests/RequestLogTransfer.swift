import AppKit
import RequestmanCore

@MainActor
enum RequestLogTransfer {
    private static var openingTask: Task<Void, Never>?

    static func save(records: [CaptureRecord], window: NSWindow?) {
        guard !records.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.title = records.count == 1 ? "保存当前请求会话" : "保存当前日志"
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd HH-mm-ss"
        panel.nameFieldStringValue = "Requestman " + date.string(from: Date()) + RequestLogArchive.filenameSuffix
        present(panel, window: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await Task.detached(priority: .utility) { try await RequestLogArchive.write(records, to: url) }.value
                } catch { show(error, action: "保存日志失败", window: window) }
            }
        }
    }

    static func open(model: WorkspaceModel, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.title = "打开日志文件"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        present(panel, window: window) { response in
            guard response == .OK, let url = panel.url else { return }
            openingTask?.cancel()
            openingTask = Task {
                let reader = Task.detached(priority: .utility) { try RequestLogArchive.read(from: url) }
                do {
                    let contents = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
                    try Task.checkCancellation()
                    model.history.openLog(contents.records, name: url.lastPathComponent)
                    model.selection = .requests
                } catch is CancellationError {
                } catch { show(error, action: "打开日志失败", window: window) }
            }
        }
    }

    private static func present(_ panel: NSSavePanel, window: NSWindow?, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private static func show(_ error: any Error, action: String, window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = action; alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
