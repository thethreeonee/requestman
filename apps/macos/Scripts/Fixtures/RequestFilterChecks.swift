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
        record.project = "商城项目"; record.environment = "dev"; record.status = statuses[index]
        record.duration = index == 4 ? 3.2 : 0.128
        if index == 7 { record.outcome = .failed; record.error = "响应传输中断" }
        record.requestHeaders = [HTTPField("Content-Type", "application/json")]
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
        precondition(cell(4).toolTip == "商城项目\n未命中规则", "Unmatched requests must not gain a workflow")
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
        for width in [1440.0, 820, 600, 569, 567, 420, 600] {
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
            let types = views.compactMap { $0 as? NSSegmentedControl }.first!
            precondition(types.segmentCount == CaptureResourceType.allCases.count && !types.isHidden)
            precondition((0..<types.segmentCount).map { types.label(forSegment: $0)! } == CaptureResourceType.allCases.map(\.rawValue))
            precondition(!descendants(host.controls).contains { $0 is NSPopUpButton }, "All resource types stay inline")
            if #available(macOS 26.0, *) { precondition(types.controlSize == .extraLarge) }
            else { precondition(types.controlSize == .large) }
            let nativeHeight = types.intrinsicContentSize.height
            precondition(types.frame.width > 0 && types.frame.height == nativeHeight)
            precondition(types.bounds.size == types.frame.size, "Native text must never be stretched by a bounds/frame scale")
            precondition(types.frame.width >= types.intrinsicContentSize.width,
                         "All nine resource labels must fit at \(width) pt: frame=\(types.frame), natural=\(types.intrinsicContentSize), segments=\((0..<types.segmentCount).map { types.width(forSegment: $0) })")
            if #available(macOS 26.0, *) { precondition(types.borderShape == .capsule) }
            let filterButton = actions.first { $0.accessibilityLabel() == "筛选" }!
            precondition(filterButton.title.isEmpty && filterButton.image != nil)
            precondition(types.frame.height == filterButton.frame.height)
            precondition(host.controls.bounds.contains(types.frame))
            for index in 0..<types.segmentCount {
                let textWidth = (types.label(forSegment: index)! as NSString).size(withAttributes: [.font: types.font!]).width
                precondition(types.width(forSegment: index) >= ceil(textWidth) + 16,
                             "Every resource segment must retain its wider horizontal padding")
            }
            if width < types.intrinsicContentSize.width + nativeHeight * 3 + 63 {
                precondition(host.controls.bounds.height == nativeHeight * 2 + 24 && types.frame.maxY < filterButton.frame.minY,
                             "Narrow layouts move all nine full-width segments onto their own row: width=\(width), controls=\(host.controls.bounds), frame=\(host.controls.frame), heights=\(host.controls.constraints.filter { $0.firstAttribute == .height }.map { $0.constant }), segments=\(types.frame), filter=\(filterButton.frame)")
            } else {
                precondition(host.controls.bounds.height == nativeHeight + 16 && types.frame.maxX < filterButton.frame.minX)
                precondition(types.frame.midY == filterButton.frame.midY)
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

        model.filter.headers = [.init(name: "Content-Type", value: "json")]
        let panel = RequestFilterPanel(filter: model.filter, records: model.records) { model.filter = $0 }
        let panelWindow = makeWindow(panel)
        panelWindow.setContentSize(panel.preferredContentSize)
        settle(panel.view)
        let combo = descendants(panel.view).compactMap { $0 as? NSComboBox }.first { $0.accessibilityLabel() == "Header 名称" }!
        precondition(combo.stringValue == "Content-Type" && combo.numberOfItems > 0)
        combo.stringValue = "Accept"
        combo.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: combo))
        precondition(model.filter.headers[0].name == "Accept")
        precondition(panelWindow.makeFirstResponder(combo))
        settle(panel.view)
        let removals = descendants(panel.view).compactMap { $0 as? NSButton }
            .filter { $0.action == NSSelectorFromString("removeCondition:") }
        precondition(removals.count == 1)
        let remove = removals[0]
        precondition(abs(remove.bounds.width - remove.bounds.height) <= 1 && remove.bounds.height >= 28,
                     "Header removal must be a square native circular button, not a minus-height pill")
        let nameFrame = combo.convert(combo.bounds, to: panel.view)
        let removeFrame = remove.convert(remove.bounds, to: panel.view)
        precondition(abs(nameFrame.midY - removeFrame.midY) <= 1, "Header controls must be vertically centered")
        precondition(combo.bounds.height >= combo.intrinsicContentSize.height)
        if let clip = combo.enclosingScrollView?.contentView {
            let focusFrame = combo.convert(combo.bounds, to: clip).insetBy(dx: -5, dy: -5)
            precondition(clip.bounds.contains(focusFrame), "Header focus ring must fit inside the scroll viewport")
        } else { preconditionFailure("Header rows must use a bounded native scroll viewport") }
        print("Header row: input=\(nameFrame), remove=\(removeFrame), nativeHeight=\(combo.intrinsicContentSize.height)")
        remove.performClick(nil)
        settle(panel.view)
        precondition(model.filter.headers.isEmpty, "Native remove action must remove its bound condition")
        checkMetadataFilters(panel, window: panelWindow, model: model)
        precondition(!panelWindow.isVisible)
        panelWindow.close()
        print("Request filter CLI checks passed: 420–1440 pt layout, six columns, status colors and selection restoration, single-line request/reuse, no horizontal scrolling, filter model search/reset, table selection, Header suggestions and editing. Hidden component windows only; no App or visual acceptance.")
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
        let bitmap = controls.bitmapImageRepForCachingDisplay(in: controls.bounds)!
        controls.cacheDisplay(in: controls.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / controls.bounds.height
        let x = Int(segments.frame.midX * scale)
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

    private static func checkMetadataFilters(_ panel: RequestFilterPanel, window: NSWindow, model: FilterFixture) {
        let views = descendants(panel.view)
        func popup(_ label: String) -> NSPopUpButton {
            views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label }!
        }
        func select(_ label: String, _ value: String) {
            let control = popup(label)
            control.selectItem(withTitle: value)
            precondition(NSApp.sendAction(control.action!, to: control.target, from: control))
        }
        let domain = views.compactMap { $0 as? NSComboBox }.first { $0.accessibilityLabel() == "域名" }!
        let url = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "URL" }!
        precondition(domain.objectValues.compactMap { $0 as? String }.contains("example.test"))
        select("状态码", "200"); select("请求方法", "POST"); select("环境", "dev")
        url.stringValue = "/long/path"
        url.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: url))
        domain.stringValue = "example.test"
        domain.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: domain))
        precondition(model.filter.statusCode == 200 && model.filter.method == "POST" && model.filter.environment == "dev")
        precondition(model.filter.urlContains == "/long/path" && model.filter.domain == "example.test")
        precondition(model.filter.activeConditionCount == 5)
        precondition(model.records.filter { model.filter.matches($0) }.map(\.id) == [model.records[1].id])
        domain.selectItem(at: 0)
        panel.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: domain))
        precondition(model.filter.domain == "example.test")
        panel.update(filter: model.filter, records: [])
        precondition(domain.stringValue == "example.test" && popup("状态码").titleOfSelectedItem == "200")
        var retained = model.filter; retained.statusCode = 418
        panel.update(filter: retained, records: [])
        precondition(popup("状态码").titleOfSelectedItem == "418")
        window.setContentSize(panel.preferredContentSize)
        settle(panel.view)
        for control in [popup("状态码"), popup("请求方法"), popup("环境"), domain, url] as [NSControl] {
            let frame = control.convert(control.bounds, to: panel.view)
            precondition(panel.view.bounds.contains(frame) && frame.width >= 80 && frame.height >= 20,
                         "Metadata controls must remain visible and usable: \(frame)")
        }
        let reset = views.compactMap { $0 as? NSButton }.first { $0.title == "重置" }!
        reset.performClick(nil)
        precondition(model.filter == CaptureRecordFilter())
        precondition(domain.stringValue.isEmpty && url.stringValue.isEmpty && popup("状态码").indexOfSelectedItem == 0)
    }

    private static func checkColumnWidths(_ table: NSTableView, host: NSViewController,
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
        for width in [420.0, 820, 1440] {
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
            precondition(ruleLabels.map(\.stringValue) == ["商城项目", "添加调试标记"], "Rules column must show project above the first rule name")
            precondition(!rulesCell.subviews.contains { $0 is NSButton }, "Steps must not be counted as matched workflows")
            precondition(rulesCell.toolTip?.contains("商城项目") == true)
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
        var requestedURL: String?
        host.table.onModifyRequest = { requestedURL = $0 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        func menu(at point: NSPoint) -> NSMenu? {
            let location = table.convert(point, to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: table.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            return table.menu(for: event)
        }
        let row = table.rect(ofRow: 2)
        let clickedMenu = menu(at: NSPoint(x: row.midX, y: row.midY))!
        precondition(clickedMenu.items.map(\.title) == ["修改请求"])
        let item = clickedMenu.items[0]
        let original = model.records
        let clickedURL = original[2].url
        model.records.insert(CaptureRecord(method: "GET", url: "https://new.test"), at: 0)
        settle(host.view)
        precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        precondition(requestedURL == clickedURL, "The context action uses the clicked row even after a new log arrives")
        model.records.removeAll()
        settle(host.view)
        precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        precondition(requestedURL == clickedURL)
        precondition(menu(at: NSPoint(x: 20, y: 20)) == nil, "Empty space has no request menu")
        model.records = original
        model.selectedID = nil
        settle(host.view)
    }

    private static func saveSnapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["REQUESTMAN_FILTER_SNAPSHOT_DIR"] else { return }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
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
        for _ in 0..<8 {
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
