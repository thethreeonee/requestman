import AppKit
import Foundation
import Observation
import RequestmanCore
import SwiftUI
import Darwin

@MainActor @Observable
final class WorkspaceModel {
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
    var search = ""
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
            let collector = CaptureBodyCollector(headers: [HTTPField("Content-Type", "application/json")])
            collector.append(Array("{\"items\":[1,2,3]}".utf8))
            record.requestBody = collector.snapshot(isComplete: true)
            record.sentBody = record.requestBody
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
