import AppKit
import Observation
import RequestmanCore

@main
struct RequestmanEntry {
    @MainActor static func main() {
        if WorkflowScript.runWorkerIfRequested() { return }
        let application = NSApplication.shared
        let delegate = WorkspaceAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class WorkspaceAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: WorkspaceModel!
    private var workspaceWindow: WorkspaceWindowController?
    private var settingsWindow: WorkspaceSettingsWindowController?
    private var recordsTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = WorkspaceModel()
        installMenus()
        let controller = WorkspaceWindowController(model: model) { [weak self] in self?.showSettings(nil) }
        workspaceWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        recordsTask = Task { [weak self] in
            guard let self else { return }
            await model.certificateSetup.prepareForStartup()
            await model.load()
            await model.collectRecords()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model else { return }
        Task { await model.certificateSetup.prepareForStartup() }
    }
    func applicationDidResignActive(_ notification: Notification) {
        guard let model else { return }
        Task { await model.flushSave() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { workspaceWindow?.showWindow(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            let saved = await model.prepareToQuit()
            if saved { recordsTask?.cancel() }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = WorkspaceSettingsWindowController(model: model) }
        settingsWindow?.showWindow(sender)
        settingsWindow?.window?.makeKeyAndOrderFront(sender)
    }
    @objc private func showWorkspace(_ sender: Any?) { workspaceWindow?.showWindow(sender) }

    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let app = NSMenu(title: "Requestman"); appItem.submenu = app
        app.addItem(withTitle: "关于 Requestman", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        let services = NSMenu(title: "服务")
        let servicesItem = app.addItem(withTitle: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 Requestman", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "退出 Requestman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
                                       ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                       ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windows = NSMenu(title: "窗口"); windowItem.submenu = windows
        let main = windows.addItem(withTitle: "Requestman", action: #selector(showWorkspace(_:)), keyEquivalent: "0")
        main.target = self
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
}

@MainActor
final class WorkspaceWindowController: NSWindowController {
    private let model: WorkspaceModel
    let workspace: WorkspaceSplitController
    private var showingError = false

    init(model: WorkspaceModel, openSettings: @escaping () -> Void) {
        self.model = model
        workspace = WorkspaceSplitController(model: model, snapshot: WorkspaceToolbarSnapshot(model: model), openSettings: openSettings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Requestman"
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.contentMinSize = NSSize(width: 1100, height: 680)
        window.center()
        window.setFrameAutosaveName("Requestman.Workspace")
        observeErrors()
    }
    required init?(coder: NSCoder) { nil }

    private func observeErrors() {
        let message = withObservationTracking { model.errorMessage } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeErrors() }
        }
        presentError(message)
    }

    private func presentError(_ message: String?) {
        guard !showingError, let message, let window else { return }
        showingError = true
        let alert = NSAlert(); alert.messageText = "Requestman"; alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self else { return }
            self.showingError = false
            if self.model.errorMessage == message {
                self.model.errorMessage = nil
            } else {
                self.presentError(self.model.errorMessage)
            }
        }
    }
}
