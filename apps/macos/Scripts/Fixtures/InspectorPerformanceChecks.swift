import AppKit
import Foundation
import Observation
import RequestmanCore
import SwiftUI
import Darwin

@MainActor @Observable
final class WorkspaceModel {
    var selectedStepID: UUID?
    var selectedStep: ModificationStep?
    var selection: WorkspaceSection = .rules
    var document = WorkspaceDocument()
    let history = ExecutionHistoryModel()
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
final class ExecutionHistoryModel {
    var records: [CaptureRecord] = []
    var selectedID: UUID?
    var filter = CaptureRecordFilter()
    var selected: CaptureRecord? { records.first { $0.id == selectedID } }
    func clear() { records.removeAll(); selectedID = nil }
}


struct WorkspaceSidebarContent: View {
    let model: WorkspaceModel
    var body: some View { Text("Sidebar").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
struct WorkspaceMainContent: View {
    let model: WorkspaceModel
    var body: some View {
        RequestRecordsTable(records: model.history.records, selectedID: Binding(
            get: { model.history.selectedID }, set: { model.history.selectedID = $0 }))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct EnvironmentSelectionPopover: View {
    let model: WorkspaceModel
    let onDismiss: () -> Void
    let openSettings: () -> Void
    var body: some View { Text("Environment") }
}

@main @MainActor
struct InspectorPerformanceChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = WorkspaceModel()
        model.selection = .requests
        for index in 0..<75 {
            var record = CaptureRecord(method: "POST", url: "https://example.invalid/api/\(index)")
            record.status = 200
            record.requestHeaders = (0..<18).map { HTTPField("X-Field-\($0)", String(repeating: "value", count: 40)) }
            record.sentHeaders = record.requestHeaders
            record.sentHeaders[0] = HTTPField("X-Field-0", "after-\(index)")
            let collector = CaptureBodyCollector(headers: [HTTPField("Content-Type", "application/json")])
            collector.append(Array("{\"items\":[1,2,3]}".utf8))
            record.requestBody = collector.snapshot(isComplete: true)
            let sentCollector = CaptureBodyCollector(headers: [HTTPField("Content-Type", "application/json")])
            sentCollector.append(Array("{\"items\":[4,5]}".utf8))
            record.sentBody = sentCollector.snapshot(isComplete: true)
            model.history.records.append(record)
        }
        let controller = WorkspaceSplitController(model: model, snapshot: .init(model: model), openSettings: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1440, height: 900))
        controller.viewDidAppear()
        let inspector = controller.splitViewItems[2]
        for index in 0..<6 {
            model.history.selectedID = model.history.records[index].id
            controller.update(snapshot: .init(model: model), openSettings: {})
            settle(controller)
            precondition(!inspector.isCollapsed)
            if index == 0 { checkDisplayMode(controller, window: window) }
            let width = index.isMultiple(of: 2) ? 1440 : 1100
            window.setContentSize(NSSize(width: width, height: 900))
            settle(controller)
            // Identical snapshots must not recreate images or invalidate toolbar sizing.
            let button = window.toolbar!.items.compactMap { $0.view as? NSButton }
                .first { $0.action == NSSelectorFromString("toggleCapture:") }!
            let image = button.image
            for _ in 0..<30 { controller.update(snapshot: .init(model: model), openSettings: {}) }
            precondition(button.image === image, "Unchanged snapshots recreated toolbar images")
            assertIdle(controller, label: "open-\(index)")
            controller.toggleInspector(nil)
            settle(controller)
            precondition(inspector.isCollapsed)
            assertIdle(controller, label: "closed-\(index)")
        }
        controller.tearDown()
        window.contentViewController = nil
        window.close()
        print("Inspector performance checks passed: actual table/detail views, 6 selection/open/resize/close cycles; bounded idle CPU, stable toolbar images. Hidden CLI window only; App acceptance still required.")
    }

    static func checkDisplayMode(_ controller: WorkspaceSplitController, window: NSWindow) {
        let inspector = controller.splitViewItems[2].viewController.view
        let mode = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "workspace.inspectorMode" }!.view as! NSSegmentedControl
        let tabs = views(NSSegmentedControl.self, in: inspector).first { $0.segmentCount == 4 }!
        let originalHeader = String(repeating: "value", count: 40)

        func select(_ control: NSSegmentedControl, _ index: Int) {
            control.selectedSegment = index
            precondition(control.sendAction(control.action, to: control.target))
        }
        func headerValue() -> String? {
            guard let outline = views(NSOutlineView.self, in: inspector).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
                  outline.numberOfRows > 0 else { return nil }
            return (outline.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
        func sourceValue() -> String? {
            views(NSTextView.self, in: inspector).first { !$0.isHiddenOrHasHiddenAncestor && !$0.isEditable }?.string
        }
        func copyButton() -> NSButton? {
            let buttons = views(NSButton.self, in: inspector).filter { $0.action == NSSelectorFromString("copyContent:") }
            precondition(buttons.count == 1, "There must be one content-copy action, outside the retained payload panes")
            return buttons.first
        }

        waitFor(controller) { headerValue() == "after-0" }
        waitFor(controller) { copyButton()?.isEnabled == true }
        precondition(copyButton()?.accessibilityLabel() == "复制当前请求头")
        let initialWidth = inspector.bounds.width
        for width: CGFloat in [400, 520, 760] {
            controller.splitView.setPosition(controller.splitView.bounds.maxX - width - controller.splitView.dividerThickness, ofDividerAt: 1)
            settle(controller)
            let tabFrame = tabs.convert(tabs.bounds, to: inspector)
            let button = copyButton()!
            let buttonFrame = button.convert(button.bounds, to: inspector)
            let tabTop = inspector.isFlipped ? tabFrame.minY : inspector.bounds.height - tabFrame.maxY
            print("Content tabs geometry: top=\(tabTop), tabs=\(tabFrame), copy=\(buttonFrame), intrinsic=\(button.intrinsicContentSize)")
            precondition(tabTop < 180, "Content tabs must stay directly below the summary, not float mid-inspector")
            precondition(abs(tabFrame.height - tabs.intrinsicContentSize.height) <= 1,
                         "Tabs must retain their native height")
            precondition(abs(buttonFrame.height - button.intrinsicContentSize.height) <= 1,
                         "Copy button must not stretch the entire tab row vertically")
            precondition(tabs.segmentDistribution == .fillEqually)
            precondition(tabFrame.minX >= 0 && buttonFrame.maxX <= inspector.bounds.width)
            precondition(buttonFrame.minX > tabFrame.maxX && abs(buttonFrame.midY - tabFrame.midY) <= 1,
                         "The copy action must remain immediately to the right of the data tabs, in the same row")
            precondition(tabFrame.width + 1 >= tabs.intrinsicContentSize.width)
            if #available(macOS 26.0, *) {
                precondition(tabs.controlSize == .extraLarge && tabFrame.height >= tabs.intrinsicContentSize.height,
                             "Native size=\(tabs.controlSize.rawValue), frame=\(tabFrame), intrinsic=\(tabs.intrinsicContentSize)")
            }
        }
        controller.splitView.setPosition(controller.splitView.bounds.maxX - initialWidth - controller.splitView.dividerThickness, ofDividerAt: 1)
        settle(controller)
        select(mode, 0)
        waitFor(controller) { headerValue() == originalHeader }
        select(tabs, 1)
        waitFor(controller) {
            views(NSButton.self, in: inspector).contains { !$0.isHiddenOrHasHiddenAncestor && $0.title == "原始数据" && $0.isEnabled }
        }
        let format = views(NSButton.self, in: inspector).first { !$0.isHiddenOrHasHiddenAncestor && $0.title == "原始数据" }!
        format.performClick(nil)
        waitFor(controller) { sourceValue() == "{\"items\":[1,2,3]}" }
        waitFor(controller) { copyButton()?.isEnabled == true }
        precondition(copyButton()?.accessibilityLabel() == "复制当前请求体")
        select(mode, 1)
        waitFor(controller) { sourceValue() == "{\"items\":[4,5]}" }
        select(tabs, 0)
        waitFor(controller) { headerValue() == "after-0" }
        select(mode, 2)
        waitFor(controller) { headerValue() == "最终  after-0" }
        select(tabs, 1)
        waitFor(controller) {
            guard let source = sourceValue() else { return false }
            return source.contains("[1,2,3]") && source.contains("[4,5]")
        }
        select(mode, 1)
        select(tabs, 0)
        waitFor(controller) { headerValue() == "after-0" }
        precondition(!views(NSButton.self, in: inspector).contains { ["修改前", "修改后", "修改对比"].contains($0.title) },
                     "The inspector footer must not retain a duplicate display-mode button")
        select(tabs, 3)
        waitFor(controller) { copyButton()?.isEnabled == false }
        precondition(copyButton()?.accessibilityLabel() == "复制当前响应体")
        select(tabs, 0)
        waitFor(controller) { headerValue() == "after-0" && copyButton()?.isEnabled == true }
        print("Display-mode integration passed: toolbar actions update real Header/source data across content tabs; source format survives tab changes; no footer mode button")
        print("Data tabs/copy layout passed at 400/520/760 pt: native full-size evenly filled tabs, one trailing copy action, active-tab labels and unavailable-data disabling; pasteboard untouched")
    }

    static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { views(type, in: $0) }
    }

    static func waitFor(_ controller: WorkspaceSplitController, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            controller.view.layoutSubtreeIfNeeded()
        }
        precondition(condition(), "Displayed payload did not follow the native mode/tab action")
    }

    static func settle(_ controller: WorkspaceSplitController) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        controller.view.layoutSubtreeIfNeeded()
    }

    static func assertIdle(_ controller: WorkspaceSplitController, label: String) {
        let before = clock()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let cpu = Double(clock() - before) / Double(CLOCKS_PER_SEC)
        print("Inspector \(label): process CPU \(String(format: "%.3f", cpu)) s / 0.6 s idle")
        precondition(cpu < 0.3, "Idle inspector consumed over half a CPU core")
    }
}

struct StepInspectorView: View {
    let model: WorkspaceModel
    var isPresented = true
    var body: some View { Text("Step fixture") }
}
