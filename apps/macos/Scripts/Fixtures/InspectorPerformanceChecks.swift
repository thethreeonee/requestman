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
    func cancelReplay(_ id: UUID) {}
    var replayUnavailableReason: String? { "测试不发送请求" }
    func replay(_ record: CaptureRecord, editing: Bool, presenter: NSViewController) {}
    func addMockWorkflow(from record: CaptureRecord) { selection = .rules }
}

@MainActor @Observable
final class ExecutionHistoryModel {
    var latestReplay: CaptureRecord? { records.first { $0.replayID != nil } }
    func reveal(_ id: UUID) { selectedID = id }
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
@MainActor final class StepInspectorViewController: ProjectSidebarViewController {
    var isPresented = false
    func installAccessories(on item: NSSplitViewItem) {}
}

@MainActor enum WorkspaceTransfer {
    static func importFile(model: WorkspaceModel, window: NSWindow?, rulesOnly: Bool = false) {}
    static func exportRules(model: WorkspaceModel, window: NSWindow?) {}
}

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
        checkImagePreviews()
        if CommandLine.arguments.contains("--images-only") { return }
        checkJSONColors()
        let model = WorkspaceModel()
        model.selection = .requests
        let workflow = RequestWorkflow(name: "命中规则")
        var project = WorkflowProject(name: "测试规则组")
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
        let link = views(NSPathControl.self, in: details.requests.view).first { $0.accessibilityLabel() == "命中的规则与规则组" }!
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
        // An open SSE record updates the existing Inspector without changing selection.
        let stream = CaptureStreamStore()
        stream.appendSSE(Data("data: first\n\n".utf8)) {}
        let deadline = Date().addingTimeInterval(2)
        while stream.summary.count < 1 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        var live = CaptureRecord(method: "GET", url: "https://example.invalid/events")
        live.captureProtocol = .sse; live.connectionState = .open; live.stream = stream; live.receivedStream = stream
        model.history.records = [live]; model.history.selectedID = live.id
        settle(controller)
        let tabs = views(NSSegmentedControl.self, in: details.requests.view).first { $0.accessibilityLabel() == "请求数据" }!
        tabs.selectedSegment = 4; precondition(NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs))
        settle(controller)
        let messages = views(NSTableView.self, in: details.requests.view).first { $0.accessibilityLabel() == "事件与消息" }!
        precondition(messages.numberOfRows == 1 && tabs.label(forSegment: 4) == "事件流")
        stream.appendSSE(Data("data: second\n\n".utf8)) {}
        let secondDeadline = Date().addingTimeInterval(2)
        while stream.summary.count < 2 && Date() < secondDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        live.revision += 1; model.history.records = [live]
        settle(controller)
        precondition(messages.numberOfRows == 2 && messages.selectedRow == 1)
        precondition(views(NSTextView.self, in: details.requests.view).contains { $0.string == "second" })
        print("Live SSE Inspector passed: stable selection, incremental messages, latest message and copy payload")
        controller.tearDown()
        window.contentViewController = nil
        window.close()
        print("Inspector performance checks passed: actual table/detail views, 6 selection/open/resize/close cycles; bounded idle CPU, stable toolbar images. Hidden CLI window only; App acceptance still required.")
    }

    static func checkImagePreviews() {
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==")!
        func snapshot(_ data: Data, type: String = "image/gif") -> CaptureBodySnapshot {
            let collector = CaptureBodyCollector(headers: [HTTPField("Content-Type", type)])
            collector.append(data)
            return collector.snapshot(isComplete: true)
        }
        var record = CaptureRecord(method: "GET", url: "https://example.invalid/image.gif")
        record.receivedBody = snapshot(gif); record.responseBody = snapshot(gif)
        let pane = RequestPayloadViewController(record: record, tab: .responseBody, version: .final)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = pane
        pane.update(version: .final, isActive: true)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                pane.view.layoutSubtreeIfNeeded()
            }
            precondition(condition(), "Image presentation did not settle")
        }
        let checkbox = views(NSButton.self, in: pane.view).first { $0.title == "显示原始数据" }!
        let preview = views(NSImageView.self, in: pane.view).first { $0.accessibilityLabel() == "响应图片预览" }!
        let source = views(NSTextView.self, in: pane.view).first!
        wait { pane.copyContent != nil && !preview.isHiddenOrHasHiddenAncestor }
        precondition(preview.image?.isValid == true && preview.imageScaling == .scaleProportionallyDown)
        precondition(checkbox.state == .off && source.isHiddenOrHasHiddenAncestor)
        precondition(!views(NSSearchField.self, in: pane.view).first!.isEnabled)
        let copy = pane.copyContent
        for width: CGFloat in [400, 520, 760] {
            window.setContentSize(NSSize(width: width, height: 500))
            pane.view.layoutSubtreeIfNeeded()
            let summary = views(NSTextField.self, in: pane.view).first { $0.stringValue.hasPrefix("image/gif ·") }!
            let infoFrame = summary.convert(summary.alignmentRect(forFrame: summary.bounds), to: pane.view)
            let checkFrame = checkbox.convert(checkbox.alignmentRect(forFrame: checkbox.bounds), to: pane.view)
            precondition(checkFrame.minY >= infoFrame.maxY, "Checkbox must sit below Content-Type")
            precondition(checkFrame.minY - infoFrame.maxY < 20, "Checkbox must be directly below Content-Type")
            precondition(abs(checkFrame.maxX - infoFrame.maxX) <= 1, "Checkbox must align to the right of Content-Type: summary=\(infoFrame), checkbox=\(checkFrame)")
            precondition(checkFrame.width >= checkbox.intrinsicContentSize.width - 1)
        }
        checkbox.performClick(nil)
        precondition(preview.isHiddenOrHasHiddenAncestor && !source.isHiddenOrHasHiddenAncestor)
        precondition(source.string.contains("47 49 46") && pane.copyContent == copy)
        pane.update(version: .final, isActive: false)
        pane.update(version: .final, isActive: true)
        precondition(checkbox.state == .on && !source.isHiddenOrHasHiddenAncestor)
        checkbox.performClick(nil)
        precondition(!preview.isHiddenOrHasHiddenAncestor && source.isHiddenOrHasHiddenAncestor)
        record.receivedBody = snapshot(Data(#"{"error":"not an image"}"#.utf8))
        pane.update(record: record, version: .original, isActive: true)
        wait { pane.copyContent?.version == .original }
        precondition(preview.isHiddenOrHasHiddenAncestor && checkbox.isHiddenOrHasHiddenAncestor)
        precondition(!source.isHiddenOrHasHiddenAncestor && source.string == #"{"error":"not an image"}"#)
        precondition(views(NSTextField.self, in: pane.view).contains { $0.stringValue.contains("无法预览此图片") })
        pane.update(version: .final, isActive: true)
        wait { pane.copyContent?.version == .final }
        precondition(!preview.isHiddenOrHasHiddenAncestor && source.isHiddenOrHasHiddenAncestor)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        record.receivedBody = snapshot(png, type: "image/png")
        pane.update(record: record, version: .difference, isActive: true)
        wait { pane.copyContent?.version == .difference }
        let before = views(NSImageView.self, in: pane.view).first { $0.accessibilityLabel() == "修改前图片预览" }!
        let after = views(NSImageView.self, in: pane.view).first { $0.accessibilityLabel() == "修改后图片预览" }!
        precondition(before.image?.size == NSSize(width: 12, height: 8) && after.image?.size == NSSize(width: 1, height: 1))
        precondition(preview.isHiddenOrHasHiddenAncestor && source.isHiddenOrHasHiddenAncestor)
        for width: CGFloat in [400, 520, 760] {
            window.setContentSize(NSSize(width: width, height: 500))
            pane.view.layoutSubtreeIfNeeded()
            let left = before.convert(before.bounds, to: pane.view)
            let right = after.convert(after.bounds, to: pane.view)
            precondition(!before.isHiddenOrHasHiddenAncestor && !after.isHiddenOrHasHiddenAncestor)
            precondition(left.maxX < right.minX && abs(left.width - right.width) <= 1)
            precondition(abs(left.minY - right.minY) <= 1 && left.height > 100)
            precondition(left.minX >= 16 && right.maxX <= width - 16)
        }
        checkbox.performClick(nil)
        precondition(before.isHiddenOrHasHiddenAncestor && after.isHiddenOrHasHiddenAncestor)
        precondition(!source.isHiddenOrHasHiddenAncestor && source.string.contains("89 50 4e 47") && source.string.contains("47 49 46"))
        checkbox.performClick(nil)
        pane.update(version: .original, isActive: true)
        wait { pane.copyContent?.version == .original }
        precondition(preview.image?.size == NSSize(width: 12, height: 8) && !preview.isHiddenOrHasHiddenAncestor)
        precondition(before.isHiddenOrHasHiddenAncestor && after.isHiddenOrHasHiddenAncestor)
        record.receivedBody = .unavailable("没有服务器原始响应")
        pane.update(record: record, version: .difference, isActive: true)
        wait { pane.copyContent?.version == .difference }
        precondition(before.isHiddenOrHasHiddenAncestor && !after.isHiddenOrHasHiddenAncestor)
        precondition(views(NSTextField.self, in: pane.view).contains { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == "没有服务器原始响应" })
        print("Image preview checks passed: GIF/PNG, equal before/after columns at 400/520/760 pt, checkbox/raw data, copy, versions, tab retention and unavailable-image fallback. Hidden window only.")
    }

    static func checkDisplayMode(_ controller: WorkspaceSplitController, window: NSWindow) {
        let inspector = controller.splitViewItems[2].viewController.view
        let more = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "workspace.inspectorMore" } as! NSMenuToolbarItem
        func selectMode(_ index: Int) {
            more.menu.delegate?.menuNeedsUpdate?(more.menu)
            let item = more.menu.items.last!.submenu!.items[index]
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        more.menu.delegate?.menuNeedsUpdate?(more.menu)
        precondition(more.menu.items.last!.submenu!.items[2].state == .on)
        selectMode(1)
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
        func copyItem() -> NSMenuItem {
            more.menu.delegate?.menuNeedsUpdate?(more.menu)
            let submenu = more.menu.items.first { $0.title == "复制" }!.submenu!
            precondition(submenu.items.count == 4)
            return submenu.items[1]
        }
        precondition(!views(NSButton.self, in: inspector).contains { $0.action == NSSelectorFromString("copyContent:") })
        precondition(views(NSButton.self, in: inspector).contains { $0.action == NSSelectorFromString("copyURL") && $0.isEnabled })

        waitFor(controller) { headerValue() == "after-0" }
        waitFor(controller) { copyItem().isEnabled == true }
        precondition(copyItem().title == "复制请求头")
        let initialWidth = inspector.bounds.width
        for width: CGFloat in [400, 520, 760] {
            controller.splitView.setPosition(controller.splitView.bounds.maxX - width - controller.splitView.dividerThickness, ofDividerAt: 1)
            settle(controller)
            precondition(abs(inspector.bounds.width - width) <= 2, "Data tabs must preserve the 400 pt inspector minimum")
            let tabFrame = tabs.convert(tabs.bounds, to: inspector)
            let tabTop = inspector.isFlipped ? tabFrame.minY : inspector.bounds.height - tabFrame.maxY
            print("Content tabs geometry: inspector=\(inspector.bounds), tabRow=\(tabs.superview!.bounds), top=\(tabTop), tabs=\(tabFrame)")
            // The summary includes a 32 pt URL button instead of the old 21 pt intrinsic height.
            precondition(tabTop < 200, "Content tabs must stay directly below the summary, not float mid-inspector: top=\(tabTop), tabs=\(tabFrame), inspector=\(inspector.bounds)")
            precondition(abs(tabFrame.height - tabs.intrinsicContentSize.height) <= 1,
                         "Tabs must retain their native height")
            precondition(tabs.segmentDistribution == .fillProportionally)
            precondition(abs(tabFrame.minX - 16) <= 1 && abs(tabFrame.maxX - (inspector.bounds.width - 16)) <= 1,
                         "Content tabs must fill the row between the inspector insets")
            precondition(tabFrame.width + 1 >= tabs.intrinsicContentSize.width)
            if #available(macOS 26.0, *) {
                precondition(tabs.controlSize == .extraLarge && tabFrame.height >= tabs.intrinsicContentSize.height,
                             "Native size=\(tabs.controlSize.rawValue), frame=\(tabFrame), intrinsic=\(tabs.intrinsicContentSize)")
            }
        }
        controller.splitView.setPosition(controller.splitView.bounds.maxX - initialWidth - controller.splitView.dividerThickness, ofDividerAt: 1)
        settle(controller)
        select(tabs, 1)
        waitFor(controller) { headerValue() == "after" && copyItem().isEnabled == true }
        precondition(copyItem().title == "复制查询参数")
        selectMode(0)
        waitFor(controller) { headerValue() == "before" }
        selectMode(2)
        waitFor(controller) { headerValue() == "最终  after" }
        select(tabs, 0)
        selectMode(0)
        waitFor(controller) { headerValue() == originalHeader }
        select(tabs, 2)
        waitFor(controller) {
            views(NSButton.self, in: inspector).contains { !$0.isHiddenOrHasHiddenAncestor && $0.title == "原始数据" && $0.isEnabled }
        }
        let format = views(NSButton.self, in: inspector).first { !$0.isHiddenOrHasHiddenAncestor && $0.title == "原始数据" }!
        format.performClick(nil)
        waitFor(controller) { sourceValue() == "{\"items\":[1,2,3]}" }
        waitFor(controller) { copyItem().isEnabled == true }
        precondition(copyItem().title == "复制请求体")
        selectMode(1)
        waitFor(controller) { sourceValue() == "{\"items\":[4,5]}" }
        select(tabs, 0)
        waitFor(controller) { headerValue() == "after-0" }
        selectMode(2)
        waitFor(controller) { headerValue() == "最终  after-0" }
        select(tabs, 2)
        waitFor(controller) {
            guard let source = sourceValue() else { return false }
            return source.contains("[1,2,3]") && source.contains("[4,5]")
        }
        selectMode(1)
        select(tabs, 0)
        waitFor(controller) { headerValue() == "after-0" }
        precondition(!views(NSButton.self, in: inspector).contains { ["修改前", "修改后", "修改对比"].contains($0.title) },
                     "The inspector footer must not retain a duplicate display-mode button")
        select(tabs, 4)
        waitFor(controller) { copyItem().isEnabled == false }
        precondition(copyItem().title == "复制响应体")
        select(tabs, 0)
        waitFor(controller) { headerValue() == "after-0" && copyItem().isEnabled == true }
        print("Display-mode integration passed: toolbar actions update real Header/source data across content tabs; source format survives tab changes; no footer mode button")
        print("Data tabs/copy layout passed at 400/520/760 pt: native full-size proportionally filled tabs, copy submenu, active-tab labels and unavailable-data disabling; pasteboard untouched")
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
