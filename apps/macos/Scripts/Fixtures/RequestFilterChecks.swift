import AppKit
import Observation
import RequestmanCore

@MainActor @Observable
private final class FilterFixture {
    var filter = CaptureRecordFilter()
    var selectedID: UUID?
    var paused = false
    var workflowNames: [UUID: String] = [:]
    var records: [CaptureRecord] = (0..<8).map { index in
        let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT"]
        let statuses: [Int?] = [101, 200, 302, 404, 500, nil, 204, 200]
        var record = CaptureRecord(method: methods[index], url: "https://example.test/very/long/path/\(index)")
        record.project = "商城规则组"; record.environment = "dev"; record.status = statuses[index]
        record.duration = index == 4 ? 3.2 : 0.128
        if index == 7 { record.outcome = .failed; record.error = "响应传输中断" }
        record.requestHeaders = [HTTPField("Content-Type", "application/json")]
        record.requestBody = CaptureBodyCollector().snapshot(isComplete: true)
        let response = CaptureBodyCollector()
        response.append(Data("response-\(index)".utf8))
        record.responseBody = response.snapshot(isComplete: true)
        record.matchedRules = [.init(kind: .setHeader, name: "添加调试标记", response: false),
                               .init(kind: .replaceBody, name: "订单数据", response: true),
                               .init(kind: .setStatus, name: "模拟状态", response: true)]
        if index.isMultiple(of: 2) { record.matchedRules = Array(record.matchedRules.prefix(1)) }
        return record
    }
}

@MainActor
private final class FilterFixtureView: ObservedViewController {
    let model: FilterFixture
    let controls = RequestFilterControls()
    let table: RequestRecordsTable
    init(model: FilterFixture, defaults: UserDefaults) {
        self.model = model; table = RequestRecordsTable(columnDefaults: defaults); super.init()
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = FlippedView()
        controls.onFilterChange = { [weak model] in model?.filter = $0 }
        controls.toggleRecording = { [weak model] in model?.paused.toggle() }
        controls.clear = { [weak model] in model?.records.removeAll() }
        table.onSelectionChange = { [weak model] in model?.selectedID = $0 }
        let stack = NativeUI.stack([controls, table], spacing: 0)
        NativeUI.pin(stack, to: view)
        for child in [controls, table] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        table.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    override func refresh() {
        controls.update(filter: model.filter, records: model.records, paused: model.paused)
        table.update(records: model.records.filter { model.filter.matches($0) }, selectedID: model.selectedID,
                     workflowNames: model.workflowNames)
    }
}

@main @MainActor
private enum RequestFilterChecks {
    private static func checkRuleRename(model: FilterFixture, host: FilterFixtureView) {
        let originalRecords = model.records
        let workflowID = UUID()
        model.records[0].matchedWorkflowID = workflowID
        model.records[1].matchedWorkflowID = workflowID
        model.records[2].matchedWorkflowID = workflowID
        model.records[2].matchedRules = []
        model.records[3].matchedWorkflowID = UUID()
        for row in 0...3 { model.records[row].workflow = "添加调试标记" }
        model.records[1].matchedRules.append(.init(kind: .setHeader, name: "添加调试标记", response: true))
        model.records[4].matchedRules = []
        model.workflowNames[workflowID] = "改名前"
        model.selectedID = model.records[1].id
        model.paused = true
        settle(host.view)
        let table = descendants(host.view).compactMap { $0 as? NSTableView }.first!
        let widths = table.tableColumns.map(\.width)
        func cell(_ row: Int) -> NSView { table.view(atColumn: 3, row: row, makeIfNecessary: true)! }
        precondition(cell(0).toolTip!.contains("改名前"))

        // No new records or manual refresh: Observation must update retained rows even while paused.
        model.workflowNames[workflowID] = "改名后"
        settle(host.view)
        for row in [0, 1, 2] {
            let ruleCell = cell(row)
            let expected = "\(model.records[row].project)\n改名后"
            precondition(ruleCell.toolTip == expected && ruleCell.accessibilityValue() as? String == expected,
                         "A matched workflow appears once, independent of successful step count")
            precondition(descendants(ruleCell).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "改名后" })
            precondition(!descendants(ruleCell).contains { $0 is NSButton },
                         "Four executed steps must not produce a +3 rule count")
        }
        precondition(cell(4).toolTip == "商城规则组\n未命中规则", "Unmatched requests must not gain a workflow")
        precondition(cell(3).toolTip!.contains("添加调试标记"), "Resolve by workflow ID, not a shared old name")
        precondition(table.selectedRow == 1 && table.tableColumns.map(\.width) == widths)
        precondition(model.records[0].matchedRules == originalRecords[0].matchedRules,
                     "Display updates must preserve captured snapshots")

