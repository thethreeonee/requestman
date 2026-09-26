import AppKit
import Foundation
import Observation
import RequestmanCore
import Darwin

@MainActor @Observable
final class WorkspaceModel {
    var settingsSection: WorkspaceSettingsSection = .general
    var selectedWorkflowID: UUID?
    var editingResponse = false
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
    func setRecordingPaused(_ value: Bool) { history.paused = value }
    func clearHistory() { history.clear() }
    func addWorkflow(matchingURL url: String) { selection = .rules }
}

@MainActor @Observable
final class ExecutionHistoryModel {
    var records: [CaptureRecord] = []
    var paused = false
    var dropped = 0
    var filtered: [CaptureRecord] { records.filter { filter.matches($0) } }
    var selectedID: UUID?
    var filter = CaptureRecordFilter()
    var selected: CaptureRecord? { records.first { $0.id == selectedID } }
    func clear() { records.removeAll(); selectedID = nil }
}


enum WorkspaceSettingsSection { case general, environments }
@MainActor class ProjectSidebarViewController: NSViewController {
    let outline = NSOutlineView()
    let searchField = NSSearchField()
    func canPerform(_ command: WorkspaceCommand) -> Bool { false }
    func perform(_ command: WorkspaceCommand) { preconditionFailure("Unexpected rules command in inspector check") }
    func createProject() { preconditionFailure("Unexpected project creation") }
    func addRequest() { preconditionFailure("Unexpected request creation") }
    func focusName() { preconditionFailure("Unexpected rules focus") }
    init(model: WorkspaceModel) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
}
@MainActor final class RulesViewController: ProjectSidebarViewController {}
@MainActor final class StepInspectorViewController: ProjectSidebarViewController { var isPresented = false }

