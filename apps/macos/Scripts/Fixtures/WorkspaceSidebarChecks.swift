import AppKit
import Foundation
import Observation
import RequestmanCore

/// Simulates key-window state without showing a window or changing the user's active app.
@MainActor
final class KeyboardCheckWindow: NSWindow {
    var hasKeyboardFocus = true
    override var isKeyWindow: Bool { hasKeyboardFocus }
}

@MainActor
final class KeyboardCommandReceiver: NSObject {
    var command: WorkspaceCommand?
    @objc func performWorkspaceCommand(_ item: NSMenuItem) { command = WorkspaceCommand(rawValue: item.tag) }
}

/// Capture menu results without touching the user's pasteboard.
@MainActor
enum RequestClipboard {
    static var copied: String?
    static func copy(_ value: String) { copied = value }
}

/// Only model and unrelated page content are fixtures. The split controller, toolbar,
/// transitions and snapshot adapter are compiled directly from the production source.
@MainActor @Observable
final class WorkspaceModel {
    var settingsSection: WorkspaceSettingsSection = .general
    var selectedWorkflowID: UUID?
    var editingResponse = false
    var selectedStepID: UUID?
    var selectedStep: ModificationStep?
    var selection: WorkspaceSection = .rules
    var document = WorkspaceDocument()
    let history = SidebarHistoryFixture()
    var loaded = true
    var isCapturing = false
    var isTransitioning = false
    var captureMode: CaptureMode = .systemProxy
    var isDiscoveringBrowsers = false
    var browserName = "Google Chrome"
    var captureButtonTitle: String {
        if isCapturing { return "停止捕获" }
        return captureMode == .browser ? "启动 \(browserName)" : "开始捕获"
    }
    var captureButtonHelp: String { "测试捕获控件" }
    func toggleCapture() async { isCapturing.toggle() }
    func setRecordingPaused(_ paused: Bool) { history.paused = paused }
    func clearHistory() { history.clear() }
}

@MainActor @Observable
final class SidebarHistoryFixture {
    var paused = false
    var records: [CaptureRecord] = []
    var selectedID: UUID?
    var filter = CaptureRecordFilter()
    var selected: CaptureRecord? { records.first { $0.id == selectedID } }
    func clear() { records.removeAll(); selectedID = nil }
}

enum WorkspaceSettingsSection { case general, environments }

@MainActor final class ProjectSidebarViewController: NSViewController {
    let outline = NSOutlineView()
    let searchField = NSSearchField()
    func canPerform(_ command: WorkspaceCommand) -> Bool { false }
    func perform(_ command: WorkspaceCommand) {}
    func createProject() {}
    func addRequest() {}
    init(model: WorkspaceModel) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
}
@MainActor final class RulesViewController: NSViewController {
    func canPerform(_ command: WorkspaceCommand) -> Bool { false }
    func perform(_ command: WorkspaceCommand) {}
    func focusName() {}
    init(model: WorkspaceModel) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
}
@MainActor final class RequestsViewController: NSViewController {
    func showFilters() {}
    func focusList() {}
    init(model: WorkspaceModel) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
}
@MainActor final class StepInspectorViewController: NSViewController {
    var isPresented = false
    init(model: WorkspaceModel) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
}
@MainActor final class RequestInspectorViewController: ObservedViewController {
    var openWorkflow: ((UUID) -> Void)?
    var workflowExists: (UUID) -> Bool = { _ in false }
    let history: SidebarHistoryFixture
    let mode: RequestInspectionMode
    var isPresented = false
    private let text = NSTextView()
    init(history: SidebarHistoryFixture, mode: RequestInspectionMode) {
        self.history = history; self.mode = mode; super.init()
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let table = NSTableView(); table.addTableColumn(NSTableColumn(identifier: .init("value")))
        let stack = NSStackView(views: [text, table]); stack.orientation = .vertical
        stack.distribution = .fillEqually; stack.alignment = .width
        view = stack
    }
    override func refresh() { text.string = mode.version.title }
}