        model.workflowNames.removeValue(forKey: workflowID)
        settle(host.view)
        precondition(cell(0).toolTip!.contains("添加调试标记"), "Deleted workflows retain the captured name")
        model.records = originalRecords
        model.selectedID = nil
        model.paused = false
        settle(host.view)
        print("Rule rename checks passed: observed row refresh while paused, multiple steps, ID isolation, selection, widths and deleted-rule fallback")
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkMethodTagRendering()
        let suite = "RequestmanColumnChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = FilterFixture()
        let host = FilterFixtureView(model: model, defaults: defaults)
        let window = makeWindow(host)
        defer { window.close() }
        checkRuleRename(model: model, host: host)
        for width in [1440.0, 820, 600, 569, 567, host.controls.minimumContentWidth, 820] {
            window.setContentSize(NSSize(width: width, height: 620))
            settle(host.view)
            precondition(abs(host.view.bounds.width - width) < 2, "Content must remain at requested width \(width), got \(host.view.bounds.width)")
            let views = descendants(host.view)
            let table = views.compactMap { $0 as? NSTableView }.first!
            precondition(table.tableColumns.map(\.title) == ["时间", "状态码", "请求", "命中的规则", "环境", "耗时"])
            let scroll = table.enclosingScrollView!
            precondition(!scroll.hasHorizontalScroller)
            precondition(abs(table.tableColumns.reduce(0) { $0 + $1.width } - scroll.contentSize.width) < 2)
            precondition(table.numberOfRows == 8)
            checkMethodLabels(table)
            precondition(!views.contains { $0 is NSSearchField }, "Log search must live only in the window toolbar")
            let actions = views.compactMap { $0 as? NSButton }
                .filter { $0.action == NSSelectorFromString("performAction:") }
            precondition(actions.count == 3)
            let segments = views.compactMap { $0 as? NSSegmentedControl }
            precondition(segments.count == 1, "Resource types, SSE and WS share one segmented control")
            let types = segments[0]
            precondition(types.segmentCount == CaptureResourceType.allCases.count && !types.isHidden)
            precondition((0..<types.segmentCount).map { types.label(forSegment: $0)! } == CaptureResourceType.allCases.map(\.rawValue))
            precondition(!descendants(host.controls).contains { $0 is NSPopUpButton }, "All resource types stay inline")
            if #available(macOS 26.0, *) { precondition(types.controlSize == .extraLarge) }
            else { precondition(types.controlSize == .large) }
            let nativeHeight = types.intrinsicContentSize.height
            precondition(types.frame.width > 0 && types.frame.height == nativeHeight)
            precondition(types.bounds.size == types.frame.size, "Native text must never be stretched by a bounds/frame scale")
            precondition(types.frame.width >= types.intrinsicContentSize.width,
                         "All eleven resource labels must fit at \(width) pt: frame=\(types.frame), natural=\(types.intrinsicContentSize), segments=\((0..<types.segmentCount).map { types.width(forSegment: $0) })")
            if #available(macOS 26.0, *) { precondition(types.borderShape == .capsule) }
            let filterButton = actions.first { $0.accessibilityLabel() == "筛选" }!
            precondition(filterButton.title.isEmpty && filterButton.image != nil)
            precondition(types.frame.height == filterButton.frame.height)
            let typesFrame = types.frame
            precondition(host.controls.bounds.contains(typesFrame), "All categories fit at their natural minimum width")
            for index in 0..<types.segmentCount {
                let textWidth = (types.label(forSegment: index)! as NSString).size(withAttributes: [.font: types.font!]).width
                precondition(types.width(forSegment: index) >= ceil(textWidth) + 16,
                             "Every resource segment keeps its full label and 16 pt horizontal padding")
            }
            let preferredWidth = types.intrinsicContentSize.width
            if width < preferredWidth + nativeHeight * 3 + 73 {
                precondition(host.controls.bounds.height == nativeHeight * 2 + 24 && typesFrame.maxY < filterButton.frame.minY,
                             "Narrow layouts move all eleven segments onto their own row: width=\(width), controls=\(host.controls.bounds), frame=\(host.controls.frame), heights=\(host.controls.constraints.filter { $0.firstAttribute == .height }.map { $0.constant }), segments=\(types.frame), filter=\(filterButton.frame)")
            } else {
                precondition(host.controls.bounds.height == nativeHeight + 16 && typesFrame.maxX < filterButton.frame.minX)
                precondition(typesFrame.midY == filterButton.frame.midY)
            }
            let rect = actions[0].convert(actions[0].bounds, to: host.view)
            for button in actions {
                let buttonFrame = button.convert(button.bounds, to: host.view)
                precondition(button.bounds.size == NSSize(width: nativeHeight, height: nativeHeight),
                             "Pause and clear must have identical native control sizes at every viewport width")
                precondition(abs(buttonFrame.midY - rect.midY) < 1)
                if #available(macOS 26.0, *) {
                    precondition(button.bezelStyle == .glass && button.borderShape == .circle)
                }
            }
            for control in views.compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                let controlRect = control.convert(control.bounds, to: host.view)
                if abs(controlRect.midY - rect.midY) < 18 && controlRect.width > 0 {
                    precondition(controlRect.minX >= -1 && controlRect.maxX <= width + 1,
                                 "Filter control clips at \(width): \(type(of: control)) \(controlRect)")
                }
            }
            precondition(!window.isVisible)
            checkResourceSegmentPaint(host.controls, segments: types)
            try! saveSnapshot(host.controls, name: "request-filters-\(Int(width))")
            print("Resource segments at \(Int(width)) pt: frame=\(types.frame), natural=\(types.intrinsicContentSize)")
        }
        let actions = descendants(host.view).compactMap { $0 as? NSButton }
            .filter { $0.action == NSSelectorFromString("performAction:") }
        let pause = actions.first { $0.accessibilityLabel() == "暂停记录" }!
        pause.performClick(nil)
        settle(host.view)
        precondition(model.paused && pause.accessibilityLabel() == "继续记录")
        precondition(pause.bounds.size == pause.frame.size && pause.bounds.width == pause.bounds.height)
        pause.performClick(nil)
        settle(host.view)
        precondition(!model.paused)
        let clear = actions.first { $0.accessibilityLabel() == "清空" }!
        let originalRecords = model.records
        clear.performClick(nil)
        settle(host.view)
        precondition(model.records.isEmpty && !clear.isEnabled)
        precondition(clear.bounds.size == pause.bounds.size)
        model.records = originalRecords
        settle(host.view)
        precondition(clear.isEnabled)
        model.filter.search = "no-match"
        settle(host.view)
        precondition(model.filter.search == "no-match")
        let table = descendants(host.view).compactMap { $0 as? NSTableView }.first!
        precondition(table.numberOfRows == 0)
        model.filter = CaptureRecordFilter()
        settle(host.view)
        precondition(table.numberOfRows == 8)
        let types = descendants(host.controls).compactMap { $0 as? NSSegmentedControl }.first!
        for (index, type) in CaptureResourceType.allCases.enumerated() {
            types.selectedSegment = index
            precondition(NSApp.sendAction(types.action!, to: types.target, from: types))
            settle(host.view)
            precondition(model.filter.resource == type)
        }
        precondition(types.selectedSegment == CaptureResourceType.allCases.firstIndex(of: model.filter.resource))
        model.filter = CaptureRecordFilter()
        settle(host.view)
        window.setContentSize(NSSize(width: 1440, height: 620))
        settle(host.view)
        checkRequestMenu(table, host: host, model: model)
        checkRowPresentation(table)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            settle(host.view)
            try! saveSnapshot(table.enclosingScrollView!, name: appearance == .aqua ? "request-list-light" : "request-list-dark")
        }
        window.appearance = NSAppearance(named: .aqua)
        // Reusing a row after a failure must clear the detail line and restore centering.
        model.records[7].outcome = .forwarded; model.records[7].error = nil
        settle(host.view)
        let reused = table.view(atColumn: 2, row: 7, makeIfNecessary: true)!
        precondition(reused.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.count == 1)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        precondition(model.selectedID == model.records[1].id)

        checkColumnWidths(table, host: host, window: window, model: model, defaults: defaults)

        checkGroupedFilters(host: host, window: window, model: model)
        print("Request filter CLI checks passed: content-sized minimum–1440 pt layout, six columns, status colors and selection restoration, single-line request/reuse, no horizontal scrolling, filter model search/reset, table selection, Header suggestions and editing. Hidden component windows only; no App or visual acceptance.")
    }
    private static func checkResourceSegmentPaint(_ controls: NSView, segments: NSSegmentedControl) {
        guard #available(macOS 26.0, *) else { return }
        let appearance = controls.appearance
        controls.appearance = NSAppearance(named: .aqua)
        controls.wantsLayer = true
        let background = controls.layer?.backgroundColor
        controls.layer?.backgroundColor = NSColor.white.cgColor
        defer { controls.appearance = appearance; controls.layer?.backgroundColor = background }
        controls.displayIfNeeded()
        // Inspect the unified category control without including the action row.
        let rect = segments.convert(segments.bounds, to: controls).intersection(controls.bounds)
        let bitmap = controls.bitmapImageRepForCachingDisplay(in: rect)!
        controls.cacheDisplay(in: rect, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / segments.frame.height
        let x = bitmap.pixelsWide / 2
        let rows = (0..<bitmap.pixelsHigh).filter { y in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent < 0.98 && color.greenComponent < 0.98 && color.blueComponent < 0.98
        }
        guard let first = rows.first, let last = rows.last else { preconditionFailure("Resource bezel did not render") }
        let paintedHeight = CGFloat(last - first + 1) / scale
        precondition(abs(paintedHeight - segments.intrinsicContentSize.height) <= 1,
                     "The native bezel itself must render at button height, not merely its frame: \(paintedHeight) pt")
        print("Resource segment painted height: \(paintedHeight) pt")
    }

    private static func checkGroupedFilters(host: FilterFixtureView, window: NSWindow, model: FilterFixture) {
        model.filter = CaptureRecordFilter()
        settle(host.view)
        let collapsedHeight = host.controls.frame.height
        host.controls.showFilters()
        settle(host.view)
        let emptyFormHeight = host.controls.frame.height - collapsedHeight
        precondition(host.controls.isExpanded && emptyFormHeight > 0 && emptyFormHeight < 150,
                     "An empty form must fit its controls without a 150 pt minimum")
        precondition(host.controls.window === window, "Filter form must be inside the table's window")
        func button(_ title: String) -> NSButton {
            descendants(host.controls).compactMap { $0 as? NSButton }.first { $0.title == title }!
        }
        func popups(_ label: String) -> [NSPopUpButton] {
            descendants(host.controls).compactMap { $0 as? NSPopUpButton }.filter { $0.accessibilityLabel() == label }
        }
        func select(_ popup: NSPopUpButton, _ title: String) {
            popup.selectItem(withTitle: title)
            precondition(NSApp.sendAction(popup.action!, to: popup.target, from: popup))
            settle(host.view)
        }
        func input(_ label: String, _ text: String) -> NSComboBox {
            let control = descendants(host.controls).compactMap { $0 as? NSComboBox }.first { $0.accessibilityLabel() == label && !$0.isHiddenOrHasHiddenAncestor }!
            control.stringValue = text
            control.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: control))
            settle(host.view)
            return control
        }
        button("添加条件").performClick(nil)
        settle(host.view)
        let singleConditionHeight = host.controls.frame.height - collapsedHeight
        precondition(singleConditionHeight > emptyFormHeight + 20, "Adding a condition must grow the form")
        let filterButton = descendants(host.controls).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "筛选" }!
        let liveURL = descendants(host.controls).compactMap { $0 as? NSComboBox }.first { $0.accessibilityLabel() == "URL" }!
        precondition(window.makeFirstResponder(liveURL))
        let liveEditor = window.fieldEditor(false, for: liveURL) as! NSTextView
        precondition((filterButton.accessibilityValue() as? String) == "已展开，无筛选条件")
        liveEditor.insertText("/path", replacementRange: NSRange(location: 0, length: liveEditor.string.utf16.count))
        precondition(model.filter.hasCriteria && (filterButton.accessibilityValue() as? String) == "已展开，1 个筛选条件",
                     "The button must reflect effective input synchronously, before Return or an observation refresh")
        precondition(window.firstResponder === liveEditor && filterButton.bezelColor == nil,
                     "Keep editing focus and the untinted native glass bezel")
        settle(host.view)
        try! saveSnapshot(filterButton, name: "request-filter-button-active")
        checkFilterDiscAlignment(filterButton)
        liveEditor.insertText("", replacementRange: NSRange(location: 0, length: liveEditor.string.utf16.count))
        precondition(!model.filter.hasCriteria && (filterButton.accessibilityValue() as? String) == "已展开，无筛选条件",
                     "Removing the last effective value must clear the indicator before Return")
        try! saveSnapshot(filterButton, name: "request-filter-button-inactive")
        let url = input("URL", "/path, /users -tracking")
        precondition(window.makeFirstResponder(url))
        let editor = window.fieldEditor(false, for: url)
        _ = input("URL", "/path, /users -internal")
        precondition(window.firstResponder === editor, "Typing must preserve the field editor")
        precondition(model.filter.conditionGroup?.conditions.first?.value == "/path, /users -internal")
        button("添加条件组").performClick(nil)
        settle(host.view)
        precondition(model.filter.conditionGroup?.groups.count == 1)
        precondition(host.controls.frame.height - collapsedHeight > singleConditionHeight + 20,
                     "Adding a group must grow the form")
        select(popups("条件组组合")[0], "任一满足（或）")
        select(popups("筛选字段")[1], "域名")
        let domain = input("域名", "example.test, other.test -blocked.test")
        precondition(domain.objectValues.compactMap { $0 as? String }.contains("example.test"))
        precondition(model.filter.activeConditionCount == 2)
        let saved = model.filter
        host.controls.showFilters(); settle(host.view)
        precondition(!host.controls.isExpanded && host.controls.frame.height == collapsedHeight)
        precondition(model.filter == saved)
        host.controls.showFilters(); settle(host.view)
        precondition(model.filter == saved && domain.stringValue.contains("-blocked.test"))
        let original = model.records
        model.records = []; settle(host.view)
        precondition(domain.stringValue.contains("example.test") && model.filter == saved)
        model.records = original; settle(host.view)
        for width: CGFloat in [host.controls.minimumContentWidth, 820, 1440] {
            window.setContentSize(NSSize(width: width, height: 620)); settle(host.view)
            let formInputs = descendants(host.controls).compactMap { $0 as? NSComboBox }.filter { !$0.isHiddenOrHasHiddenAncestor }
            for control in formInputs {
                precondition(control.bounds.width > 80 && control.bounds.height >= 20)
                let clip = control.enclosingScrollView!.contentView
                let frame = control.convert(control.bounds, to: clip)
                precondition(frame.minX >= 0 && frame.maxX <= clip.bounds.width, "No horizontal clipping in nested forms")
            }
            try! saveSnapshot(host.controls, name: "request-filter-form-\(Int(width))")
        }
        window.setContentSize(NSSize(width: 500, height: 440)); settle(host.view)
        precondition(host.controls.frame.height <= 96 + 440 * 0.45 + 1, "Short windows keep space for the table")
        // Add another nested group and enough rows to exercise the bounded scroll area.
        let addGroups = descendants(host.controls).compactMap { $0 as? NSButton }.filter { $0.title == "添加条件组" && !$0.isHiddenOrHasHiddenAncestor }
        addGroups.last!.performClick(nil); settle(host.view)
        precondition(model.filter.conditionGroup?.groups[0].groups.count == 1)
        for _ in 0..<5 { button("添加条件").performClick(nil); settle(host.view) }
        let fields = popups("筛选字段")
        precondition(fields.count == 8)
        let lastField = fields.last!
        lastField.scrollToVisible(lastField.bounds); settle(host.view)
        let viewport = lastField.enclosingScrollView!.contentView
        precondition(viewport.bounds.contains(lastField.convert(lastField.bounds, to: viewport)), "Last nested condition must remain reachable")
        try! saveSnapshot(host.controls, name: "request-filter-form-scrolled")
        // Restore the two-condition form before checking Header editing.
        model.filter = saved; settle(host.view)
        window.setContentSize(NSSize(width: 820, height: 620)); settle(host.view)
        select(popups("筛选字段")[1], "请求 Header")
        let name = input("Header 名称", "Content-Type")
        _ = input("Header 值", "json")
        precondition(name.numberOfItems > 0)
        try! saveSnapshot(host.controls, name: "request-filter-form-header")
        precondition(model.filter.conditionGroup?.groups[0].conditions[0].headerName == "Content-Type")
        select(popups("Header 来源").last!, "修改后请求")
        precondition(model.filter.conditionGroup?.groups[0].conditions[0].headerSource == .sent)
        let remove = descendants(host.controls).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "移除条件组" }!
        precondition(remove.bounds.width == remove.bounds.height && remove.bounds.height >= 28)
        remove.performClick(nil); settle(host.view)
        precondition(model.filter.conditionGroup?.groups.isEmpty == true)
        precondition(abs(host.controls.frame.height - collapsedHeight - singleConditionHeight) < 1,
                     "Removing a group must reclaim its height")
        model.filter.search = "retained search"; model.filter.resource = .json; settle(host.view)
        button("重置").performClick(nil); settle(host.view)
        precondition(model.filter == CaptureRecordFilter())
        precondition(host.controls.isExpanded, "Reset keeps the form open")
        precondition(abs(host.controls.frame.height - collapsedHeight - emptyFormHeight) < 1,
                     "Reset must shrink the form back to its empty content height")
        host.controls.showFilters(); settle(host.view)
    }

    private static func checkColumnWidths(_ table: NSTableView, host: FilterFixtureView,
                                          window: NSWindow, model: FilterFixture, defaults: UserDefaults) {
        let key = RequestRecordsTable.columnWidthsKey
        precondition(table.allowsColumnResizing && !table.allowsColumnReordering)
        precondition(table.tableColumns.allSatisfy { $0.resizingMask.contains(.userResizingMask) })
        precondition(defaults.object(forKey: key) == nil, "Automatic fitting must not persist widths")
        let header = table.headerView!
        let rect = header.headerRect(ofColumn: 2)
        let start = header.convert(NSPoint(x: rect.maxX - 1, y: rect.midY), to: nil)
        let oldRequestWidth = table.tableColumns[2].width
        let drag = LiveColumnDragCheck(table: table, defaults: defaults, start: start)
        let timer = Timer(timeInterval: 0.08, target: drag, selector: #selector(LiveColumnDragCheck.advance(_:)),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        header.mouseDown(with: drag.mouse(.leftMouseDown, offset: 0))
        timer.invalidate()
        precondition(drag.checkedSteps == 3, "Must inspect intermediate widths before mouse-up")
        settle(host.view)
        precondition(abs(table.tableColumns[2].width - oldRequestWidth - 30) < 2,
                     "Native header drag must adjust the request column")
        precondition(defaults.object(forKey: key) != nil, "Native header drag must persist widths")
        for index in table.tableColumns.indices {
            let column = table.tableColumns[index]
            let oldWidth = column.width
            column.width += 12
            table.delegate?.tableViewColumnDidResize?(Notification(name: NSTableView.columnDidResizeNotification,
                object: table, userInfo: ["NSTableColumn": column, "NSOldWidth": oldWidth]))
            settle(host.view)
            precondition(abs(column.width - oldWidth - 12) < 1, "Dragged column must keep the requested width")
            precondition(abs(table.tableColumns.reduce(0) { $0 + $1.width } - table.enclosingScrollView!.contentSize.width) < 2)
        }
        let widths = table.tableColumns.map(\.width)
        let saved = defaults.dictionary(forKey: key) as! [String: Double]
        precondition(saved.count == 6)
        model.records.append(CaptureRecord(method: "GET", url: "https://example.test/new"))
        model.filter.search = "example"
        settle(host.view)
        precondition(zip(widths, table.tableColumns).allSatisfy { abs($0 - $1.width) < 1 },
                     "Incoming records and filtering must preserve manual widths")
        for width in [host.controls.minimumContentWidth, 820, 1440] {
            window.setContentSize(NSSize(width: width, height: 620))
            settle(host.view)
            precondition(abs(table.tableColumns.reduce(0) { $0 + $1.width } - table.enclosingScrollView!.contentSize.width) < 2)
            precondition(table.tableColumns.allSatisfy { $0.width >= $0.minWidth - 0.1 && $0.maxWidth > $0.minWidth },
                         "All columns remain adjustable in narrow windows")
            precondition(defaults.dictionary(forKey: key) as! [String: Double] == saved,
                         "Viewport adaptation must not overwrite preferences")
        }
        precondition(zip(widths, table.tableColumns).allSatisfy { abs($0 - $1.width) < 1 },
                     "Returning to the original viewport must restore widths")
        var legacyWidths = saved
        legacyWidths["project"] = 180
        defaults.set(legacyWidths, forKey: key)
        let restored = FilterFixtureView(model: FilterFixture(), defaults: defaults)
        let restoredWindow = makeWindow(restored)
        restoredWindow.setContentSize(NSSize(width: 1440, height: 620))
        settle(restored.view)
        let restoredTable = descendants(restored.view).compactMap { $0 as? NSTableView }.first!
        precondition(zip(widths, restoredTable.tableColumns).allSatisfy { abs($0 - $1.width) < 1 },
                     "A new table must restore persisted widths: expected=\(widths), actual=\(restoredTable.tableColumns.map(\.width)), viewport=\(restoredTable.enclosingScrollView!.contentSize.width), saved=\(saved)")
        restoredWindow.close()
        var importedWidths = saved
        importedWidths["request"] = (saved["request"] ?? 320) * 1.5
        defaults.set(importedWidths, forKey: key)
        NotificationCenter.default.post(name: .init("Requestman.preferencesRestored"), object: nil)
        settle(host.view)
        precondition(abs(table.tableColumns[2].width - widths[2]) > 10, "Import must apply widths to an existing table immediately")
        precondition(defaults.dictionary(forKey: key) as! [String: Double] == importedWidths)
        defaults.set(saved, forKey: key)
        NotificationCenter.default.post(name: .init("Requestman.preferencesRestored"), object: nil)
        settle(host.view)
        precondition(zip(widths, table.tableColumns).allSatisfy { abs($0 - $1.width) < 1 })
        defaults.set(["request": -20], forKey: key)
        let fallback = FilterFixtureView(model: FilterFixture(), defaults: defaults)
        let fallbackWindow = makeWindow(fallback)
        fallbackWindow.setContentSize(NSSize(width: 1440, height: 620))
        settle(fallback.view)
        let fallbackTable = descendants(fallback.view).compactMap { $0 as? NSTableView }.first!
        precondition(fallbackTable.tableColumns.allSatisfy { $0.width.isFinite && $0.width > 0 })
        precondition(abs(fallbackTable.tableColumns.reduce(0) { $0 + $1.width } - fallbackTable.enclosingScrollView!.contentSize.width) < 2)
        fallbackWindow.close()
        print("Column checks passed: live native header drag before mouse-up, six resizable columns, persisted widths, record refresh, viewport adaptation, new-table restore and invalid-preference fallback")
    }

    private static func checkRowPresentation(_ table: NSTableView) {
        let expected: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemRed,
                                   .systemRed, .secondaryLabelColor, .systemGreen, .systemGreen]
        for row in 0..<8 {
            let statusCell = table.view(atColumn: 1, row: row, makeIfNecessary: true) as! NSTableCellView
            precondition(statusCell.textField?.textColor == expected[row])
            statusCell.backgroundStyle = .emphasized
            precondition(statusCell.textField?.textColor == .alternateSelectedControlTextColor)
            statusCell.backgroundStyle = .normal
            precondition(statusCell.textField?.textColor == expected[row], "Selection must restore status color")
            let rulesCell = table.view(atColumn: 3, row: row, makeIfNecessary: true) as! NSTableCellView
            let ruleLabels = rulesCell.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
            precondition(ruleLabels.map(\.stringValue) == ["商城规则组", "添加调试标记"], "Rules column must show project above the first rule name")
            precondition(!rulesCell.subviews.contains { $0 is NSButton }, "Steps must not be counted as matched workflows")
            precondition(rulesCell.toolTip?.contains("商城规则组") == true)
            let requestCell = table.view(atColumn: 2, row: row, makeIfNecessary: true) as! NSTableCellView
            requestCell.layoutSubtreeIfNeeded()
            let labels = requestCell.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
            precondition(labels.count == (row == 7 ? 2 : 1), "Only failures have a request subtitle")
            if row != 7 {
                precondition(abs(requestCell.textField!.frame.midY - requestCell.bounds.midY) < 1)
            }
        }
        let duration = table.view(atColumn: 5, row: 4, makeIfNecessary: true) as! NSTableCellView
        precondition(duration.textField?.stringValue == "3.2 s" && duration.textField?.alignment == .right)
    }
    private static func checkMethodTagRendering() {
        func renderedLabel(_ label: NSTextField) -> Data {
            let image = NSImage(size: label.bounds.size)
            image.lockFocus()
            NSColor.white.setFill(); label.bounds.fill()
            label.displayIgnoringOpacity(label.bounds, in: NSGraphicsContext.current!)
            image.unlockFocus()
            return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        }
        let tag = RequestMethodTag()
        for method in ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "BASELINE-CONTROL", "X-CUSTOM-METHOD", "GET"] {
            tag.setMethod(method)
            tag.frame = NSRect(origin: .zero, size: tag.intrinsicContentSize)
            tag.layoutSubtreeIfNeeded()
            let label = tag.subviews.first as! NSTextField
            let actual = renderedLabel(label)
            label.lineBreakMode = .byClipping
            let withoutEllipsis = renderedLabel(label)
            label.lineBreakMode = .byTruncatingTail
            precondition(actual == withoutEllipsis, "Method must render without an ellipsis: \(method)")
            precondition(label.bounds.width >= ceil(label.cell!.cellSize.width), "Full method text must fit the drawing cell")
            precondition(tag.bounds.width == RequestMethodTag.requiredWidth(for: method), "Table reservation and shared tag must agree")
        }
        print("Method tags: complete native glyph rendering and reused-label sizing passed")
    }

    private static func checkMethodLabels(_ table: NSTableView) {
        for row in 0..<table.numberOfRows {
            let cell = table.view(atColumn: 2, row: row, makeIfNecessary: true)!
            cell.layoutSubtreeIfNeeded()
            let method = descendants(cell).compactMap { $0 as? NSTextField }.first {
                $0.superview !== cell
            }!
            let tag = method.superview!
            precondition(method.bounds.width >= ceil(method.cell!.cellSize.width),
                         "Method text must fit completely: \(method.stringValue), available=\(method.bounds.width), needed=\(method.cell!.cellSize.width)")
            precondition(tag.frame.maxX <= cell.bounds.width,
                         "The request column must reserve the full method tag width")
        }
    }
    private static func checkRequestMenu(_ table: NSTableView, host: FilterFixtureView, model: FilterFixture) {
        var active = CaptureRecord(method: "GET", url: "https://example.test/replay")
        active.replayID = active.id; active.replaySourceID = UUID(); active.connectionState = .open
        var cancelledID: UUID?
        var sourceID: UUID?
        let actions = NSMenu(); actions.autoenablesItems = false
        RequestActionsMenu.append(to: actions, record: active, replayUnavailable: nil,
                                  cancelReplay: { cancelledID = $0 }, revealSource: { sourceID = $0 }, replay: { _, _ in })
        let cancel = actions.items.first { $0.title == "取消此次重放" }!
        let source = actions.items.first { $0.title == "查看原请求" }!
        precondition(NSApp.sendAction(cancel.action!, to: cancel.target, from: cancel))
        precondition(NSApp.sendAction(source.action!, to: source.target, from: source))
        precondition(cancelledID == active.replayID && sourceID == active.replaySourceID)
        active.connectionState = .closed
        let completedActions = NSMenu(); completedActions.autoenablesItems = false
        RequestActionsMenu.append(to: completedActions, record: active, replayUnavailable: nil, replay: { _, _ in })
        precondition(!completedActions.items.contains { $0.title == "取消此次重放" })
        precondition(completedActions.items.first { $0.title == "查看原请求" }?.isEnabled == false)
        var replayed: (CaptureRecord, Bool)?
        host.table.onReplay = { replayed = ($0, $1) }
        var requestedRecord: CaptureRecord?
        host.table.onMockRequest = { requestedRecord = $0 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        func menu(at point: NSPoint) -> NSMenu? {
            let location = table.convert(point, to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: table.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            return table.menu(for: event)
        }
        let row = table.rect(ofRow: 2)
        host.table.replayUnavailableReason = { "请先启动捕获，再重放请求" }
        let stoppedMenu = menu(at: NSPoint(x: row.midX, y: row.midY))!
        precondition(!stoppedMenu.items[0].isEnabled && stoppedMenu.items[0].toolTip != nil)
        let editWhileStopped = stoppedMenu.items[1]
        precondition(editWhileStopped.title == "重新发送请求…" && editWhileStopped.isEnabled && editWhileStopped.toolTip == nil)
        precondition(NSApp.sendAction(editWhileStopped.action!, to: editWhileStopped.target, from: editWhileStopped))
        precondition(replayed?.0.id == model.records[2].id && replayed?.1 == true)
        var incomplete = model.records[2]
        incomplete.requestBody = CaptureBodyCollector().snapshot(isComplete: false)
        let incompleteMenu = NSMenu(); incompleteMenu.autoenablesItems = false
        RequestActionsMenu.append(to: incompleteMenu, record: incomplete, replayUnavailable: nil, replay: { _, _ in
            preconditionFailure("An incomplete request must not open the editor")
        })
        precondition(!incompleteMenu.items[0].isEnabled && !incompleteMenu.items[1].isEnabled)
        host.table.replayUnavailableReason = { nil }
        let clickedMenu = menu(at: NSPoint(x: row.midX, y: row.midY))!
        precondition(clickedMenu.items.map(\.title) == ["重放", "重新发送请求…", "", "复制", "", "Mock 当前请求"])
        precondition(clickedMenu.items[2].isSeparatorItem && clickedMenu.items[4].isSeparatorItem)
        let item = clickedMenu.items[5]
        precondition(item.isEnabled)
        let original = model.records
        let clickedURL = original[2].url
        model.records.insert(CaptureRecord(method: "GET", url: "https://new.test"), at: 0)
        settle(host.view)
        precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        for (index, editing) in [false, true].enumerated() {
            let action = clickedMenu.items[index]
            precondition(action.isEnabled)
            precondition(NSApp.sendAction(action.action!, to: action.target, from: action))
            precondition(replayed?.0.url == clickedURL && replayed?.1 == editing)
        }
        precondition(requestedRecord?.url == clickedURL, "The context action uses the clicked row even after a new log arrives")
        model.records.removeAll()
        settle(host.view)
        precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        precondition(requestedRecord?.url == clickedURL)
        precondition(requestedRecord?.responseBody.data == original[2].responseBody.data)
        precondition(menu(at: NSPoint(x: 20, y: 20)) == nil, "Empty space has no request menu")
        model.records = original
        settle(host.view)
        let invalid = table.rect(ofRow: 7)
        let invalidMenu = menu(at: NSPoint(x: invalid.midX, y: invalid.midY))!
        precondition(!invalidMenu.items[5].isEnabled && invalidMenu.items[5].toolTip != nil)
        model.selectedID = nil
        settle(host.view)
    }

    private static func checkFilterDiscAlignment(_ button: NSButton) {
        let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds)!
        button.cacheDisplay(in: button.bounds, to: bitmap)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.9, color.blueComponent > color.redComponent + 0.3,
                      color.blueComponent > color.greenComponent + 0.15 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        precondition(maxX >= minX && maxY >= minY, "The active filter disc must render blue")
        let scaleX = CGFloat(bitmap.pixelsWide) / button.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / button.bounds.height
        let centerX = CGFloat(minX + maxX + 1) / (2 * scaleX)
        let centerY = CGFloat(minY + maxY + 1) / (2 * scaleY)
        precondition(abs(centerX - button.bounds.midX) <= 0.5 && abs(centerY - button.bounds.midY) <= 0.5,
                     "The blue disc must center in the native bezel: \(centerX), \(centerY) in \(button.bounds)")
        print("Filter disc pixel alignment passed: center \(centerX), \(centerY) in \(button.bounds.size)")
    }

    private static func saveSnapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["REQUESTMAN_FILTER_SNAPSHOT_DIR"] else { return }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Composite transparent native controls over the system window background for inspection.
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            context.cgContext.setBlendMode(.destinationOver)
            context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: destination.appendingPathComponent(name + ".png"))
        }
    }
    private static func makeWindow(_ controller: NSViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 620),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        return window
    }
    private static func settle(_ view: NSView) {
        for _ in 0..<12 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

// Timed events leave AppKit inside its real header tracking loop while each
// intermediate layout is checked. A queued drag + mouse-up only checks the result.
@MainActor
private final class LiveColumnDragCheck: NSObject {
    let table: NSTableView
    let defaults: UserDefaults
    let start: NSPoint
    let initialWidth: CGFloat
    private let offsets: [CGFloat] = [30, 60, 30]
    private var postedSteps = 0
    var checkedSteps = 0

    init(table: NSTableView, defaults: UserDefaults, start: NSPoint) {
        self.table = table
        self.defaults = defaults
        self.start = start
        initialWidth = table.tableColumns[2].width
    }

    func mouse(_ type: NSEvent.EventType, offset: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + offset, y: start.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: table.window!.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @objc func advance(_ timer: Timer) {
        if postedSteps > 0 {
            let expected = initialWidth + offsets[postedSteps - 1]
            precondition(abs(table.tableColumns[2].width - expected) < 2,
                         "Dragged column must follow the pointer before mouse-up")
            if let cell = table.view(atColumn: 2, row: 0, makeIfNecessary: false) {
                precondition(abs(cell.frame.width - expected) < 2,
                             "Visible request cells must resize during tracking, before mouse-up")
            } else { preconditionFailure("Live drag must exercise an existing request cell") }
            let viewport = table.enclosingScrollView!.contentSize.width
            precondition(abs(table.tableColumns.reduce(0) { $0 + $1.width } - viewport) < 2,
                         "All columns must fit the viewport during tracking, before mouse-up")
            precondition(abs(table.frame.width - viewport) < 2,
                         "Table must not become horizontally scrollable during tracking")
            precondition(abs(table.enclosingScrollView!.contentView.bounds.minX) < 1)
            precondition(defaults.object(forKey: RequestRecordsTable.columnWidthsKey) == nil,
                         "Drag previews must not write preferences on every pointer movement")
            checkedSteps += 1
        }
        if postedSteps == offsets.count {
            NSApp.postEvent(mouse(.leftMouseUp, offset: offsets.last!), atStart: false)
            timer.invalidate()
        } else {
            NSApp.postEvent(mouse(.leftMouseDragged, offset: offsets[postedSteps]), atStart: false)
            postedSteps += 1
        }
    }
}

@MainActor enum RequestClipboard { static func copy(_ value: String) {} }
