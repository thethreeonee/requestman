import AppKit
import Foundation
import Observation
import RequestmanCore
import SwiftUI

/// Capture menu results without touching the user's pasteboard.
@MainActor
enum RequestClipboard {
    static var copied: String?
    static func copy(_ value: String) { copied = value }
}

/// Only model and unrelated SwiftUI content are fixtures. The split controller, toolbar,
/// transitions and snapshot adapter are compiled directly from the production source.
@MainActor @Observable
final class WorkspaceModel {
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
}

@MainActor @Observable
final class SidebarHistoryFixture {
    var records: [CaptureRecord] = []
    var selectedID: UUID?
    var search = ""
    var selected: CaptureRecord? { records.first { $0.id == selectedID } }
    func clear() { records.removeAll(); selectedID = nil }
}

struct WorkspaceSidebarContent: View {
    let model: WorkspaceModel
    var body: some View { Text("Sidebar fixture").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
struct WorkspaceMainContent: View {
    let model: WorkspaceModel
    var body: some View { Text(model.selection.title).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
struct RequestInspectorView: View {
    let history: SidebarHistoryFixture
    let isPresented: Bool
    var body: some View {
        Group {
            if isPresented { BodyRespondersFixture() }
            else { Text("") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct EnvironmentSelectionPopover: View {
    let model: WorkspaceModel
    let onDismiss: () -> Void
    let openSettings: () -> Void
    var body: some View { Text("Environment fixture") }
}

/// Native body controls exercise the actual NSHostingController/NSViewRepresentable responder path.
private struct BodyRespondersFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSStackView {
        let text = NSTextView()
        text.string = "Request body fixture"
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value")))
        let stack = NSStackView(views: [text, table])
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.alignment = .width
        return stack
    }
    func updateNSView(_ view: NSStackView, context: Context) {}
}

/// Matches WorkspaceView's observation boundary; no manual controller updates are made in this path.
private struct WorkspaceHostingFixture: View {
    let model: WorkspaceModel
    var body: some View {
        WorkspaceSplitView(model: model, snapshot: WorkspaceToolbarSnapshot(model: model), openSettings: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
    }
}

@main
@MainActor
struct WorkspaceSidebarChecks {
    private static let inspectorToggleIdentifier = NSToolbarItem.Identifier("workspace.toggleInspector")
    private static let sidebarToggleIdentifier = NSToolbarItem.Identifier("workspace.toggleSidebar")
    private static let inspectorTitleIdentifier = NSToolbarItem.Identifier("workspace.inspectorTitle")
    private static let inspectorMoreIdentifier = NSToolbarItem.Identifier("workspace.inspectorMore")
    private static var widthFailures: [String] = []

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        checkSwiftUIIntegration()
        checkDirectController()
        precondition(widthFailures.isEmpty, widthFailures.joined(separator: "; "))
        print("Workspace sidebar CLI checks passed: native item roles, unique toolbar toggle, title visibility, selection/clear/page changes, fixed window width, safe-area geometry and teardown")
        print("Actual WorkspaceSplitView.swift executed with model/content fixtures in hidden NSWindows; no user App built/launched, window shown, network request or configuration write. Visual appearance remains unverified.")
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
        checkGeometry(controller, window: window, inspector: inspector, windowWidth: windowWidth)
        checkInitialInspectorWidth(inspector, scenario: "first selection after no selection")
        let root = inspector.viewController as! NSHostingController<RequestInspectorView>
        precondition(root.rootView.isPresented, "Visible inspector enables its hosted detail content")
        checkRequestMenu(controller, model: model, window: window)

        // Invoke the native toolbar item; there must be exactly one entry point.
        invoke(toggleItem(window))
        settle(controller) { inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: true)
        precondition(model.history.selectedID == record.id, "Manual collapse preserves the selected request")
        precondition(!root.rootView.isPresented)
        update(controller, model: model)
        precondition(inspector.isCollapsed, "Unrelated updates must not reopen a manually collapsed inspector")
        invoke(toggleItem(window))
        settle(controller) { !inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: true, requests: true)
        checkGeometry(controller, window: window, inspector: inspector, windowWidth: windowWidth)

        invoke(toggleItem(window))
        settle(controller) { inspector.isCollapsed }
        model.history.selectedID = nextRecord.id
        update(controller, model: model)
        settle(controller) { !inspector.isCollapsed }
        precondition(root.rootView.history.selectedID == nextRecord.id)

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
        precondition(!root.rootView.isPresented)

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

    private static func checkSwiftUIIntegration() {
        let model = WorkspaceModel()
        let record = CaptureRecord(method: "GET", url: "https://example.test/initial")
        let other = CaptureRecord(method: "POST", url: "https://example.test/changed")
        model.selection = .requests
        model.history.records = [record, other]
        model.history.selectedID = record.id
        let host = NSHostingController(rootView: WorkspaceHostingFixture(model: model))
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
        // must install the toolbar through the real representable update, without calling it here.
        model.history.search = "fixture"
        waitFor(host) { window.toolbar != nil }
        precondition(!inspector.isCollapsed, "Initial selected request must open the inspector through the representable")
        precondition((inspector.viewController as! NSHostingController<RequestInspectorView>).rootView.isPresented)
        expectToolbar(window, inspectorVisible: true, requests: true)
        let originalWidth = window.frame.width
        checkGeometry(controller, window: window, inspector: inspector, windowWidth: originalWidth)
        checkInitialInspectorWidth(inspector, scenario: "initial snapshot already has a selection")
        checkCaptureButton(host, model: model, window: window)

        // With no focused control, the actual native toolbar item's explicit target must still work.
        precondition(window.makeFirstResponder(nil))
        precondition(window.firstResponder === window)
        let item = toggleItem(window)
        precondition(item.target === controller && item.view == nil)
        invoke(item)
        waitFor(host) { inspector.isCollapsed }

        // Observation must update native state without calling controller.update or replacing rootView.
        model.history.selectedID = other.id
        waitFor(host) { !inspector.isCollapsed }
        expectToolbar(window, inspectorVisible: true, requests: true)
        checkHostedBodyAction(host, window: window, inspector: inspector, type: NSTextView.self)
        model.history.selectedID = record.id
        waitFor(host) { !inspector.isCollapsed }
        checkHostedBodyAction(host, window: window, inspector: inspector, type: NSTableView.self)
        model.history.selectedID = other.id
        waitFor(host) { !inspector.isCollapsed }
        checkTitleGeometry(window, inspector: inspector)
        model.history.clear()
        waitFor(host) { inspector.isCollapsed && !toggleItem(window).isEnabled }
        expectToolbar(window, inspectorVisible: false, requests: true)
        model.selection = .rules
        waitFor(host) { !controller.splitViewItems[0].isCollapsed }
        expectToolbar(window, inspectorVisible: false, requests: false)
        precondition(!window.isVisible, "The CLI check must never show a window")
        controller.tearDown()
        log("SwiftUI integration actions passed: Observation-driven selection/clear/page updates and native toolbar actions with empty/text/table focus.")
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
        precondition(button.toolTip == model.captureButtonHelp)

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
        // NSViewControllerRepresentable has no NSHostingController child on this SDK. Its actual
        // NSSplitView's public delegate still gives access to the production controller.
        return findView(NSSplitView.self, in: controller.view)?.delegate as? WorkspaceSplitController
    }

    private static func findView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { findView(type, in: $0) }.first
    }

    private static func waitFor(_ host: NSViewController, file: StaticString = #fileID, line: UInt = #line,
                                until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            host.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        } while !condition() && Date() < deadline
        precondition(condition(), "SwiftUI/AppKit integration did not reach the expected state", file: file, line: line)
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

    private static func settle(_ controller: WorkspaceSplitController, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        } while !condition() && Date() < deadline
        precondition(condition(), "AppKit did not reach the expected split-item state")
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
        precondition(items.filter { $0.itemIdentifier == inspectorToggleIdentifier }.count == (requests ? 1 : 0))
        precondition(items.filter { $0.itemIdentifier == sidebarToggleIdentifier }.count == (requests ? 0 : 1))
        precondition(!items.contains { $0.itemIdentifier == .toggleInspector || $0.itemIdentifier == .toggleSidebar },
                     "AppKit's reserved nil-target toggles must not duplicate the explicit-target native items")
        precondition(items.filter { $0.itemIdentifier == inspectorTitleIdentifier }.count == (inspectorVisible ? 1 : 0))
        precondition(items.filter { $0.itemIdentifier == inspectorMoreIdentifier }.count == (inspectorVisible ? 1 : 0))
        if inspectorVisible {
            let moreIndex = items.firstIndex { $0.itemIdentifier == inspectorMoreIdentifier }!
            precondition(items[moreIndex + 1].itemIdentifier == inspectorToggleIdentifier,
                         "More belongs immediately before the inspector toggle")
        }
        precondition(items.filter { $0.itemIdentifier == .inspectorTrackingSeparator }.count == (requests ? 1 : 0))
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