@main @MainActor
struct InspectorPerformanceChecks {
    static func checkJSONColors() {
        let json = #"{"name":"value","count":42,"enabled":true,"nothing":null}"#
        let cases: [(String, String, RequestDataValueKind, JSONSyntax.Role)] = [
            ("name", "\"value\"", .string, .string), ("count", "42", .number, .number),
            ("enabled", "true", .boolean, .boolean), ("nothing", "null", .null, .null)
        ]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let source = RequestSourceView()
        window.contentView = source
        let text = views(NSTextView.self, in: source).first!
        source.update(text: json, search: "", stateKey: "request", isVisible: true, isJSON: true)
        func tint(at range: NSRange) -> NSColor? {
            text.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
        }
        for (key, value, _, role) in cases {
            precondition(tint(at: (json as NSString).range(of: "\"" + key + "\"")) == JSONSyntax.color(.key))
            precondition(tint(at: (json as NSString).range(of: value)) == JSONSyntax.color(role))
        }
        let selected = NSRange(location: 1, length: 6)
        text.setSelectedRange(selected)
        source.update(text: json, search: "value", stateKey: "request", isVisible: true, isJSON: true)
        let valueRange = (json as NSString).range(of: "value")
        precondition(text.string == json && text.selectedRange() == selected, "Highlighting must preserve source and selection")
        precondition(tint(at: valueRange) == JSONSyntax.color(.string))
        precondition(text.textStorage?.attribute(.backgroundColor, at: valueRange.location, effectiveRange: nil) != nil)
        source.update(text: json, search: "", stateKey: "request", isVisible: true, isJSON: false)
        precondition(tint(at: valueRange) == nil, "A plain-text payload must clear old syntax colors")
        source.update(text: json, search: "", stateKey: "response", isVisible: false, isJSON: true)
        source.update(text: json, search: "", stateKey: "response", isVisible: true, isJSON: true)
        precondition(tint(at: valueRange) == JSONSyntax.color(.string), "Retained source panes must recolor when shown")
        precondition(text.textStorage?.attribute(.backgroundColor, at: valueRange.location, effectiveRange: nil) == nil)

        let outline = RequestDataOutline(); window.contentView = outline
        let nodes = cases.map { key, value, kind, _ in RequestDataNode(id: key, name: key, value: value, copyValue: value, valueKind: kind) }
        outline.update(nodes: nodes, showsTypes: true, isVisible: true)
        window.contentView?.layoutSubtreeIfNeeded()
        let table = views(NSOutlineView.self, in: outline).first!
        for (index, item) in cases.enumerated() {
            let key = table.view(atColumn: 0, row: index, makeIfNecessary: true) as! NSTableCellView
            let value = table.view(atColumn: 1, row: index, makeIfNecessary: true) as! NSTableCellView
            precondition(key.textField?.textColor == JSONSyntax.color(.key))
            precondition(value.textField?.textColor == JSONSyntax.color(item.3), "JSON tree and source must share value colors")
            value.backgroundStyle = .emphasized
            precondition(value.textField?.textColor == .alternateSelectedControlTextColor)
            value.backgroundStyle = .normal
            precondition(value.textField?.textColor == JSONSyntax.color(item.3))
        }
        outline.update(nodes: nodes, showsTypes: false, isVisible: true)
        let headerKey = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
        precondition(headerKey.textField?.textColor == .labelColor, "Header names keep their native text color")
        print("Shared JSON colors passed: source/tree, all value types, search, selection, plain-text reset and retained panes")
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkJSONColors()
        let model = WorkspaceModel()
        model.selection = .requests
        let workflow = RequestWorkflow(name: "命中规则")
        var project = WorkflowProject(name: "测试项目")
        project.workflows = [workflow]
        model.document.projects = [project]
        for index in 0..<75 {
            var record = CaptureRecord(method: "POST", url: "https://example.invalid/api/\(index)?page=before")
            record.finalURL = "https://example.invalid/api/\(index)?page=after"
            record.status = index == 0 ? 302 : 200
            record.matchedWorkflowID = workflow.id
            record.workflow = workflow.name
            record.project = project.name
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
        model.history.selectedID = model.history.records[0].id
        settle(controller)
        let details = inspector.viewController as! WorkspaceInspectorController
        let link = views(NSPathControl.self, in: details.requests.view).first { $0.accessibilityLabel() == "命中的规则与项目" }!
        precondition(link.isEnabled && link.font!.pointSize == 14)
        precondition(link.pathItems.map(\.title) == [project.name, workflow.name] && !link.isEditable)
        let method = views(RequestMethodTag.self, in: details.requests.view).first!
        precondition(method.bounds.width == method.intrinsicContentSize.width && method.bounds.height == 24)
        let status = views(NSTextField.self, in: details.requests.view).first { $0.stringValue == "302" }!
        precondition(status.textColor == NSColor.systemOrange && status.font == RequestStatusStyle.font)
        precondition(link.sendAction(link.action, to: link.target))
        settle(controller)
        precondition(model.selection == .rules && model.selectedWorkflowID == workflow.id && model.selectedStepID == nil)
        model.selection = .requests
        model.document.projects = []
        settle(controller)
        precondition(!link.isEnabled, "Deleted workflows must not navigate to a stale selection")
        print("Summary checks passed: shared method/status styles, direct matched-workflow navigation and deleted-target disabling")
        controller.tearDown()
        window.contentViewController = nil
        window.close()
        print("Inspector performance checks passed: actual table/detail views, 6 selection/open/resize/close cycles; bounded idle CPU, stable toolbar images. Hidden CLI window only; App acceptance still required.")
    }

    static func checkDisplayMode(_ controller: WorkspaceSplitController, window: NSWindow) {
        let inspector = controller.splitViewItems[2].viewController.view
        let mode = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "workspace.inspectorMode" }!.view as! NSSegmentedControl
        let tabs = views(NSSegmentedControl.self, in: inspector).first { $0.segmentCount == 5 }!
        let originalHeader = String(repeating: "value", count: 40)
        precondition((0..<tabs.segmentCount).map { tabs.label(forSegment: $0)! } == ["请求头", "查询参数", "请求体", "响应头", "响应体"])

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
            precondition(abs(inspector.bounds.width - width) <= 2, "Data tabs must preserve the 400 pt inspector minimum")
            let tabFrame = tabs.convert(tabs.bounds, to: inspector)
            let button = copyButton()!
            let buttonFrame = button.convert(button.bounds, to: inspector)
            let tabTop = inspector.isFlipped ? tabFrame.minY : inspector.bounds.height - tabFrame.maxY
            print("Content tabs geometry: inspector=\(inspector.bounds), tabRow=\(tabs.superview!.bounds), top=\(tabTop), tabs=\(tabFrame), copy=\(buttonFrame), intrinsic=\(button.intrinsicContentSize)")
            precondition(tabTop < 180, "Content tabs must stay directly below the summary, not float mid-inspector")
            precondition(abs(tabFrame.height - tabs.intrinsicContentSize.height) <= 1,
                         "Tabs must retain their native height")
            precondition(abs(buttonFrame.height - button.intrinsicContentSize.height) <= 1,
                         "Copy button must not stretch the entire tab row vertically")
            precondition(tabs.segmentDistribution == .fillProportionally)
            precondition(tabFrame.minX >= 0 && buttonFrame.maxX <= inspector.bounds.width)
            precondition(abs(buttonFrame.maxX - (inspector.bounds.width - 16)) <= 1,
                         "Content tabs must expand across the inspector, keeping the copy action at the trailing inset")
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
        select(tabs, 1)
        waitFor(controller) { headerValue() == "after" && copyButton()?.isEnabled == true }
        precondition(copyButton()?.accessibilityLabel() == "复制当前查询参数")
        select(mode, 0)
        waitFor(controller) { headerValue() == "before" }
        select(mode, 2)
        waitFor(controller) { headerValue() == "最终  after" }
        select(tabs, 0)
        select(mode, 0)
        waitFor(controller) { headerValue() == originalHeader }
        select(tabs, 2)
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
        select(tabs, 2)
        waitFor(controller) {
            guard let source = sourceValue() else { return false }
            return source.contains("[1,2,3]") && source.contains("[4,5]")
        }
        select(mode, 1)
        select(tabs, 0)
        waitFor(controller) { headerValue() == "after-0" }
        precondition(!views(NSButton.self, in: inspector).contains { ["修改前", "修改后", "修改对比"].contains($0.title) },
                     "The inspector footer must not retain a duplicate display-mode button")
        select(tabs, 4)
        waitFor(controller) { copyButton()?.isEnabled == false }
        precondition(copyButton()?.accessibilityLabel() == "复制当前响应体")
        select(tabs, 0)
        waitFor(controller) { headerValue() == "after-0" && copyButton()?.isEnabled == true }
        print("Display-mode integration passed: toolbar actions update real Header/source data across content tabs; source format survives tab changes; no footer mode button")
        print("Data tabs/copy layout passed at 400/520/760 pt: native full-size proportionally filled tabs, one trailing copy action, active-tab labels and unavailable-data disabling; pasteboard untouched")
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