@main
@MainActor
struct WorkspaceSidebarChecks {
    private static let inspectorToggleIdentifier = NSToolbarItem.Identifier("workspace.toggleInspector")
    private static let sidebarToggleIdentifier = NSToolbarItem.Identifier("workspace.toggleSidebar")
    private static let inspectorTitleIdentifier = NSToolbarItem.Identifier("workspace.inspectorTitle")
    private static let inspectorModeIdentifier = NSToolbarItem.Identifier("workspace.inspectorMode")
    private static let inspectorMoreIdentifier = NSToolbarItem.Identifier("workspace.inspectorMore")
    private static var widthFailures: [String] = []
    private static var toolbarGeometryFailures: [String] = []

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        checkKeyboardCommands()
        checkEnvironmentSelection()
        checkObservationIntegration()
        checkDirectController()
        precondition(widthFailures.isEmpty, widthFailures.joined(separator: "; "))
        precondition(toolbarGeometryFailures.isEmpty, toolbarGeometryFailures.joined(separator: "; "))
        print("Workspace sidebar CLI checks passed: native item roles, unique toolbar toggle and display-mode control, mode actions and persistence, 400/520 pt toolbar geometry, title visibility, selection/clear/page changes, fixed window width, safe-area geometry and teardown")
        print("Actual WorkspaceSplitView.swift executed with model/content fixtures in hidden NSWindows; no user App built/launched, window shown, network request or configuration write. Visual appearance remains unverified.")
    }

    private static func checkKeyboardCommands() {
        let model = WorkspaceModel()
        model.selection = .requests
        let record = CaptureRecord(method: "GET", url: "https://example.test/keyboard")
        model.history.records = [record]; model.history.selectedID = record.id
        let controller = WorkspaceSplitController(model: model, snapshot: .init(model: model), openSettings: {})
        let window = KeyboardCheckWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        controller.viewDidAppear()
        let oldMenu = NSApp.mainMenu
        let menu = NSMenu(title: "Fixture")
        let parent = NSMenuItem(); let commands = NSMenu(title: "Commands")
        menu.addItem(parent); parent.submenu = commands
        var keys = Set<String>()
        for command in WorkspaceCommand.allCases {
            let item = command.menuItem(target: controller)
            precondition(keys.insert("\(item.keyEquivalent):\(item.keyEquivalentModifierMask.rawValue)").inserted,
                         "Shortcuts must be unique")
            commands.addItem(item)
        }
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = oldMenu; controller.tearDown(); window.close() }
        func invoke(_ command: WorkspaceCommand) {
            commands.update()
            let keyCodes: [String: UInt16] = ["n": 45, "d": 2, "\r": 36, "\u{8}": 51, "l": 37,
                                               "1": 18, "2": 19, "f": 3, "s": 1, "i": 34, "e": 14,
                                               "r": 15, "k": 40, "c": 8]
            // Match at the NSMenu boundary. Its Backspace equivalent is 0x08;
            // physical Delete event translation (0x7F) still needs full-App acceptance.
            let characters = command.modifiers.contains(.shift) ? command.key.uppercased() : command.key
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command.modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCodes[command.key]!)!
            precondition(menu.performKeyEquivalent(with: event), "Native menu must dispatch \(command)")
        }
        let receiver = KeyboardCommandReceiver()
        for item in commands.items { item.target = receiver }
        for command in WorkspaceCommand.allCases {
            receiver.command = nil
            invoke(command)
            precondition(receiver.command == command, "Key combination must invoke only \(command)")
        }
        for item in commands.items { item.target = controller }
        precondition(controller.canPerform(.capture) && controller.canPerform(.clear))
        model.isTransitioning = true
        precondition(!controller.canPerform(.capture))
        model.isTransitioning = false
        invoke(.copyURL)
        precondition(RequestClipboard.copied == record.url)
        invoke(.recording)
        precondition(model.history.paused && !model.isCapturing)
        let recording = commands.items.first { $0.tag == WorkspaceCommand.recording.rawValue }!
        _ = controller.validateMenuItem(recording)
        precondition(recording.title == "恢复记录")
        invoke(.recording)
        precondition(!model.history.paused)
        var truncated = record; truncated.urlWasTruncated = true
        model.history.records = [truncated]
        precondition(!controller.canPerform(.copyURL) && !controller.canPerform(.copyCURL))
        model.history.records = [record]
        invoke(.clear)
        precondition(model.history.records.isEmpty && !controller.canPerform(.clear) && !controller.canPerform(.copyURL))
        invoke(.rules)
        precondition(model.selection == .rules && !controller.canPerform(.recording))
        invoke(.requests)
        precondition(model.selection == .requests)
        window.hasKeyboardFocus = false
        precondition(!controller.canPerform(.capture) && !controller.canPerform(.newWorkflow),
                     "Workspace commands must not act behind another key window")
        window.hasKeyboardFocus = true
        model.loaded = false
        precondition(!controller.canPerform(.newWorkflow))
        print("Keyboard commands passed: native menu dispatch, unique bindings, recording/clear/copy, page changes and key-window/state validation")
    }

    private static func checkEnvironmentSelection() {
        let model = WorkspaceModel()
        let dev = WorkspaceEnvironment(name: "Development")
        let prod = WorkspaceEnvironment(name: "Production")
        model.document.environments = [dev, prod]
        model.document.selectedEnvironmentID = dev.id
        var dismissals = 0
        var openedSettings = false
        let controller = EnvironmentSelectionPopover(model: model, onDismiss: { dismissals += 1 },
                                                      openSettings: { openedSettings = true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(controller.view)
        let table = controls.compactMap { $0 as? NSTableView }.first!
        let search = controls.compactMap { $0 as? NSSearchField }.first!
        let scroll = table.enclosingScrollView!
        func checkListFits() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.setContentSize(controller.preferredContentSize)
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(table.frame.height <= scroll.contentSize.height + 0.5,
                         "Up to seven environment rows must fit: rows=\(table.numberOfRows), table=\(table.frame), viewport=\(scroll.contentSize), last=\(table.rect(ofRow: max(0, table.numberOfRows - 1))), rowHeight=\(table.rowHeight), spacing=\(table.intercellSpacing)")
            if table.numberOfRows > 0 {
                let last = table.rect(ofRow: table.numberOfRows - 1)
                precondition(scroll.documentVisibleRect.contains(last), "The final environment row must be fully visible")
            }
            precondition(!scroll.hasVerticalScroller && scroll.verticalScrollElasticity == .none)
        }
        checkListFits()
        precondition(table.numberOfRows == 3 && table.selectedRow == 1)
        search.stringValue = "prod"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(table.numberOfRows == 1 && table.selectedRow == -1)
        checkListFits()
        let editor = NSTextView()
        precondition(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        precondition(table.selectedRow == 0 && model.document.selectedEnvironmentID == dev.id,
                     "Arrow navigation must not commit an environment")
        precondition(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        precondition(model.document.selectedEnvironmentID == prod.id && dismissals == 1)
        controller.cancelOperation(nil)
        precondition(dismissals == 2 && model.document.selectedEnvironmentID == prod.id)
        search.stringValue = "does-not-exist"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(table.numberOfRows == 0)
        checkListFits()
        let empty = controls.compactMap { $0 as? NSTextField }.first { $0.stringValue == "没有匹配的环境" }!
        precondition(!empty.isHidden)
        search.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(table.numberOfRows == 3 && table.selectedRow == 2 && empty.isHidden)
        checkListFits()
        let manage = controls.compactMap { $0 as? NSButton }.first { $0.title == "管理环境…" }!
        manage.performClick(nil)
        precondition(openedSettings && model.settingsSection == .environments && dismissals == 3)
        model.document.environments = []
        controller.observeModel()
        precondition(table.numberOfRows == 1)
        checkListFits()
        model.document.environments = (1...6).map { WorkspaceEnvironment(name: "Environment \($0)") }
        controller.observeModel()
        precondition(table.numberOfRows == 7)
        checkListFits()
        model.document.environments.append(WorkspaceEnvironment(name: "Environment 7"))
        controller.observeModel()
        window.setContentSize(controller.preferredContentSize)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(table.numberOfRows == 8 && scroll.hasVerticalScroller)
        precondition(table.frame.height > scroll.contentSize.height)
        table.scrollRowToVisible(7)
        precondition(scroll.documentVisibleRect.contains(table.rect(ofRow: 7)))
        search.stringValue = "Environment 1"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        checkListFits()
        let beforeKeyboardSelection = model.document.selectedEnvironmentID
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
                                   charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
        table.keyDown(with: down)
        precondition(table.selectedRow == 0 && model.document.selectedEnvironmentID == beforeKeyboardSelection)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        table.keyDown(with: enter)
        precondition(model.document.selectedEnvironmentID == model.document.environments[0].id)
        print("Environment popover checks passed: one/seven rows fit, eight rows scroll, filtering after scrolling, current selection, empty/reset, cancel and settings routing")
    }

    private static func checkDirectController() {
        let model = WorkspaceModel()
        let controller = WorkspaceSplitController(model: model, snapshot: WorkspaceToolbarSnapshot(model: model), openSettings: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let originalToolbar = NSToolbar(identifier: "SidebarChecks.Previous")
        window.toolbar = originalToolbar
        window.titleVisibility = .visible
        window.toolbarStyle = .expanded
        window.contentViewController = controller
        // NSWindow initially adopts a newly attached controller's fitting size.
        window.setContentSize(NSSize(width: 1440, height: 900))
        defer { window.close() }
        update(controller, model: model)

        let items = controller.splitViewItems
        precondition(items.count == 3)
        let sidebar = items[0], main = items[1], inspector = items[2]
        precondition(sidebar.behavior == .sidebar && main.behavior == .default && inspector.behavior == .inspector)
        precondition(sidebar.canCollapse && inspector.canCollapse)
        precondition(sidebar.allowsFullHeightLayout && inspector.allowsFullHeightLayout)
        precondition(sidebar.collapseBehavior == .preferResizingSiblingsWithFixedSplitView)
        precondition(inspector.collapseBehavior == .preferResizingSiblingsWithFixedSplitView)
        precondition(window.toolbar !== originalToolbar && window.titleVisibility == .hidden && window.toolbarStyle == .unified)
        precondition(window.styleMask.contains(.fullSizeContentView) && !window.isVisible)
        expectToolbar(window, inspectorVisible: false, requests: false)
        precondition(!sidebar.isCollapsed && inspector.isCollapsed)
        let sidebarWidth = sidebar.viewController.view.bounds.width
        if abs(sidebarWidth - 320) > 1 {
            widthFailures.append("Initial project sidebar must be 320 pt; actual \(sidebarWidth)")
        }

        // Rules use the same window-level Inspector and native toggle, with a distinct title.
        let step = ModificationStep(kind: .script)
        var annotationWorkflow = RequestWorkflow()
        annotationWorkflow.requestSteps = [ModificationStep(kind: .setHeader), step]
        annotationWorkflow.responseSteps = [step]
        var annotationProject = WorkflowProject(); annotationProject.workflows = [annotationWorkflow]
        model.document.projects.append(annotationProject); model.selectedWorkflowID = annotationWorkflow.id
        model.selectedStep = step; model.selectedStepID = step.id
        update(controller, model: model)
        settle(controller) { !inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: true, requests: false)
        if let path = ProcessInfo.processInfo.environment["REQUESTMAN_TOOLBAR_SNAPSHOT"],
           let frameView = window.contentView?.superview,
           let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        let heading = window.toolbar!.items.first { $0.itemIdentifier == inspectorTitleIdentifier }!.view as! NSStackView
        let title = heading.arrangedSubviews[0] as! NSTextField
        let annotation = heading.arrangedSubviews[1] as! NSTextField
        precondition(title.stringValue == "步骤详情" && annotation.stringValue == "请求阶段 · 第 2 步")
        precondition(annotation.font!.pointSize < title.font!.pointSize && annotation.textColor == .secondaryLabelColor)
        precondition(heading.orientation == .vertical && heading.alignment == .leading && heading.spacing == 1)
        model.document.projects[model.document.projects.count - 1].workflows[0].requestSteps.swapAt(0, 1)
        update(controller, model: model)
        precondition(annotation.stringValue == "请求阶段 · 第 1 步", "Reordering the same selected step must refresh its annotation")
        model.editingResponse = true; update(controller, model: model)
        precondition(annotation.stringValue == "响应阶段 · 第 1 步")
        model.editingResponse = false; update(controller, model: model)
        checkGeometry(controller, window: window, inspector: inspector, windowWidth: window.frame.width)
        invoke(toggleItem(window))
        settle(controller) { inspector.isCollapsed }
        precondition(model.selectedStepID == step.id)
        update(controller, model: model)
        precondition(inspector.isCollapsed, "Ordinary refresh must preserve manual collapse")
        precondition(controller.view.tryToPerform(#selector(StepInspectorPresenting.showStepInspector(_:)), with: controller.view))
        settle(controller) { !inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: true, requests: false)
        precondition(model.selectedStepID == step.id, "Reactivating the same step must reveal its inspector without clearing selection")
        controller.showStepInspector(nil)
        precondition(!inspector.isCollapsed, "Repeated activation reveals rather than toggles the inspector")
        model.selectedStep = nil; model.selectedStepID = nil
        update(controller, model: model)
        settle(controller) { inspector.isCollapsed }

        // Use the actual native segmented control/action to change the model's page.
        let sections = toolbarItem(window, label: "工作区").view as! NSSegmentedControl
        sections.selectedSegment = WorkspaceSection.allCases.firstIndex(of: .requests)!
        precondition(sections.sendAction(sections.action, to: sections.target))
        precondition(model.selection == .requests)
        update(controller, model: model)
        settle(controller) { sidebar.isCollapsed && inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: true)
        precondition(!toggleItem(window).isEnabled)
        controller.toggleInspector(nil)
        precondition(inspector.isCollapsed, "No selection cannot reveal an empty inspector")

        let record = CaptureRecord(method: "GET", url: "https://example.test/one")
        let nextRecord = CaptureRecord(method: "POST", url: "https://example.test/two")
        model.history.records = [record, nextRecord]
        model.history.selectedID = record.id
        let windowWidth = window.frame.width
        update(controller, model: model)
        settle(controller) { !inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: true, requests: true)
        let nativeToggle = toggleItem(window)
        precondition(nativeToggle.isEnabled && nativeToggle.action == #selector(NSSplitViewController.toggleInspector(_:)))
        precondition(nativeToggle.target === controller && nativeToggle.view == nil,
                     "AppKit must create the native toolbar button with an explicit split-controller target")
        let requestHeading = window.toolbar!.items.first { $0.itemIdentifier == inspectorTitleIdentifier }!.view as! NSStackView
        precondition(requestHeading.arrangedSubviews[1].isHidden, "Request-log inspector must not retain a step annotation")
        checkGeometry(controller, window: window, inspector: inspector, windowWidth: windowWidth)
        checkInitialInspectorWidth(inspector, scenario: "first selection after no selection")
        let root = inspector.viewController as! WorkspaceInspectorController
        precondition(root.requests.isPresented, "Visible inspector enables its hosted detail content")
        let inspectionMode = root.requests.mode
        checkInspectionModeActions(controller, window: window, inspector: inspector)
        checkRequestMenu(controller, model: model, window: window)
        expectInspectionMode(window, root: root, mode: inspectionMode, visible: true)

        // Invoke the native toolbar item; there must be exactly one entry point.
        invoke(toggleItem(window))
        settle(controller) { inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: true)
        precondition(model.history.selectedID == record.id, "Manual collapse preserves the selected request")
        precondition(!root.requests.isPresented)
        expectInspectionMode(window, root: root, mode: inspectionMode, visible: false)
        update(controller, model: model)
        precondition(inspector.isCollapsed, "Unrelated updates must not reopen a manually collapsed inspector")
        invoke(toggleItem(window))
        settle(controller) { !inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: true, requests: true)
        expectInspectionMode(window, root: root, mode: inspectionMode, visible: true)
        checkGeometry(controller, window: window, inspector: inspector, windowWidth: windowWidth)

        invoke(toggleItem(window))
        settle(controller) { inspector.isCollapsed }
        model.history.selectedID = nextRecord.id
        update(controller, model: model)
        settle(controller) { !inspector.isCollapsed }
        precondition(root.requests.history.selectedID == nextRecord.id)
        expectInspectionMode(window, root: root, mode: inspectionMode, visible: true)

        // Removing a retained selection, even before selectedID resets, closes details.
        model.history.records.removeAll()
        update(controller, model: model)
        settle(controller) { inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: true)
        precondition(!toggleItem(window).isEnabled)
        model.history.clear()
        update(controller, model: model)
        precondition(inspector.isCollapsed)

        model.history.records = [record]
        model.history.selectedID = record.id
        update(controller, model: model)
        settle(controller) { !inspector.isCollapsed }
        model.selection = .rules
        update(controller, model: model)
        settle(controller) { inspector.isCollapsed && !sidebar.isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: false)
        precondition(!root.requests.isPresented)

        // The project sidebar keeps a manual collapse preference across page changes.
        let sidebarToggle = window.toolbar!.items.first { $0.itemIdentifier == sidebarToggleIdentifier }!
        invoke(sidebarToggle)
        settle(controller) { sidebar.isCollapsed }
        model.selection = .requests
        update(controller, model: model)
        settle(controller) { sidebar.isCollapsed && inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: true)
        model.selection = .rules
        update(controller, model: model)
        settle(controller) { sidebar.isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: false)
        invoke(window.toolbar!.items.first { $0.itemIdentifier == sidebarToggleIdentifier }!)
        settle(controller) { !sidebar.isCollapsed }

        // Settings/capture changes are reflected in native toolbar controls through a fresh snapshot.
        model.isTransitioning = true
        update(controller, model: model)
        precondition(!(toolbarItem(window, label: "捕获").view as! NSButton).isEnabled)
        model.isTransitioning = false
        model.isCapturing = true
        update(controller, model: model)
        precondition((toolbarItem(window, label: "捕获").view as! NSButton).accessibilityLabel() == "停止捕获")

        controller.tearDown()
        precondition(window.toolbar === originalToolbar && window.titleVisibility == .visible && window.toolbarStyle == .expanded)
        precondition(!window.styleMask.contains(.fullSizeContentView))
        precondition(!window.isVisible)
    }

    private static func checkObservationIntegration() {
        let model = WorkspaceModel()
        let record = CaptureRecord(method: "GET", url: "https://example.test/initial")
        let other = CaptureRecord(method: "POST", url: "https://example.test/changed")
        model.selection = .requests
        model.history.records = [record, other]
        model.history.selectedID = record.id
        let host = WorkspaceSplitController(model: model, snapshot: WorkspaceToolbarSnapshot(model: model), openSettings: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1440, height: 900))
        defer { window.close() }
        waitFor(host) { findController(in: host) != nil }
        let controller = findController(in: host)!
        let inspector = controller.splitViewItems[2]
        // Hidden windows do not receive viewDidAppear. A model observation refresh after mounting
        // must install the toolbar through native observation, without calling it here.
        model.document.environments = [WorkspaceEnvironment(name: "fixture")]
        model.document.selectedEnvironmentID = model.document.environments[0].id
        waitFor(host) { window.toolbar != nil }
        precondition(!inspector.isCollapsed, "Initial selected request must open the inspector through observation")
        precondition((inspector.viewController as! WorkspaceInspectorController).requests.isPresented)
        expectToolbar(window, inspectorVisible: true, requests: true)
        let originalWidth = window.frame.width
        checkGeometry(controller, window: window, inspector: inspector, windowWidth: originalWidth)
        checkInitialInspectorWidth(inspector, scenario: "initial snapshot already has a selection")
        let inspectorRoot = inspector.viewController as! WorkspaceInspectorController
        let inspectionMode = inspectorRoot.requests.mode
        checkInspectionModeActions(host, window: window, inspector: inspector)
        checkInspectorToolbarGeometry(controller, window: window, inspector: inspector)
        checkCaptureButton(host, model: model, window: window)

        // With no focused control, the actual native toolbar item's explicit target must still work.
        precondition(window.makeFirstResponder(nil))
        precondition(window.firstResponder === window)
        let item = toggleItem(window)
        precondition(item.target === controller && item.view == nil)
        invoke(item)
        waitFor(host) { inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: true)
        expectInspectionMode(window, root: inspectorRoot, mode: inspectionMode, visible: false)

        // Observation must update native state without calling controller.update or replacing a page.
        model.history.selectedID = other.id
        waitFor(host) { !inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: true, requests: true)
        expectInspectionMode(window, root: inspectorRoot, mode: inspectionMode, visible: true)
        checkHostedBodyAction(host, window: window, inspector: inspector, type: NSTextView.self)
        model.history.selectedID = record.id
        waitFor(host) { !inspector.isCollapsed }
        checkHostedBodyAction(host, window: window, inspector: inspector, type: NSTableView.self)
        model.history.selectedID = other.id
        waitFor(host) { !inspector.isCollapsed }
        expectInspectionMode(window, root: inspectorRoot, mode: inspectionMode, visible: true)
        checkTitleGeometry(window, inspector: inspector)
        model.history.clear()
        waitFor(host) { inspector.isCollapsed && !toggleItem(window).isEnabled }
        expectToolbar(window, inspectorVisible: false, requests: true)
        checkToolbarSearch(host, model: model, window: window)
        model.selection = .rules
        waitFor(host) { !controller.splitViewItems[0].isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: false)
        checkDividerResizing(host, controller: controller, model: model, window: window)
        precondition(!window.isVisible, "The CLI check must never show a window")
        controller.tearDown()
        log("AppKit observation integration actions passed: Observation-driven selection/clear/page updates and native toolbar actions with empty/text/table focus.")
    }

    private static func checkDividerResizing(_ host: NSViewController, controller: WorkspaceSplitController,
                                             model: WorkspaceModel, window: NSWindow) {
        let step = ModificationStep(kind: .setHeader)
        model.selectedStep = step
        model.selectedStepID = step.id
        let sidebar = controller.splitViewItems[0]
        let inspector = controller.splitViewItems[2]
        waitFor(host) { !sidebar.isCollapsed && !inspector.isCollapsed }
        for width: CGFloat in [1440, 1800, 1100] {
            window.setContentSize(NSSize(width: width, height: 900))
            waitFor(host) { true }
            let windowFrame = window.frame
            for sidebarWidth: CGFloat in [260, 400, 320] {
                controller.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
                waitFor(host) { true }
                for inspectorWidth: CGFloat in [400, 760] {
                    controller.splitView.setPosition(controller.splitView.bounds.maxX - inspectorWidth
                                                     - controller.splitView.dividerThickness, ofDividerAt: 1)
                    waitFor(host) { true }
                    let splitFrame = controller.splitView.convert(controller.splitView.bounds, to: host.view)
                    precondition(abs(splitFrame.minX - host.view.bounds.minX) < 1
                                 && abs(splitFrame.maxX - host.view.bounds.maxX) < 1,
                                 "Divider resize must keep the workspace edge-to-edge: split=\(splitFrame), host=\(host.view.bounds)")
                    precondition(window.frame == windowFrame, "Divider resize must not resize the window")
                    for item in controller.splitViewItems where !item.isCollapsed {
                        precondition(item.viewController.view.bounds.width >= item.minimumThickness - 1)
                    }
                }
            }
        }
        log("Hosted divider resizing passed: both dividers, narrow/wide windows and workspace edges")
    }

    private static func checkToolbarSearch(_ host: NSViewController, model: WorkspaceModel, window: NSWindow) {
        let item = window.toolbar!.items.compactMap { $0 as? NSSearchToolbarItem }.first!
        let field = item.searchField
        field.stringValue = "example"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        waitFor(host) { model.history.filter.search == "example" }
        precondition(model.history.filter.matches(CaptureRecord(method: "GET", url: "https://example.test")))
        precondition(!model.history.filter.matches(CaptureRecord(method: "GET", url: "https://other.test")))
        model.history.filter = CaptureRecordFilter()
        waitFor(host) { field.stringValue.isEmpty }
        model.history.filter.search = "clear-me"
        waitFor(host) { field.stringValue == "clear-me" }
        (field.cell as! NSSearchFieldCell).cancelButtonCell!.performClick(field)
        waitFor(host) { model.history.filter.search.isEmpty }
        model.history.filter.search = "retained"
        waitFor(host) { field.stringValue == "retained" }
        model.selection = .rules
        waitFor(host) { !window.toolbar!.items.contains { $0 is NSSearchToolbarItem } }
        expectToolbar(window, inspectorVisible: false, requests: false)
        model.selection = .requests
        waitFor(host) { window.toolbar!.items.contains { $0 is NSSearchToolbarItem } }
        let restored = window.toolbar!.items.compactMap { $0 as? NSSearchToolbarItem }.first!
        precondition(restored === item && restored.searchField.stringValue == "retained")
        expectToolbar(window, inspectorVisible: false, requests: true)
        model.history.filter = CaptureRecordFilter()
        waitFor(host) { field.stringValue.isEmpty }
        log("Toolbar search passed: trailing placement, tab visibility, filtering, clear/reset and retained query")
    }

    private static func checkHostedBodyAction<T: NSView>(_ host: NSViewController, window: NSWindow,
                                                        inspector: NSSplitViewItem, type: T.Type) {
        waitFor(host) { findView(type, in: inspector.viewController.view) != nil }
        let body = findView(type, in: inspector.viewController.view)!
        precondition(window.makeFirstResponder(body), "Native body control must accept focus")
        precondition(window.firstResponder === body)
        let item = toggleItem(window)
        invoke(item)
        waitFor(host) { inspector.isCollapsed }
    }

    private static func checkInspectionModeActions(_ host: NSViewController, window: NSWindow,
                                                   inspector: NSSplitViewItem) {
        let root = inspector.viewController as! WorkspaceInspectorController
        let mode = root.requests.mode
        let item = window.toolbar!.items.first { $0.itemIdentifier == inspectorModeIdentifier }!
        let control = item.view as! NSSegmentedControl
        precondition(mode.version == .final && control.selectedSegment == 1,
                     "Each workspace starts with the modified request selected")
        precondition(control.segmentCount == 3 && control.trackingMode == .selectOne)
        precondition((0..<control.segmentCount).map { control.label(forSegment: $0) } == ["修改前", "修改后", "修改对比"])
        // AppKit may promote the configured .large size when installing the native toolbar.
        log("Hosted native mode style: style=\(control.segmentStyle.rawValue), distribution=\(control.segmentDistribution.rawValue), size=\(control.controlSize.rawValue)")
        precondition(control.segmentStyle == .automatic && control.segmentDistribution == .fit)
        if #available(macOS 26.0, *) { precondition(control.borderShape == .capsule) }
        if #available(macOS 27.0, *) { precondition(control.role == .tabs) }
        precondition(control.target === findController(in: host))
        for (index, version) in InspectionVersion.allCases.enumerated() {
            control.selectedSegment = index
            precondition(control.sendAction(control.action, to: control.target), "Use the actual segmented-control action")
            precondition(mode.version == version, "The native mode action must update the shared production state")
            waitFor(host) { findView(NSTextView.self, in: root.view)?.string == version.title }
            precondition(root.requests.mode === mode, "The hosting root must keep the same shared mode object")
        }
        precondition(mode.version == .difference)
        log("Inspector mode actions passed: three native segments update the same observable production mode and its hosted consumer; default is modified.")
    }

    private static func expectInspectionMode(_ window: NSWindow, root: WorkspaceInspectorController,
                                             mode: RequestInspectionMode, visible: Bool) {
        precondition(root.requests.mode === mode && mode.version == .difference,
                     "Display mode must survive record changes, hosted-content updates and collapse/reopen")
        let items = window.toolbar!.items.filter { $0.itemIdentifier == inspectorModeIdentifier }
        precondition(items.count == (visible ? 1 : 0), "Collapsed details must remove their sole display-mode entry")
        if visible {
            precondition((items[0].view as! NSSegmentedControl).selectedSegment == 2,
                         "Reopened mode control must preserve the selected segment")
        }
    }

    private static func checkInspectorToolbarGeometry(_ controller: WorkspaceSplitController, window: NSWindow,
                                                       inspector: NSSplitViewItem) {
        let initialWidth = inspector.viewController.view.bounds.width
        let windowWidth = window.frame.width
        let identifiers = [inspectorTitleIdentifier, inspectorModeIdentifier, inspectorMoreIdentifier, inspectorToggleIdentifier]
        for targetWidth: CGFloat in [400, 520] {
            controller.splitView.setPosition(controller.splitView.bounds.maxX - targetWidth - controller.splitView.dividerThickness,
                                             ofDividerAt: 1)
            settle(controller) { !inspector.isCollapsed }
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let inspectorView = inspector.viewController.view
            let inspectorFrame = inspectorView.convert(inspectorView.bounds, to: nil)
            let actualWidth = inspectorFrame.width
            if abs(actualWidth - targetWidth) > 1 {
                toolbarGeometryFailures.append("Cannot validate \(targetWidth) pt inspector: actual width \(actualWidth)")
            }
            let items = window.toolbar!.items.filter { identifiers.contains($0.itemIdentifier) }
            let visibleIdentifiers = Set((window.toolbar!.visibleItems ?? []).map(\.itemIdentifier))
            var frames: [String] = []
            for item in items {
                if !item.isVisible || !visibleIdentifiers.contains(item.itemIdentifier) {
                    toolbarGeometryFailures.append("\(targetWidth) pt: \(item.itemIdentifier.rawValue) overflowed or is hidden")
                }
                let nativeView = item.view ?? window.contentView?.superview.flatMap { frameView in
                    findViews(NSView.self, in: frameView).first {
                        ($0.accessibilityRole() == .button || $0.accessibilityRole() == .menuButton)
                            && ($0.accessibilityLabel() == item.label || (item.toolTip != nil && $0.toolTip == item.toolTip))
                            && !$0.isHiddenOrHasHiddenAncestor
                    }
                }
                guard let view = nativeView, view.window === window, view.bounds.width > 0 else {
                    toolbarGeometryFailures.append("\(targetWidth) pt: native view geometry unavailable for \(item.itemIdentifier.rawValue)")
                    continue
                }
                let frame = view.convert(view.bounds, to: nil)
                frames.append("\(item.itemIdentifier.rawValue)=\(NSStringFromRect(frame))")
                if frame.minX < inspectorFrame.minX - 1 || frame.maxX > inspectorFrame.maxX + 1 {
                    toolbarGeometryFailures.append("\(targetWidth) pt: \(item.itemIdentifier.rawValue) extends outside inspector \(NSStringFromRect(inspectorFrame)): \(NSStringFromRect(frame))")
                }
                if item.itemIdentifier == inspectorModeIdentifier,
                   view.bounds.width + 1 < view.intrinsicContentSize.width {
                    toolbarGeometryFailures.append("\(targetWidth) pt: native display-mode segments are compressed below their intrinsic width")
                }
            }
            checkGeometry(controller, window: window, inspector: inspector, windowWidth: windowWidth)
            log("Inspector toolbar geometry at requested \(targetWidth) pt (actual \(actualWidth)): " + frames.joined(separator: "; "))
        }
        controller.splitView.setPosition(controller.splitView.bounds.maxX - initialWidth - controller.splitView.dividerThickness,
                                         ofDividerAt: 1)
        settle(controller) { !inspector.isCollapsed }
    }

    private static func checkCaptureButton(_ host: NSViewController, model: WorkspaceModel, window: NSWindow) {
        let button = toolbarItem(window, label: "捕获").view as! NSButton
        let initialSize = button.intrinsicContentSize
        let initialWidth = button.frame.width
        model.captureMode = .browser
        waitFor(host) { button.accessibilityLabel() == "启动 Google Chrome" }
        model.browserName = "A browser with a deliberately long display name"
        waitFor(host) { button.accessibilityLabel() == model.captureButtonTitle }
        precondition(abs(button.intrinsicContentSize.width - initialSize.width) < 1
                     && abs(button.frame.width - initialWidth) < 1,
                     "Browser names must not widen the icon-only capture button")
        precondition(button.imagePosition == .imageOnly && button.image != nil,
                     "Capture updates must preserve the native icon-only layout")
        precondition(button.toolTip == model.captureButtonHelp + "（⌘R）")

        model.isTransitioning = true
        waitFor(host) { !button.isEnabled }
        button.performClick(nil)
        precondition(!model.isCapturing, "A disabled capture button must not start capture")
        model.isTransitioning = false
        waitFor(host) { button.isEnabled }
        button.performClick(nil)
        waitFor(host) { model.isCapturing && button.accessibilityLabel() == "停止捕获" }
        precondition(button.imagePosition == .imageOnly && button.image != nil)
        precondition(abs(button.frame.width - initialWidth) < 1,
                     "Switching to stop must preserve the capture button's width")
        button.performClick(nil)
        waitFor(host) { !model.isCapturing && button.accessibilityLabel() == model.captureButtonTitle }
        precondition(button.imagePosition == .imageOnly)
        log("Capture toolbar checks passed: stable icon-only layout across browser names and start/stop, accessibility labels, disabled transition and native button actions.")
    }

    private static func checkRequestMenu(_ controller: WorkspaceSplitController, model: WorkspaceModel, window: NSWindow) {
        let savedRecords = model.history.records
        let selectedID = model.history.selectedID
        defer {
            model.history.records = savedRecords
            model.history.selectedID = selectedID
            update(controller, model: model)
        }
        var record = model.history.selected!
        record.requestBody = CaptureBodyCollector().snapshot(isComplete: true)
        record.sentBody = record.requestBody
        record.sentMethod = "POST"
        record.finalURL = "https://example.test/modified"
        model.history.records = [record]
        update(controller, model: model)
        let item = window.toolbar!.items.first { $0.itemIdentifier == inspectorMoreIdentifier } as! NSMenuToolbarItem
        precondition(item.view == nil && item.isBordered, "AppKit must own the menu button's appearance")
        let menu = item.menu
        menu.delegate?.menuNeedsUpdate?(menu)
        precondition(menu.items.map(\.title) == ["复制完整 URL", "复制原始请求为 cURL", "复制修改后请求为 cURL"])
        precondition(menu.items.allSatisfy(\.isEnabled))
        for (index, menuItem) in menu.items.enumerated() {
            RequestClipboard.copied = nil
            precondition(NSApp.sendAction(menuItem.action!, to: menuItem.target, from: menuItem))
            let copied = RequestClipboard.copied!
            switch index {
            case 0: precondition(copied == record.url)
            case 1: precondition(copied.contains("--request 'GET'") && copied.contains("--url '\(record.url)'"))
            default: precondition(copied.contains("--request 'POST'") && copied.contains("--url '\(record.finalURL)'"))
            }
        }
        var next = CaptureRecord(method: "GET", url: "https://example.test/next")
        model.history.records.append(next)
        model.history.selectedID = next.id
        update(controller, model: model)
        menu.delegate?.menuNeedsUpdate?(menu)
        precondition(NSApp.sendAction(menu.items[0].action!, to: menu.items[0].target, from: menu.items[0]))
        precondition(RequestClipboard.copied == next.url, "Opening the menu again must use the new selected request")
        precondition(!menu.items[1].isEnabled && !menu.items[2].isEnabled, "Uncollected requests cannot export cURL")
        next.urlWasTruncated = true
        model.history.records = [next]
        menu.delegate?.menuNeedsUpdate?(menu)
        precondition(!menu.items[0].isEnabled, "A truncated URL cannot be copied as complete")
        log("Inspector menu checks passed: native toolbar menu, correct copy actions, fresh selection and incomplete-data restrictions; user pasteboard untouched.")
    }

    private static func checkTitleGeometry(_ window: NSWindow, inspector: NSSplitViewItem) {
        let title = window.toolbar!.items.first { $0.itemIdentifier == inspectorTitleIdentifier }!.view!
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard title.window === window, title.bounds.width > 0 else {
            log("Title geometry unavailable: AppKit did not lay out the toolbar title in the hidden window; visible-window alignment remains unverified.")
            return
        }
        let titleFrame = title.convert(title.bounds, to: nil)
        let inspectorView = inspector.viewController.view
        let inspectorFrame = inspectorView.convert(inspectorView.bounds, to: nil)
        let inset = titleFrame.minX - inspectorFrame.minX
        log("Hosted toolbar title geometry: titleX=\(titleFrame.minX), inspectorX=\(inspectorFrame.minX), inset=\(inset)")
        precondition(inset >= 0 && inset <= 40, "Inspector toolbar title must align near the inspector's leading edge")
    }

    private static func checkInitialInspectorWidth(_ inspector: NSSplitViewItem, scenario: String) {
        let width = inspector.viewController.view.bounds.width
        log("Initial inspector width (\(scenario)): \(width)")
        if abs(width - 520) > 1 {
            widthFailures.append("Initial inspector must be 520 pt (\(scenario)); actual \(width)")
        }
    }

    private static func findController(in controller: NSViewController) -> WorkspaceSplitController? {
        if let split = controller as? WorkspaceSplitController { return split }
        if let child = controller.children.lazy.compactMap({ findController(in: $0) }).first { return child }
        return findView(NSSplitView.self, in: controller.view)?.delegate as? WorkspaceSplitController
    }

    private static func findView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { findView(type, in: $0) }.first
    }

    private static func findViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        let current = (view as? T).map { [$0] } ?? []
        return current + view.subviews.flatMap { findViews(type, in: $0) }
    }

    private static func waitFor(_ host: NSViewController, file: StaticString = #fileID, line: UInt = #line,
                                until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            host.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        } while !condition() && Date() < deadline
        precondition(condition(), "AppKit integration did not reach the expected state", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.view.layoutSubtreeIfNeeded()
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func update(_ controller: WorkspaceSplitController, model: WorkspaceModel) {
        controller.update(snapshot: WorkspaceToolbarSnapshot(model: model), openSettings: {})
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.layoutSubtreeIfNeeded()
    }

    private static func settle(_ controller: WorkspaceSplitController, file: StaticString = #fileID, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        } while !condition() && Date() < deadline
        precondition(condition(), "AppKit did not reach the expected split-item state", file: file, line: line)
        // Collapse observation and toolbar reconciliation run on the main actor on the next turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        controller.view.layoutSubtreeIfNeeded()
    }

    private static func toolbarItem(_ window: NSWindow, label: String) -> NSToolbarItem {
        let matching = window.toolbar!.items.filter { $0.label == label }
        precondition(matching.count == 1, "Expected one toolbar item: " + label)
        return matching[0]
    }

    private static func toggleItem(_ window: NSWindow) -> NSToolbarItem {
        let toggles = window.toolbar!.items.filter { $0.itemIdentifier == inspectorToggleIdentifier }
        precondition(toggles.count == 1, "Inspector toggle must have exactly one native toolbar item")
        return toggles[0]
    }

    private static func invoke(_ item: NSToolbarItem) {
        precondition(item.target != nil && item.view == nil, "Use AppKit's own toolbar button and an explicit target")
        precondition(item.isEnabled && NSApp.sendAction(item.action!, to: item.target, from: item),
                     "The native toolbar action must reach the actual workspace split controller regardless of focus")
    }

    private static func expectToolbar(_ window: NSWindow, inspectorVisible: Bool, requests: Bool) {
        let items = window.toolbar!.items
        let searches = items.compactMap { $0 as? NSSearchToolbarItem }
        precondition(searches.count == (requests ? 1 : 0), "Search appears only on the request log tab")
        if requests {
            let searchIndex = items.firstIndex { $0 is NSSearchToolbarItem }!
            precondition(items[searchIndex + 1].itemIdentifier == .inspectorTrackingSeparator,
                         "Search must remain at the trailing edge of the main toolbar")
        }
        precondition(items.filter { $0.itemIdentifier == inspectorToggleIdentifier }.count == 1)
        precondition(items.filter { $0.itemIdentifier == sidebarToggleIdentifier }.count == (requests ? 0 : 1))
        precondition(!items.contains { $0.itemIdentifier == .toggleInspector || $0.itemIdentifier == .toggleSidebar },
                     "AppKit's reserved nil-target toggles must not duplicate the explicit-target native items")
        precondition(items.filter { $0.itemIdentifier == inspectorTitleIdentifier }.count == (inspectorVisible ? 1 : 0))
        precondition(items.filter { $0.itemIdentifier == inspectorModeIdentifier }.count == (inspectorVisible && requests ? 1 : 0))
        precondition(items.filter { $0.itemIdentifier == inspectorMoreIdentifier }.count == (inspectorVisible && requests ? 1 : 0))
        let infoIdentifier = NSToolbarItem.Identifier("workspace.templateInfo")
        precondition(items.filter { $0.itemIdentifier == infoIdentifier }.count == (inspectorVisible && !requests ? 1 : 0))
        if inspectorVisible && !requests {
            let index = items.firstIndex { $0.itemIdentifier == infoIdentifier }!
            precondition(items[index + 1].itemIdentifier == .space && items[index + 2].itemIdentifier == inspectorToggleIdentifier,
                         "Info and inspector toggle must occupy separate native glass groups")
            let info = items[index]
            precondition(info.label == "动态值" && info.image != nil)
            precondition(info.view == nil && info.isBordered && items[index + 2].isBordered,
                         "Info and collapse must both retain their native bordered toolbar appearance")
            precondition(info.target != nil && info.action != nil && info.isEnabled,
                         "The native info button must remain actionable")
        }
        if inspectorVisible && requests {
            let moreIndex = items.firstIndex { $0.itemIdentifier == inspectorMoreIdentifier }!
            precondition(items[moreIndex - 1].itemIdentifier == inspectorModeIdentifier,
                         "The only display-mode control belongs immediately before More")
            precondition(items[moreIndex + 1].itemIdentifier == inspectorToggleIdentifier,
                         "More belongs immediately before the inspector toggle")
        }
        precondition(items.filter { $0.itemIdentifier == .inspectorTrackingSeparator }.count == 1)
    }

    private static func checkGeometry(_ controller: WorkspaceSplitController, window: NSWindow, inspector: NSSplitViewItem, windowWidth: CGFloat) {
        controller.view.layoutSubtreeIfNeeded()
        let view = inspector.viewController.view
        let width = view.bounds.width
        precondition(width >= inspector.minimumThickness - 1 && width <= inspector.maximumThickness + 1, "Inspector width must respect native item limits")
        precondition(abs(window.frame.width - windowWidth) < 1,
                     "Showing details resizes siblings, not the window: before=\(windowWidth), after=\(window.frame.width), split=\(controller.splitView.bounds.width), inspector=\(width)")
        let frame = controller.splitView.convert(view.bounds, from: view)
        precondition(frame.width.isFinite && frame.height.isFinite && frame.height > 0)
        precondition(frame.minX >= -1 && frame.maxX <= controller.splitView.bounds.maxX + 1)
        precondition(view.safeAreaInsets.top >= 0 && view.safeAreaInsets.bottom >= 0)
        precondition(view.safeAreaRect.width >= 0 && view.safeAreaRect.height >= 0)
        precondition(inspector.allowsFullHeightLayout && window.styleMask.contains(.fullSizeContentView))
    }
}
