import AppKit
import RequestmanEditor
import CodeEditTextView
import QuartzCore
import Observation
import RequestmanCore

@MainActor @Observable final class WorkspaceModel {
    var selection: WorkspaceSection = .rules
    var document = WorkspaceDocument()
    func importArchive(_ archive: WorkspaceArchive) async throws { preconditionFailure("Unexpected file import") }
    var isTransitioning = false
    var loaded = true
    var selectedWorkflowID: UUID?
    var selectedStepID: UUID?
    var editingResponse = false
    var workflow: RequestWorkflow? { document.projects.flatMap(\.workflows).first { $0.id == selectedWorkflowID } }
    var selectedStep: ModificationStep? { (editingResponse ? workflow?.responseSteps : workflow?.requestSteps)?.first { $0.id == selectedStepID } }
    var projectName: String { document.projects.first { $0.workflows.contains { $0.id == selectedWorkflowID } }?.name ?? "" }
    func updateWorkflow(_ workflow: RequestWorkflow) {
        for p in document.projects.indices { if let w = document.projects[p].workflows.firstIndex(where: { $0.id == workflow.id }) { document.projects[p].workflows[w] = workflow; return } }
    }
    func addProject() { let project = WorkflowProject(); document.projects.append(project); addWorkflow(projectID: project.id) }
    func addWorkflow(projectID: UUID) {
        guard let index = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let workflow = RequestWorkflow(); document.projects[index].workflows.append(workflow); selectedWorkflowID = workflow.id; selectedStepID = nil
    }
    func duplicateWorkflow(_ workflow: RequestWorkflow, projectID: UUID) {
        guard let index = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        var copy = workflow; copy.id = UUID(); copy.name += " 副本"; document.projects[index].workflows.append(copy); selectedWorkflowID = copy.id
    }
    func deleteWorkflow(_ id: UUID) { for p in document.projects.indices { document.projects[p].workflows.removeAll { $0.id == id } }; if selectedWorkflowID == id { selectedWorkflowID = nil; selectedStepID = nil } }
    func duplicateProject(_ id: UUID) {
        var copy = document.projects.first { $0.id == id }!.duplicated(); copy.name += " 副本"
        document.projects.append(copy); selectedWorkflowID = copy.workflows.first?.id; selectedStepID = nil
    }
    func addStep(_ kind: ModificationKind, response: Bool) {
        guard var workflow else { return }; let step = ModificationStep(kind: kind)
        if response { workflow.responseSteps.append(step) } else { workflow.requestSteps.append(step) }
        updateWorkflow(workflow); editingResponse = response; selectedStepID = step.id
    }
}

@MainActor private final class StepInspectorReceiver: NSResponder, StepInspectorPresenting {
    var count = 0
    func showStepInspector(_ sender: Any?) { count += 1 }
    func toggleStepInspector(_ sender: Any?) { count += 1 }
}

@MainActor private final class ScriptFocusCheckWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private final class WheelCountingScrollView: NSScrollView {
    var wheelCount = 0
    override func scrollWheel(with event: NSEvent) { wheelCount += 1; super.scrollWheel(with: event) }
}

@main @MainActor struct RulesUIChecks {
    static func settleEditor(_ editor: CodeEditorView) {
        let until = Date().addingTimeInterval(0.35)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        editor.layoutSubtreeIfNeeded()
    }

    static func checkCodeEditorBehavior() {
        let outer = WheelCountingScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 480, height: 1400))
        outer.documentView = document; outer.hasVerticalScroller = true
        let window = NSWindow(contentRect: outer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = outer
        defer { window.close() }
        let area = CodeEditorView(language: .javascript)
        area.frame = NSRect(x: 20, y: 20, width: 430, height: 140); document.addSubview(area)
        for (source, forwards) in [("", true), ("return request;", true), (String(repeating: "let x = 1;\n", count: 150), false), ("short", true)] {
            area.string = source; area.layoutSubtreeIfNeeded()
            let previous = outer.wheelCount
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0)!
            area.textView.scrollWheel(with: NSEvent(cgEvent: wheel)!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            precondition(outer.wheelCount == previous + (forwards ? 1 : 0), "Code editor wheel routing must track overflow")
        }
        area.string = "const value = '中文😀';"
        window.makeFirstResponder(area.textView)
        area.textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 5))
        area.appearance = NSAppearance(named: .aqua); settleEditor(area)
        let light = area.textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        precondition(area.textView.selectedRange() == NSRange(location: 6, length: 5))
        precondition(area.textView.undoManager?.canUndo == false, "Loading and syntax colors must not register undo")
        area.appearance = NSAppearance(named: .darkAqua); settleEditor(area)
        let dark = area.textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        precondition(light != dark && area.string == "const value = '中文😀';")
        area.textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: area.textView.selectedRange())
        settleEditor(area)
        precondition(area.textView.hasMarkedText(), "Highlighting must not commit marked text")
        area.textView.insertText("拼音", replacementRange: area.textView.markedRange())
        settleEditor(area)
        precondition(area.string.contains("拼音"))
        area.string = String(repeating: "const value = 123;\n", count: 1000)
        area.string = "return request;"
        settleEditor(area)
        precondition(area.string == "return request;" && area.textView.textStorage.length == 15)
        print("Code editor passed: wheel forwarding, appearance, selection, no highlight undo, IME composition and stale-result rejection")
    }

    static func checkNumberedEditorGeometry() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for mode in 0..<3 {
            let area = CodeEditorView(language: mode == 2 ? .javascript : .json)
            window.contentView = area
            for style in [NSScroller.Style.overlay, .legacy] {
                area.scrollerStyle = style
                for height: CGFloat in [180, 420] {
                    window.setContentSize(NSSize(width: 480, height: height))
                    for source in ["return request;", Array(repeating: "line", count: 100).joined(separator: "\n")] {
                        area.string = source; area.layoutSubtreeIfNeeded()
                        area.textView.scrollToRange(NSRange(location: (source as NSString).length, length: 0))
                        area.layoutSubtreeIfNeeded()
                        let ruler = descendants(area).compactMap { $0 as? GutterView }.first!
                        let rulerFrame = ruler.convert(ruler.visibleRect, to: area)
                        let textFrame = area.contentView.convert(area.contentView.bounds, to: area)
                        precondition(abs(rulerFrame.minY - textFrame.minY) <= 0.5 && abs(rulerFrame.maxY - textFrame.maxY) <= 0.5,
                                     "Numbered editor edges must align: mode=\(mode), ruler=\(rulerFrame), text=\(textFrame)")
                        precondition(area.borderType == .bezelBorder && area.clipsToBounds,
                                     "The editor uses the native scroll-view bezel")
                        let bitmap = area.bitmapImageRepForCachingDisplay(in: area.bounds)!
                        area.cacheDisplay(in: area.bounds, to: bitmap)
                    }
                }
            }
        }
        checkGutterBaselineRendering()
        checkEmptyGutterRendering()
        print("Numbered editors passed: template/literal Body and JavaScript, aligned ruler/text edges, native borders, resizing and scrolling")
    }

    static func checkGutterBaselineRendering() {
        let area = CodeEditorView(language: .plaintext)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = area
        defer { window.close() }
        area.string = (1...60).map(String.init).joined(separator: "\n")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            area.appearance = NSAppearance(named: appearance)
            for style in [NSScroller.Style.overlay, .legacy] {
                area.scrollerStyle = style
                for offset in [0, (area.string as NSString).length] {
                    area.textView.scrollToRange(NSRange(location: offset, length: 0))
                    settleEditor(area)
                    let gutter = descendants(area).compactMap { $0 as? GutterView }.first!
                    let separator = descendants(gutter).compactMap { $0 as? NSBox }.first { $0.identifier?.rawValue == "editor.gutterSeparator" }!
                    precondition(separator.boxType == .separator && abs(separator.alignmentRect(forFrame: separator.frame).maxX - gutter.bounds.maxX) <= 0.5, "Separator frame=\(separator.frame), gutter=\(gutter.bounds)")
                    precondition(abs(area.textView.textInsets.left - gutter.frame.width - 6) < 0.5)
                    let bitmap = area.bitmapImageRepForCachingDisplay(in: area.bounds)!
                    area.cacheDisplay(in: area.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / area.bounds.width
                    let dark = appearance == .darkAqua
                    func inkBottom(in rect: NSRect) -> Int? {
                        let top = area.isFlipped ? rect.minY : area.bounds.height - rect.maxY
                        let x0 = max(0, Int(ceil(rect.minX * scale))), x1 = min(bitmap.pixelsWide, Int(floor(rect.maxX * scale)))
                        let y0 = max(0, Int(ceil(top * scale))), y1 = min(bitmap.pixelsHigh, Int(floor((top + rect.height) * scale)))
                        guard x0 < x1, y0 < y1 else { return nil }
                        return (y0..<y1).last { y in
                            (x0..<x1).contains { x in
                                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { return false }
                                return dark ? min(color.redComponent, color.greenComponent, color.blueComponent) > 0.5 : max(color.redComponent, color.greenComponent, color.blueComponent) < 0.65
                            }
                        }
                    }
                    var checked = 0
                    for line in area.textView.layoutManager.linesStartingAt(area.contentView.bounds.minY, until: area.contentView.bounds.maxY) {
                        guard line.index > 0, let fragment = line.data.lineFragments.first?.data else { continue }
                        let row = area.textView.convert(NSRect(x: 0, y: line.yPos, width: area.textView.bounds.width, height: fragment.scaledHeight), to: area)
                        guard area.bounds.insetBy(dx: 0, dy: 8).contains(row.intersection(NSRect(x: 0, y: row.minY, width: area.bounds.width, height: row.height))) else { continue }
                        let numberRect = NSRect(x: 4, y: row.minY, width: gutter.frame.width - 12, height: row.height)
                        let textRect = NSRect(x: area.textView.textInsets.left, y: row.minY, width: 24, height: row.height)
                        guard let numberBottom = inkBottom(in: numberRect), let textBottom = inkBottom(in: textRect) else { preconditionFailure("Missing rendered line number or text") }
                        precondition(abs(numberBottom - textBottom) <= Int(ceil(scale)), "Rendered number/text baselines differ: line=\(line.index + 1), number=\(numberBottom), text=\(textBottom), scale=\(scale)")
                        checked += 1
                    }
                    precondition(checked >= 3, "Baseline comparison must cover multiple visible lines")
                    if let path = ProcessInfo.processInfo.environment["REQUESTMAN_GUTTER_PREVIEW"], appearance == .aqua, style == .overlay, offset == 0 {
                        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
        print("Rendered gutter passed: number/text baselines, native separator and spacing, both themes and scroller styles, before/after scrolling")
    }

    static func checkEmptyGutterRendering() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for language in [CodeEditorView.Language.json, .javascript] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let area = CodeEditorView(language: language)
                window.contentView = area; area.appearance = NSAppearance(named: appearance)
                for (state, source) in [("initial", ""), ("typed", "1"), ("cleared", ""), ("trailing", "1\n")] {
                    area.replaceText(with: source)
                    area.textView.selectionManager.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
                    settleEditor(area)
                    guard state != "typed" else { continue }
                    let gutter = descendants(area).compactMap { $0 as? GutterView }.first!
                    let line = area.textView.layoutManager.textLineForOffset((source as NSString).length)!
                    let row = area.textView.convert(NSRect(x: 0, y: line.yPos, width: gutter.frame.width, height: line.height), to: area)
                    let bitmap = area.bitmapImageRepForCachingDisplay(in: area.bounds)!
                    area.cacheDisplay(in: area.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / area.bounds.width
                    let top = area.isFlipped ? row.minY : area.bounds.height - row.maxY
                    let x0 = Int(ceil(8 * scale)), x1 = Int(floor((gutter.frame.width - 8) * scale))
                    let y0 = max(0, Int(floor(top * scale))), y1 = min(bitmap.pixelsHigh, Int(ceil((top + row.height + 2) * scale)))
                    let inkRows = (y0..<y1).filter { y in
                        (x0..<x1).contains { x in
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { return false }
                            return appearance == .darkAqua
                                ? min(color.redComponent, color.greenComponent, color.blueComponent) > 0.6
                                : max(color.redComponent, color.greenComponent, color.blueComponent) < 0.4
                        }
                    }
                    guard let first = inkRows.first, let last = inkRows.last else { preconditionFailure("Empty editor must render its line number") }
                    let center = CGFloat(first + last + 1) / (2 * scale)
                    let expectedCenter = top + row.height / 2
                    precondition(abs(center - expectedCenter) <= 1,
                                 "Empty line number must be centered: language=\(language), state=\(state), center=\(center), rowCenter=\(expectedCenter)")
                    if let directory = ProcessInfo.processInfo.environment["REQUESTMAN_EMPTY_GUTTER_PREVIEW"], language == .json, appearance == .aqua {
                        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("empty-gutter-" + state + ".png"))
                    }
                }
            }
        }
        print("Empty gutter rendering passed: initial, typed then cleared and trailing empty lines in Body/JavaScript and both themes")
    }

    static func checkStepAccessories() {
        guard #available(macOS 26.0, *) else { return }
        let model = WorkspaceModel(); model.addProject(); model.addStep(.setHeader, response: false)
        var workflow = model.workflow!
        workflow.requestSteps[0].headerEntries = (0..<12).map { HeaderEntry(operation: .modify, name: "X-\($0)", value: "value") }
        model.updateWorkflow(workflow)
        let inspector = StepInspectorViewController(model: model)
        let split = NSSplitViewController(); split.splitView.isVertical = true
        let sidebar = ProjectSidebarViewController(model: model)
        let flow = FlowEditorViewController(model: model)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 260; sidebarItem.maximumThickness = 320; sidebarItem.allowsFullHeightLayout = true
        split.addSplitViewItem(sidebarItem)
        let flowItem = NSSplitViewItem(viewController: flow)
        flowItem.minimumThickness = 420; flowItem.allowsFullHeightLayout = true
        split.addSplitViewItem(flowItem)
        let item = NSSplitViewItem(sidebarWithViewController: inspector)
        item.minimumThickness = 400; item.maximumThickness = 600; item.allowsFullHeightLayout = true
        split.addSplitViewItem(item)
        inspector.installAccessories(on: item)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        // Keep the three-pane fixture within the workspace's usable size during selection changes.
        window.contentMinSize = NSSize(width: 1100, height: 600)
        window.isReleasedWhenClosed = false; window.contentViewController = split
        defer { window.close() }
        func settle() {
            for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        settle()
        let bottom = item.bottomAlignedAccessoryViewControllers.first!
        precondition(item.topAlignedAccessoryViewControllers.isEmpty, "Step headings live in the window toolbar")
        let preview = descendants(flow.view).first { $0.identifier?.rawValue == "rules.previewFlow" }!
        let sidebarAdd = descendants(sidebar.view).first { $0.identifier?.rawValue == "rules.sidebarAdd" }!
        let flowScroll = descendants(flow.view).first { $0.identifier?.rawValue == "rules.editorScroll" } as! NSScrollView
        precondition(!preview.isDescendant(of: flowScroll), "Preview stays outside the scrolling form")
        func checkFooterAlignment() {
            let actions = [sidebarAdd, preview] + descendants(bottom.view).compactMap { $0 as? NSButton }
            let centers = actions.map { $0.convert($0.bounds, to: split.view).midY }
            precondition(centers.max()! - centers.min()! < 1, "All three pane actions align: \(centers)")
            precondition(abs(preview.convert(preview.bounds, to: flow.view).minX - 24) < 1)
        }
        checkFooterAlignment()
        let previewBeforeScroll = preview.convert(preview.bounds, to: split.view)
        flowScroll.documentView!.scroll(NSPoint(x: 0, y: flowScroll.documentView!.bounds.maxY)); settle()
        precondition(preview.convert(preview.bounds, to: split.view) == previewBeforeScroll)
        window.setContentSize(NSSize(width: 1200, height: 600)); settle(); checkFooterAlignment()
        window.setContentSize(NSSize(width: 1400, height: 800)); settle(); checkFooterAlignment()
        let scroll = descendants(inspector.view).compactMap { $0 as? NSScrollView }.first!
        precondition(scroll.frame == inspector.view.bounds, "The form scrolls behind the native footer accessory")
        precondition(!descendants(inspector.view).compactMap { $0 as? NSBox }.contains { $0.boxType == .separator }, "No footer separator remains")
        precondition(bottom.view.frame.height > 0)
        let first = descendants(inspector.view).first { $0.identifier?.rawValue == "rules.headerEntry" }!
        precondition(first.convert(first.bounds, to: split.view).maxY <= inspector.view.convert(inspector.view.safeAreaRect, to: split.view).maxY + 1,
                     "The first Header begins inside the unobscured area")
        let add = descendants(bottom.view).compactMap { $0 as? ActionButton }.first { $0.title == "Header 修改" }!
        add.performClick(nil); inspector.refresh(); settle()
        precondition(model.selectedStep?.headerEntries.count == 13)
        let currentScroll = descendants(inspector.view).compactMap { $0 as? NSScrollView }.first!
        currentScroll.documentView!.scroll(NSPoint(x: 0, y: currentScroll.documentView!.bounds.maxY)); settle()
        let last = descendants(inspector.view).last { $0.identifier?.rawValue == "rules.headerEntry" }!
        let lastFrame = last.convert(last.bounds, to: split.view)
        let footerFrame = bottom.view.convert(bottom.view.bounds, to: split.view)
        precondition(lastFrame.minY >= footerFrame.maxY - 1, "The last Header stays above the footer at the scroll limit: last=\(lastFrame), footer=\(footerFrame), insets=\(currentScroll.contentInsets)")
        inspector.isPresented = false; settle()
        precondition(bottom.isHidden, "Switching away hides the footer accessory")
        inspector.isPresented = true; settle()
        precondition(!bottom.isHidden)
        model.selectedStepID = nil; inspector.refresh(); settle()
        precondition(bottom.isHidden, "Clearing the selected step hides the footer accessory")
        model.addStep(.replaceBody, response: false); inspector.refresh(); settle()
        let bodyScroll = descendants(inspector.view).compactMap { $0 as? NSScrollView }.first!
        let body = descendants(inspector.view).compactMap { $0 as? CodeEditorView }.first!
        precondition(body.frame.height >= 360 && !bottom.isHidden)
        let available = bodyScroll.contentSize.height - bodyScroll.contentInsets.top - bodyScroll.contentInsets.bottom
        precondition(abs(bodyScroll.documentView!.frame.height - available) < 2,
                     "A short Body form fills the unobscured viewport without excess scrolling: document=\(bodyScroll.documentView!.frame), available=\(available), scroll=\(bodyScroll.frame), contentSize=\(bodyScroll.contentSize), insets=\(bodyScroll.contentInsets), safe=\(inspector.view.safeAreaRect), bottom=\(bottom.view.frame), window=\(window.frame)")
        model.addStep(.script, response: false); inspector.refresh(); settle()
        let script = inspector.children.first { $0 is ScriptEditorViewController }!
        precondition(inspector.view.safeAreaRect.contains(script.view.frame), "The script editor's controls stay inside the unobscured area")
        precondition(descendants(bottom.view).compactMap { $0 as? ActionButton }.contains { $0.title == "删除" })
        print("Step accessories passed: full-height scrolling, reachable first/last rows, Body sizing, script layout, fixed footer actions and lifecycle")
    }

    static func checkTextAreaWheelRouting() {
        let outer = WheelCountingScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        outer.hasVerticalScroller = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 480, height: 1400))
        outer.documentView = document
        let window = NSWindow(contentRect: outer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = outer
        defer { window.close() }
        func wheel() -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0)!
            event.flags = []
            return NSEvent(cgEvent: event)!
        }
        for template in [false, true] {
            let area = RulesTextArea(template: template)
            area.frame = NSRect(x: 20, y: 20, width: 430, height: 120); document.addSubview(area)
            func prepare(_ source: String) {
                area.string = source
                area.textView.layoutManager!.ensureLayout(for: area.textView.textContainer!)
                outer.layoutSubtreeIfNeeded()
                area.layoutSubtreeIfNeeded()
                outer.contentView.scroll(to: .zero); outer.reflectScrolledClipView(outer.contentView)
            }
            for short in ["", "one line"] {
                prepare(short)
                let count = outer.wheelCount
                area.textView.scrollWheel(with: wheel())
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                precondition(outer.wheelCount == count + 1 && outer.contentView.bounds.minY > 0,
                             "A fitting editor must route wheel events to the surrounding form: template=\(template), text=\(short), wheels=\(outer.wheelCount)/\(count), outer=\(outer.contentView.bounds), outerDocument=\(outer.contentView.documentRect), document=\(area.contentView.documentRect), viewport=\(area.contentView.bounds)")
                precondition(abs(area.contentView.bounds.minY) < 1, "Short text must not rubber-band")
            }
            prepare(Array(repeating: "long content", count: 100).joined(separator: "\n"))
            let count = outer.wheelCount
            area.textView.scrollWheel(with: wheel())
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(outer.wheelCount == count && area.contentView.bounds.minY > 0,
                         "Overflowing text must keep native internal scrolling")
            prepare("short again")
            area.textView.scrollWheel(with: wheel())
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(outer.wheelCount == count + 1, "Shrinking text restores outer scrolling")
            area.removeFromSuperview()
        }
        print("Text editor wheel routing passed: empty/short content forwards, long content scrolls, shrinking restores forwarding")
    }

    static func checkCapturedMockEditing() throws {
        var record = CaptureRecord(method: "POST", url: "https://example.test/api?q=1")
        record.status = 201
        record.requestHeaders = [HTTPField("X-Captured", "value")]
        let body = CaptureBodyCollector()
        body.append(Data(#"{"value":"{{literal}}"}"#.utf8))
        record.requestBody = body.snapshot(isComplete: true)
        record.originalStatus = 201
        record.receivedBody = body.snapshot(isComplete: true)
        record.receivedHeaders = [HTTPField("Content-Type", "application/json"), HTTPField("X-Origin", "original")]
        let workflow = try CapturedMockWorkflow.make(from: record)
        precondition(workflow.responseSteps.map(\.kind) == [.setStatus, .replaceBody, .setHeader] && !workflow.requestSteps.contains { $0.kind == .mock })
        precondition(workflow.requestSteps.last?.headerEntries.first?.operation == .modify)
        let model = WorkspaceModel(); model.addProject()
        model.document.projects[0].workflows = [workflow]
        model.selectedWorkflowID = workflow.id; model.editingResponse = false
        model.selectedStepID = workflow.requestSteps[2].id
        let inspector = StepInspectorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = inspector
        defer { window.close() }
        inspector.refresh(); inspector.view.layoutSubtreeIfNeeded()
        let area = descendants(inspector.view).compactMap { $0 as? CodeEditorView }.first!
        precondition(area.string == workflow.requestSteps[2].value && area.textView.isEditable)
        precondition(area.clipsToBounds && area.borderType == .bezelBorder)
        // Render the actual literal editor inside its scrolling Inspector, with a long body.
        area.string = "{\n" + (0..<80).map { "  \"field\($0)\": \"value\"" }.joined(separator: ",\n") + "\n}"
        for height: CGFloat in [480, 760] {
            window.setContentSize(NSSize(width: 520, height: height))
            inspector.view.layoutSubtreeIfNeeded()
            area.textView.scrollToRange(NSRange(location: (area.string as NSString).length, length: 0))
            let ruler = descendants(area).compactMap { $0 as? GutterView }.first!
            let frame = ruler.convert(ruler.visibleRect, to: area)
            precondition(frame.minY >= 0 && frame.maxY <= area.bounds.maxY + 1)
            let bitmap = inspector.view.bitmapImageRepForCachingDisplay(in: inspector.view.bounds)!
            inspector.view.cacheDisplay(in: inspector.view.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["REQUESTMAN_CAPTURED_MOCK_PREVIEW"] {
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mock-body-\(Int(height)).png"))
            }
        }
        let templates = descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "rules.resolveTemplates" }!
        precondition(templates.state == .off)
        area.string = #"{"edited":true}"#
        area.onChange(area.string)
        precondition(model.selectedStep?.value == area.string)
        templates.performClick(nil); inspector.refresh()
        precondition(model.selectedStep?.literalValues == false)

        var updated = model.workflow!
        updated.requestSteps[2].bodyEncoding = .base64
        updated.requestSteps[2].literalValues = true
        updated.requestSteps[2].value = Data([0, 255, 10]).base64EncodedString()
        model.updateWorkflow(updated); inspector.refresh()
        precondition(descendants(inspector.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Body · Base64" })
        let binary = descendants(inspector.view).compactMap { $0 as? CodeEditorView }.first!
        precondition(binary.string == "AP8K" && binary.textView.isEditable)
        let format = descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == "格式化 JSON" }!
        precondition(format.isHidden)
        model.editingResponse = true; model.selectedStepID = workflow.responseSteps[1].id; inspector.refresh()
        let responseBody = descendants(inspector.view).compactMap { $0 as? CodeEditorView }.first!
        precondition(responseBody.string == workflow.responseSteps[1].value && responseBody.textView.isEditable)
        model.selectedStepID = workflow.responseSteps[2].id; inspector.refresh()
        let headers = descendants(inspector.view).compactMap { $0 as? HeaderNameField }
        precondition(headers.map(\.stringValue) == ["Content-Type", "X-Origin"])
        let operations = descendants(inspector.view).compactMap { $0 as? ActionPopUpButton }.filter { $0.accessibilityLabel() == "Header 修改方法" }
        precondition(operations.count == 2 && operations.allSatisfy { $0.titleOfSelectedItem == "修改" && $0.itemTitles == ["添加", "修改", "删除", "添加或覆盖"] })
        print("Captured Mock inspector passed: editable prefilled text, literal/template toggle and lossless Base64 body")
    }

    static func checkSingleLineBackgrounds() {
        let model = WorkspaceModel(); model.addProject()
        let inspector = StepInspectorViewController(model: model)
        let flow = FlowEditorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var checked = 0
        func check(_ controller: NSViewController) {
            if controller === inspector {
                let split = NSSplitViewController()
                let main = NSViewController(); main.view = NSView()
                split.addSplitViewItem(NSSplitViewItem(viewController: main))
                let item = NSSplitViewItem(sidebarWithViewController: inspector)
                item.minimumThickness = 640; item.maximumThickness = 640
                split.addSplitViewItem(item)
                window.contentViewController = split
                window.setContentSize(NSSize(width: 1060, height: 1000))
            } else {
                window.contentViewController = controller
                window.setContentSize(NSSize(width: 640, height: 1000))
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for _ in 0..<3 {
                    controller.view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                let fields = descendants(controller.view).compactMap { $0 as? NSTextField }.filter {
                    ($0 is ActionTextField || $0 is HeaderNameField) && $0.isEditable && ($0.isBezeled || $0.isBordered)
                        && $0.bezelStyle != .roundedBezel && !$0.isHiddenOrHasHiddenAncestor
                }
                precondition(!fields.isEmpty)
                for field in fields {
                    precondition(abs(field.bounds.height - 32) < 0.5, "Single-line input height must be 32 pt: \(field.accessibilityLabel() ?? field.placeholderString ?? "input"), \(field.bounds)")
                    for focused in [false, true] {
                        if focused { field.selectText(nil) } else { window.makeFirstResponder(nil) }
                        controller.view.layoutSubtreeIfNeeded()
                        field.displayIfNeeded()
                        guard let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) else {
                            preconditionFailure("Missing input layout: \(field.accessibilityLabel() ?? field.placeholderString ?? "input"), \(field.frame)")
                        }
                        field.cacheDisplay(in: field.bounds, to: bitmap)
                        var white = 0
                        for y in 0..<bitmap.pixelsHigh {
                            for x in 0..<bitmap.pixelsWide {
                                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                                   color.alphaComponent > 0.95 && color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95 { white += 1 }
                            }
                        }
                        precondition(field is HeaderNameField || field.accessibilityLabel() == "JSON 路径"
                                     || white > bitmap.pixelsWide * bitmap.pixelsHigh / 3,
                                     "Input must render an opaque white fill: \(field.accessibilityLabel() ?? field.placeholderString ?? "input"), \(appearance), focus=\(focused)")
                        if focused {
                            let editor = field.currentEditor() as! NSTextView
                            let before = field.stringValue
                            editor.insertText("x", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                            precondition(field.stringValue == "x")
                            editor.insertText(before, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                        }
                        checked += 1
                    }
                }
            }
            window.makeFirstResponder(nil)
        }
        var workflow = model.workflow!
        workflow.matchConditions.conditions.append(.init(field: .header, operation: .equals, name: "X-Test", value: "test"))
        model.updateWorkflow(workflow)
        check(flow)
        for kind in [ModificationKind.setHeader, .modifyJSON, .setQueryParameter, .replaceURLString, .mock, .delay, .script] {
            model.addStep(kind, response: kind == .delay); inspector.refresh()
            check(inspector)
        }
        print("Single-line inputs: \(checked) rendered background and editing checks passed")
    }

    static func checkURLRewriteSplitWidth() {
        guard #available(macOS 26.0, *) else { return }
        let model = WorkspaceModel(); model.addProject(); model.addStep(.rewriteURL, response: false)
        let inspector = StepInspectorViewController(model: model)
        let split = NSSplitViewController(); split.splitView.isVertical = true
        let main = NSViewController(); main.view = NSView()
        let mainItem = NSSplitViewItem(viewController: main); mainItem.minimumThickness = 420
        split.addSplitViewItem(mainItem)
        let item = NSSplitViewItem(sidebarWithViewController: inspector)
        item.minimumThickness = 400; item.maximumThickness = 760; item.allowsFullHeightLayout = true
        split.addSplitViewItem(item); inspector.installAccessories(on: item)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 900, height: 800)
        window.isReleasedWhenClosed = false; window.contentViewController = split
        defer { window.close() }
        func settle() {
            inspector.refresh()
            for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        settle()
        for width: CGFloat in [400, 520, 640] {
            split.splitView.setPosition(split.splitView.bounds.width - split.splitView.dividerThickness - width, ofDividerAt: 0)
            settle()
            let baseline = inspector.view.frame.width, windowFrame = window.frame
            precondition(item.topAlignedAccessoryViewControllers.isEmpty)
            for index in [1, 2, 0, 2, 1, 0] {
                let control = descendants(inspector.view).first { $0.identifier?.rawValue == "rules.urlRewriteTarget" } as! NSSegmentedControl
                control.selectedSegment = index; control.sendAction(control.action, to: control.target); settle()
                precondition(abs(inspector.view.frame.width - baseline) < 1 && window.frame == windowFrame,
                             "URL target must not resize the inspector or window: target=\(index), before=\(baseline), after=\(inspector.view.frame.width)")
                precondition(item.topAlignedAccessoryViewControllers.isEmpty)
                let inputHint = descendants(inspector.view).first { $0.identifier?.rawValue == "rules.urlRewriteInputDescription" } as? NSTextField
                if index == 0 { precondition(inputHint == nil) }
                else {
                    let inputHint = inputHint!
                    let area = descendants(inspector.view).compactMap { $0 as? RulesTextArea }.first!
                    let fields = area.superview as! NSStackView
                    let areaIndex = fields.arrangedSubviews.firstIndex(of: area)!
                    precondition(fields.arrangedSubviews[areaIndex + 1] === inputHint,
                                 "Target-specific guidance follows the URL input")
                    let inputRect = inputHint.convert(inputHint.bounds, to: inspector.view)
                    precondition(inputRect.minX >= 0 && inputRect.maxX <= baseline && inputHint.frame.height > 20)
                }
            }
        }
        print("URL rewrite split width passed: native accessories, resizable inspector, repeated target switching and wrapping")
    }

    static func checkURLRewriteEditing() throws {
        let model = WorkspaceModel(); model.addProject(); model.addStep(.rewriteURL, response: false)
        let inspector = StepInspectorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = inspector
        defer { window.close() }
        func settle() { inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded() }
        func selector() -> NSSegmentedControl {
            descendants(inspector.view).first { $0.identifier?.rawValue == "rules.urlRewriteTarget" } as! NSSegmentedControl
        }
        settle()
        precondition((0..<selector().segmentCount).map { selector().label(forSegment: $0) } == ["完整 URL", "主机", "路径"] && selector().selectedSegment == 0)
        precondition(selector().segmentStyle == .automatic && selector().controlSize == .large)
        if #available(macOS 26.0, *) { precondition(selector().borderShape == .capsule) }
        precondition(model.selectedStep?.urlRewriteTarget == nil)
        for (index, label, text) in [(1, "目标主机（可含端口）", "{{$env.host}}:8080"), (2, "目标路径", "/api/中文%2f"), (0, "目标 URL", "https://example.test/")] {
            let control = selector()
            control.selectedSegment = index; control.sendAction(control.action, to: control.target); settle()
            precondition(model.selectedStep?.effectiveURLRewriteTarget == URLRewriteTarget.allCases[index])
            let area = descendants(inspector.view).compactMap { $0 as? RulesTextArea }.first!
            precondition(area.textView.accessibilityLabel() == label)
            area.string = text; area.textDidChange(Notification(name: NSText.didChangeNotification)); settle()
            precondition(model.selectedStep?.value == text && descendants(inspector.view).contains { $0 === area })
            let decoded = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(model.selectedStep!))
            precondition(decoded == model.selectedStep)
            for width: CGFloat in [360, 440, 640] {
                window.setContentSize(NSSize(width: width, height: 650)); settle()
                precondition(!selector().hasAmbiguousLayout && selector().bounds.width > 0)
                let rect = selector().convert(selector().bounds, to: inspector.view)
                precondition(rect.minX >= 0 && rect.maxX <= inspector.view.bounds.width)
            }
        }
        let control = selector()
        control.selectedSegment = 1; control.sendAction(control.action, to: control.target); settle()
        precondition(model.selectedStep?.value == "https://example.test/", "Switching targets preserves the entered value")
        model.loaded = false; settle()
        precondition(!selector().isEnabled)
        let area = descendants(inspector.view).compactMap { $0 as? RulesTextArea }.first!
        precondition(!area.textView.isEditable)
    }

    static func checkURLReplacementEditing() throws {
        let model = WorkspaceModel(); model.addProject(); model.addStep(.replaceURLString, response: false)
        var workflow = model.workflow!
        workflow.requestSteps[0].name = "old"; workflow.requestSteps[0].value = "new"
        model.updateWorkflow(workflow)
        let inspector = StepInspectorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = inspector
        defer { window.close() }
        func settle() { inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded() }
        func boxes() -> [NSBox] { descendants(inspector.view).compactMap { $0 as? NSBox }.filter { $0.identifier?.rawValue == "rules.urlReplacementEntry" } }
        func buttons() -> [NSButton] { descendants(inspector.view).compactMap { $0 as? NSButton } }
        settle()
        precondition(boxes().count == 1)
        precondition(!descendants(inspector.view).contains { $0.identifier?.rawValue == "rules.stepDescription" })
        let firstBox = boxes()[0]
        let search = descendants(firstBox).compactMap { $0 as? ActionTextField }.first!
        let replacement = descendants(firstBox).compactMap { $0 as? RulesTextArea }.first!
        precondition(search.stringValue == "old" && replacement.string == "new")
        precondition(search.cell?.usesSingleLineMode == true && search.cell?.wraps == false)
        search.selectText(nil)
        let editor = search.currentEditor() as! NSTextView
        editor.insertText("test", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(search.currentEditor() == nil)
        replacement.string = "{{$env.target}}"; replacement.textDidChange(Notification(name: NSText.didChangeNotification))
        settle()
        precondition(boxes()[0] === firstBox)
        precondition(model.selectedStep?.urlReplacementEntries.first?.search == "test")
        precondition(model.selectedStep?.urlReplacementEntries.first?.replacement == "{{$env.target}}")
        let add = buttons().first { $0.title == "添加替换配置" }!
        precondition(!add.isDescendant(of: firstBox))
        add.performClick(nil); settle()
        buttons().first { $0.title == "添加替换配置" }!.performClick(nil); settle()
        precondition(boxes().count == 3 && Set(model.selectedStep!.urlReplacementEntries.map(\.id)).count == 3)
        for width: CGFloat in [360, 440, 640] {
            window.setContentSize(NSSize(width: width, height: 850)); settle()
            precondition(abs(inspector.view.bounds.width - width) < 1)
            for box in boxes() {
                precondition(!box.hasAmbiguousLayout && box.bounds.width > 0)
                for control in descendants(box) where control is ActionTextField || control is RulesTextArea || control is NSButton {
                    let rect = control.convert(control.bounds, to: box)
                    precondition(rect.minX >= 0 && rect.maxX <= box.bounds.width + 1)
                }
            }
        }
        let secondID = model.selectedStep!.urlReplacementEntries[1].id
        buttons().first { $0.accessibilityLabel() == "删除替换配置" }!.performClick(nil); settle()
        precondition(boxes().count == 2 && model.selectedStep!.urlReplacementEntries[0].id == secondID)
        for _ in 0..<2 { buttons().first { $0.accessibilityLabel() == "删除替换配置" }!.performClick(nil); settle() }
        precondition(boxes().isEmpty && model.selectedStep!.urlReplacementEntries.isEmpty)
        let decoded = try JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(model.selectedStep!))
        precondition(decoded.urlReplacements == [])
        buttons().first { $0.title == "添加替换配置" }!.performClick(nil); settle()
        precondition(boxes().count == 1 && model.selectedStep!.urlReplacementEntries[0].search.isEmpty)
    }

    static func checkQueryParameterEditing() {
        let model = WorkspaceModel(); model.addProject(); model.addStep(.setQueryParameter, response: false)
        let inspector = StepInspectorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = inspector
        defer { window.close() }
        func settle() { inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded() }
        func buttons() -> [NSButton] { descendants(inspector.view).compactMap { $0 as? NSButton } }
        func boxes() -> [NSBox] { descendants(inspector.view).compactMap { $0 as? NSBox }.filter { $0.identifier?.rawValue == "rules.queryParameterEntry" } }
        func text(_ box: NSBox, _ label: String) -> RulesTextArea {
            descendants(box).compactMap { $0 as? RulesTextArea }.first { $0.textView.accessibilityLabel() == label }!
        }
        func parameterName(_ box: NSBox) -> ActionTextField {
            descendants(box).compactMap { $0 as? ActionTextField }.first { $0.accessibilityLabel() == "参数名称" }!
        }
        settle()
        precondition(boxes().count == 1)
        precondition(!descendants(inspector.view).contains { $0.identifier?.rawValue == "rules.stepDescription" })
        precondition(descendants(boxes()[0]).compactMap { $0 as? NSTextField }.filter { !$0.isEditable }.map(\.stringValue) == ["操作", "参数名称", "参数值"])
        precondition(buttons().first { $0.title == "添加参数操作" }!.isDescendant(of: descendants(inspector.view).first { $0.identifier?.rawValue == "rules.stepFooter" }!), "Query parameter addition stays in the fixed footer")
        let firstBox = boxes()[0]
        let name = parameterName(firstBox), value = text(firstBox, "参数值")
        precondition(name.cell?.usesSingleLineMode == true && name.cell?.wraps == false)
        name.selectText(nil)
        let editor = name.currentEditor() as! NSTextView
        editor.insertText("debug", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(name.currentEditor() == nil, "Return commits the single-line parameter name")
        value.string = "true"; value.textDidChange(Notification(name: NSText.didChangeNotification))
        settle()
        precondition(model.selectedStep?.queryParameterEntries.first?.name == "debug")
        precondition(boxes()[0] === firstBox && text(firstBox, "参数值") === value, "Typing retains the field and selection")
        let popup = descendants(firstBox).compactMap { $0 as? ActionPopUpButton }.first!
        precondition(popup.itemTitles == ["添加", "修改", "删除"] && popup.indexOfSelectedItem == 0)
        let matching = descendants(firstBox).compactMap { $0 as? ActionPopUpButton }.first { $0.accessibilityLabel() == "参数名称匹配规则" }!
        precondition(matching.itemTitles == ["等于", "包含", "通配符", "正则"])
        precondition(matching.isHiddenOrHasHiddenAncestor && matching.indexOfSelectedItem == 0)
        popup.selectItem(at: 2); popup.onChange(2); settle()
        precondition(!matching.isHiddenOrHasHiddenAncestor)
        matching.selectItem(at: 3); matching.onChange(3); settle()
        precondition(model.selectedStep?.queryParameterEntries.first?.matchRule == .regex)
        precondition(value.isHiddenOrHasHiddenAncestor && !name.isHiddenOrHasHiddenAncestor)
        precondition(model.selectedStep?.queryParameterEntries.first?.operation == .remove)
        popup.selectItem(at: 1); popup.onChange(1); settle()
        precondition(!value.isHiddenOrHasHiddenAncestor && value.string == "true")
        precondition(model.selectedStep?.queryParameterEntries.first?.operation == .modify)
        precondition(!matching.isHiddenOrHasHiddenAncestor && matching.indexOfSelectedItem == 3)
        popup.selectItem(at: 0); popup.onChange(0); settle()
        precondition(matching.isHiddenOrHasHiddenAncestor && !value.isHiddenOrHasHiddenAncestor)
        popup.selectItem(at: 1); popup.onChange(1); settle()
        precondition(matching.indexOfSelectedItem == 3)
        buttons().first { $0.title == "添加参数操作" }!.performClick(nil); settle()
        buttons().first { $0.title == "添加参数操作" }!.performClick(nil); settle()
        precondition(boxes().count == 3 && Set(model.selectedStep!.queryParameterEntries.map(\.id)).count == 3)
        var workflow = model.workflow!
        workflow.requestSteps[0].queryParameterEntries = [
            QueryParameterEntry(name: "debug", value: "true"),
            QueryParameterEntry(operation: .modify, name: "page", value: "2"),
            QueryParameterEntry(operation: .remove, name: "utm_*", matchRule: .wildcard)
        ]
        model.updateWorkflow(workflow); settle()
        for width: CGFloat in [360, 440, 640] {
            window.setContentSize(NSSize(width: width, height: 850)); settle()
            precondition(abs(inspector.view.bounds.width - width) < 1, "The description wraps without widening the inspector")
            for box in boxes() {
                precondition(box.bounds.width > 0 && !box.hasAmbiguousLayout)
                let menus = descendants(box).compactMap { $0 as? ActionPopUpButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
                for menu in menus {
                    let rect = menu.convert(menu.bounds, to: box)
                    precondition(rect.minX >= 0 && rect.maxX <= box.bounds.width + 1 && rect.width >= 60)
                }
                if menus.count == 2 {
                    let first = menus[0].convert(menus[0].bounds, to: box)
                    let second = menus[1].convert(menus[1].bounds, to: box)
                    precondition(first.maxX <= second.minX && abs(first.midY - second.midY) < 1, "Operation and matching controls share one row")
                }
                for area in descendants(box).compactMap({ $0 as? RulesTextArea }) where !area.isHiddenOrHasHiddenAncestor {
                    let rect = area.convert(area.bounds, to: box)
                    precondition(rect.minX >= 0 && rect.maxX <= box.bounds.width + 1, "Query field must fit narrow inspector")
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["REQUESTMAN_QUERY_FORM_PREVIEW"] {
            window.setContentSize(NSSize(width: 440, height: 850)); settle()
            inspector.view.appearance = NSAppearance(named: .aqua)
            inspector.view.wantsLayer = true
            inspector.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            for area in descendants(inspector.view).compactMap({ $0 as? RulesTextArea }) {
                area.textView.layoutManager?.ensureLayout(for: area.textView.textContainer!)
                area.textView.display()
            }
            CATransaction.flush()
            let bitmap = inspector.view.bitmapImageRepForCachingDisplay(in: inspector.view.bounds)!
            inspector.view.cacheDisplay(in: inspector.view.bounds, to: bitmap)
            let image = NSImage(size: inspector.view.bounds.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill(); inspector.view.bounds.fill()
            bitmap.draw(in: inspector.view.bounds)
            // Layer-backed scroll views need their native document capture included separately offscreen.
            for area in descendants(inspector.view).compactMap({ $0 as? RulesTextArea }) where !area.isHiddenOrHasHiddenAncestor {
                let rect = area.textView.visibleRect
                guard let textBitmap = area.textView.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                area.textView.cacheDisplay(in: rect, to: textBitmap)
                textBitmap.draw(in: area.textView.convert(rect, to: inspector.view))
            }
            image.unlockFocus()
            let rendered = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try! rendered.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        let decoded = try! JSONDecoder().decode(ModificationStep.self, from: JSONEncoder().encode(model.selectedStep!))
        precondition(decoded == model.selectedStep)
        let reopened = StepInspectorViewController(model: model); reopened.refresh()
        precondition(descendants(reopened.view).compactMap { $0 as? ActionPopUpButton }.filter { $0.accessibilityLabel() == "参数操作" }.map(\.indexOfSelectedItem) == [0, 1, 2])
        precondition(descendants(reopened.view).compactMap { $0 as? ActionPopUpButton }.filter { $0.accessibilityLabel() == "参数名称匹配规则" }.map(\.indexOfSelectedItem) == [0, 0, 2])
        model.loaded = false; settle()
        precondition(descendants(inspector.view).compactMap { $0 as? ActionPopUpButton }.allSatisfy { !$0.isEnabled })
        model.loaded = true; settle()
        for _ in 0..<3 { buttons().first { $0.accessibilityLabel() == "删除参数操作" }!.performClick(nil); settle() }
        precondition(boxes().isEmpty && model.selectedStep?.queryParameterEntries.isEmpty == true)
        buttons().first { $0.title == "添加参数操作" }!.performClick(nil); settle()
        precondition(boxes().count == 1)
        workflow = model.workflow!
        workflow.requestSteps[0].queryParameters = nil
        workflow.requestSteps[0].name = "legacy"; workflow.requestSteps[0].value = "old"
        model.updateWorkflow(workflow); settle()
        precondition(parameterName(boxes()[0]).stringValue == "legacy")
        precondition(model.selectedStep?.queryParameters == nil, "Opening a legacy form must not migrate it")
        let legacyRule = descendants(boxes()[0]).compactMap { $0 as? ActionPopUpButton }.first { $0.accessibilityLabel() == "参数名称匹配规则" }!
        precondition(legacyRule.indexOfSelectedItem == 0 && !legacyRule.isHiddenOrHasHiddenAncestor)
        legacyRule.selectItem(at: 1); legacyRule.onChange(1); settle()
        precondition(model.selectedStep?.queryParameterEntries.first?.operation == .modify && model.selectedStep?.queryParameterEntries.first?.matchRule == .contains)
    }

    static func checkBodyEditing() {
        let original = #"{"z":900719925474099312345,"a":[true,null,1.2300e+04],"name":"中文😀","id":"{{$uuid}}","count":{{$env.count}},"empty":{}}"#
        let formatted = BodyJSONPresentation.formatted(original)!
        precondition(formatted.contains("900719925474099312345") && formatted.contains("1.2300e+04"))
        precondition(formatted.hasPrefix("{\n  \"z\":"), "Formatting preserves field order")
        precondition(formatted.contains("{{$env.count}}") && formatted.contains("{{$uuid}}") && formatted.contains("\"empty\": {}"))
        precondition(BodyJSONPresentation.formatted(formatted) == formatted)
        let loose = #"{name:"张三",nested:{enabled:true,},items:[1,2,],$token:"{{$uuid}}",数量:{{$env.count}},large:900719925474099312345,}"#
        let normalized = BodyJSONPresentation.formatted(loose)!
        precondition(normalized.contains("\"name\": \"张三\"") && normalized.contains("\"enabled\": true"))
        precondition(normalized.contains("\"数量\": {{$env.count}}") && normalized.contains("900719925474099312345"))
        precondition(BodyJSONPresentation.formatted(normalized) == normalized)
        let plainObject = BodyJSONPresentation.formatted(#"{a:[1,2,],nested:{b:true,},trueKey:"{unquoted:1,}",}"#)!
        precondition((try? JSONSerialization.jsonObject(with: Data(plainObject.utf8))) != nil)
        precondition(plainObject.contains(#""{unquoted:1,}""#), "Formatting must not alter punctuation inside strings")
        for invalid in ["plain text", "[1 2]", "{", "", "{a:1,,}", "[,]", "{a:,}", "{a:unknown}", "{a: (() => 1)()}"] {
            precondition(BodyJSONPresentation.formatted(invalid) == nil, "Invalid JSON was accepted: \(invalid)")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var saved = ""
        let area = CodeEditorView(language: .json) { saved = $0 }
        window.contentView = area; defer { window.close() }
        area.string = original
        window.makeFirstResponder(area.textView)
        precondition(area.formatJSON() && saved == formatted)
        area.textView.undoManager?.undo()
        precondition(area.string == original && saved == original, "Formatting is one undoable plain text edit")
        area.string = "{invalid}"
        precondition(!area.formatJSON() && area.string == "{invalid}")
        area.string = "{\r\n\"long\": \"" + String(repeating: "中文😀", count: 90) + "\"\r\n}\r\n"
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(area.textView.layoutManager.lineCount == 4)
        area.string = #"{"key":true,"id":"{{$uuid}}"}"#
        area.annotationRanges = { source in
            TemplateLayoutManager.expression.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length)).map(\.range)
        }
        settleEditor(area)
        precondition(area.textView.textStorage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor != .textColor)
        precondition(area.textView.textStorage.attribute(.backgroundColor, at: 23, effectiveRange: nil) != nil)
        // Exercise native ruler drawing for empty text, wrapped lines and scrolling.
        for source in ["", formatted, "[\n" + Array(repeating: "  \"" + String(repeating: "long ", count: 30) + "\"", count: 40).joined(separator: ",\n") + "\n]\n"] {
            area.string = source
            window.contentView?.layoutSubtreeIfNeeded()
            area.textView.scrollToRange(NSRange(location: (source as NSString).length, length: 0))
            guard let bitmap = area.bitmapImageRepForCachingDisplay(in: area.bounds) else { preconditionFailure("Missing editor rendering") }
            area.cacheDisplay(in: area.bounds, to: bitmap)
        }
        if let path = ProcessInfo.processInfo.environment["REQUESTMAN_BODY_EDITOR_PREVIEW"] {
            area.string = formatted; settleEditor(area); area.textView.scrollToRange(NSRange(location: 0, length: 0))
            window.contentView?.layoutSubtreeIfNeeded()
            let bitmap = area.bitmapImageRepForCachingDisplay(in: area.bounds)!
            area.cacheDisplay(in: area.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        let model = WorkspaceModel(); model.addProject()
        let bodyCases: [(Bool, ModificationKind)] = [(false, .replaceBody), (true, .replaceBody), (false, .mock)]
        for (response, kind) in bodyCases {
            model.addStep(kind, response: response)
            let inspector = StepInspectorViewController(model: model)
            inspector.refresh(); window.contentViewController = inspector
            window.contentView?.layoutSubtreeIfNeeded()
            let editor = descendants(inspector.view).compactMap { $0 as? CodeEditorView }.first!
            precondition(editor.frame.height == 360)
            let form = descendants(inspector.view).compactMap { $0 as? NSScrollView }.first { !($0 is CodeEditorView) }!
            window.setContentSize(NSSize(width: 480, height: 760))
            window.contentView?.layoutSubtreeIfNeeded()
            let expandedHeight = editor.frame.height
            precondition(expandedHeight > 360 && abs(form.documentView!.frame.height - form.contentSize.height) < 1,
                         "Body must fill the remaining viewport: editor=\(editor.frame), form=\(form.frame), document=\(form.documentView!.frame)")
            window.setContentSize(NSSize(width: 480, height: 960))
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(abs(editor.frame.height - expandedHeight - 200) < 1, "Only the editor should absorb extra window height")
            window.setContentSize(NSSize(width: 480, height: 360))
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(abs(editor.frame.height - 360) < 1 && form.documentView!.frame.height > form.contentSize.height,
                         "Small windows must keep a 360 pt editor and scroll the outer form: editor=\(editor.frame), form=\(form.frame), document=\(form.documentView!.frame), window=\(window.contentView!.frame)")
            form.documentView!.scroll(NSPoint(x: 0, y: form.documentView!.bounds.maxY))
            precondition(form.contentView.bounds.minY > 0, "The outer form must remain scrollable at minimum editor height")
            let longBody = "[\n" + Array(repeating: "  {\"name\": \"long body\"}", count: 300).joined(separator: ",\n") + "\n]"
            editor.string = longBody
            window.contentView?.layoutSubtreeIfNeeded()
            editor.textView.scrollToRange(NSRange(location: (longBody as NSString).length - 1, length: 1))
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(editor.contentView.bounds.minY > 0, "The last Body line must be reachable")
            precondition(editor.formatJSON())
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(editor.textView.layoutManager.lineCount > 300)
            editor.string = loose; editor.onChange(editor.string)
            descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == "格式化 JSON" }!.performClick(nil)
            precondition(model.selectedStep?.value == normalized, "Object literal input must save as formatted JSON in both directions")
            editor.string = original; editor.onChange(editor.string)
            descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == "格式化 JSON" }!.performClick(nil)
            precondition(model.selectedStep?.value == formatted, "Formatting must persist in both directions")
            editor.string = ""
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(editor.textView.frame.height >= editor.contentSize.height, "An empty editor must remain clickable throughout its viewport")
            let savedText = model.selectedStep!.value
            let source = descendants(inspector.view).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == "rules.bodySource" }!
            precondition(source.selectedSegment == 0, "Body source defaults to text")
            source.selectedSegment = 1; source.sendAction(source.action!, to: source.target)
            inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded()
            precondition(model.selectedStep?.usesBodyFile == true)
            precondition(!descendants(inspector.view).contains { $0 is CodeEditorView })
            precondition(descendants(inspector.view).compactMap { $0 as? NSButton }.contains { $0.title == "映射本地文件…" })
            precondition(!descendants(inspector.view).contains { $0.identifier?.rawValue == "rules.resolveTemplates" })
            var workflow = model.workflow!
            if response { workflow.responseSteps[workflow.responseSteps.count - 1].bodyFilePath = "/tmp/example.json" }
            else { workflow.requestSteps[workflow.requestSteps.count - 1].bodyFilePath = "/tmp/example.json" }
            model.updateWorkflow(workflow); inspector.refresh()
            precondition(descendants(inspector.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "/tmp/example.json" })
            let fileSource = descendants(inspector.view).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == "rules.bodySource" }!
            fileSource.selectedSegment = 0; fileSource.sendAction(fileSource.action!, to: fileSource.target)
            inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded()
            precondition(model.selectedStep?.value == savedText && model.selectedStep?.bodyFilePath == "/tmp/example.json")
            precondition(descendants(inspector.view).compactMap { $0 as? CodeEditorView }.first?.string == savedText)
        }
    }
    static func checkHeaderEditing(_ inspector: StepInspectorViewController, model: WorkspaceModel, window: NSWindow) {
        func button(_ title: String) -> NSButton {
            descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == title }!
        }
        button("Header 修改").performClick(nil); inspector.refresh()
        precondition(model.selectedStep?.headerEntries.count == 2)
        window.contentView?.layoutSubtreeIfNeeded()
        let boxes = descendants(inspector.view).compactMap { $0 as? NSBox }.filter { $0.identifier?.rawValue == "rules.headerEntry" }
        precondition(boxes.count == 2 && boxes.allSatisfy { descendants($0).compactMap { $0 as? HeaderNameField }.count == 1 })
        precondition(boxes.allSatisfy { !button("Header 修改").isDescendant(of: $0) })
        precondition(!descendants(inspector.view).contains { $0.identifier?.rawValue == "rules.stepDescription" })
        let fields = descendants(inspector.view).compactMap { $0 as? HeaderNameField }
        fields[1].stringValue = "X-Token"; fields[1].controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields[1]))
        let area = descendants(inspector.view).compactMap { $0 as? RulesTextArea }[1]
        window.makeFirstResponder(area.textView)
        let original = "pre{{$env.api}}post\n{{$uuid}}end / {{unfinished"
        area.textView.insertText(original, replacementRange: NSRange(location: 0, length: 0))
        inspector.refresh()
        precondition(model.selectedStep?.headerEntries[1].value == original)
        let layout = area.textView.layoutManager as! TemplateLayoutManager
        precondition(layout.tokenRanges.count == 2 && area.borderType == .bezelBorder)
        precondition((original as NSString).substring(with: layout.tokenRanges[0]) == "{{$env.api}}")
        window.contentView?.layoutSubtreeIfNeeded()
        var previousMark: NSRect?
        for token in layout.tokenRanges {
            let glyphs = layout.glyphRange(forCharacterRange: token, actualCharacterRange: nil)
            let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let mark = layout.backgroundRects(forCharacterRange: token).first!
            precondition(mark.height >= 19.9, "Consecutive marks must retain their padded height: \(mark), line: \(line)")
            let visible = layout.visibleTextBounds(forGlyphRange: glyphs, in: area.textView.textContainer!)
            precondition(abs(mark.midY - visible.midY) < 0.01, "Text must be optically centered inside its mark")
            if let previousMark {
                precondition(mark.minY - previousMark.maxY >= 4, "Consecutive template lines must retain a visible gap")
            }
            let following = layout.glyphRange(forCharacterRange: NSRange(location: NSMaxRange(token), length: 1), actualCharacterRange: nil)
            let nextText = layout.visibleTextBounds(forGlyphRange: following, in: area.textView.textContainer!)
            precondition(nextText.minX - mark.maxX >= 3.5, "Following ordinary text must clear the token background")
            if token.location > 0 && original.utf16[original.utf16.index(original.utf16.startIndex, offsetBy: token.location - 1)] != 10 {
                let previous = layout.glyphRange(forCharacterRange: NSRange(location: token.location - 1, length: 1), actualCharacterRange: nil)
                let previousText = layout.visibleTextBounds(forGlyphRange: previous, in: area.textView.textContainer!)
                precondition(mark.minX - previousText.maxX >= 3.5, "Leading ordinary text must clear the token background")
            }
            previousMark = mark
            let displayed = mark.offsetBy(dx: area.textView.textContainerOrigin.x, dy: area.textView.textContainerOrigin.y)
            precondition(area.contentView.bounds.contains(displayed), "Both template lines must fit without clipping")
            precondition(mark.width >= visible.width + 7.9 && mark.minY >= line.minY && mark.maxY <= line.maxY,
                         "Token padding must be visible and stay inside the line height")
        }
        if let path = ProcessInfo.processInfo.environment["REQUESTMAN_TEMPLATE_SNAPSHOT"],
           let bitmap = inspector.view.bitmapImageRepForCachingDisplay(in: inspector.view.bounds) {
            inspector.view.cacheDisplay(in: inspector.view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        area.textView.setSelectedRange(layout.tokenRanges[0])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let wrote = area.textView.writeSelection(to: pasteboard, types: area.textView.writablePasteboardTypes)
        precondition(wrote, "Clipboard export failed: selection=\(area.textView.selectedRange()), types=\(area.textView.writablePasteboardTypes)")
        precondition(pasteboard.string(forType: .string) == "{{$env.api}}")
        area.textView.undoManager?.undo()
        precondition(area.string.isEmpty && model.selectedStep?.headerEntries[1].value == "")
        area.textView.undoManager?.redo()
        precondition(area.string == original && layout.tokenRanges.count == 2)
        let operations = descendants(inspector.view).compactMap { $0 as? ActionPopUpButton }.filter { $0.accessibilityLabel() == "Header 修改方法" }
        precondition(operations.count == 2 && operations.allSatisfy { $0.itemTitles == ["添加", "修改", "删除", "添加或覆盖"] })
        operations[1].selectItem(at: 2); operations[1].onChange(2); inspector.refresh()
        precondition(model.selectedStep?.headerEntries[1].operation == .remove && area.isHiddenOrHasHiddenAncestor)
        precondition(model.selectedStep?.headerEntries[0].operation == .add)
        precondition(model.selectedStep?.headerEntries[1].value == original)
        operations[1].selectItem(at: 0); operations[1].onChange(0); inspector.refresh()
        precondition(!area.isHiddenOrHasHiddenAncestor && area.string == original)
        operations[1].selectItem(at: 1); operations[1].onChange(1); inspector.refresh()
        precondition(model.selectedStep?.headerEntries[1].operation == .modify && !area.isHiddenOrHasHiddenAncestor)
        precondition(model.selectedStep?.headerEntries[1].value == original)
        let removeHeader = descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "删除 Header" }!
        removeHeader.performClick(nil); inspector.refresh()
        precondition(model.selectedStep?.headerEntries.count == 1 && model.selectedStep?.headerEntries[0].name == "X-Token")
        for _ in 0..<10 { button("Header 修改").performClick(nil); inspector.refresh() }
        window.contentView?.layoutSubtreeIfNeeded()
        let scrolling = descendants(inspector.view).compactMap { $0 as? NSScrollView }.first { !($0 is RulesTextArea) }!
        precondition(scrolling.documentView!.frame.height > scrolling.contentSize.height, "Many Header rows must scroll without growing the inspector")
        let editors = descendants(inspector.view).compactMap { $0 as? HeaderNameField }
        precondition(editors.count == 11 && editors.allSatisfy { $0.frame.width > 100 })
        let step = model.selectedStep!
        let remove = button("删除")
        precondition(remove.contentTintColor == .systemRed)
        remove.performClick(nil)
        precondition(model.selectedStep?.id == step.id, "Opening confirmation must not delete")
        let cancel = descendants(inspector.deletion.contentViewController!.view).compactMap { $0 as? NSButton }.first { $0.title == "取消" }!
        cancel.performClick(nil)
        precondition(model.selectedStep?.id == step.id)
        remove.performClick(nil)
        let confirm = descendants(inspector.deletion.contentViewController!.view).compactMap { $0 as? NSButton }.first { $0.title == "删除步骤" }!
        model.selectedStepID = model.workflow?.requestSteps.last?.id; inspector.refresh()
        confirm.performClick(nil)
        precondition(model.workflow?.requestSteps.contains { $0.id == step.id } == true, "An old confirmation cannot delete a newly selected step")
        model.selectedStepID = step.id; inspector.refresh(); button("删除").performClick(nil)
        descendants(inspector.deletion.contentViewController!.view).compactMap { $0 as? NSButton }.first { $0.title == "删除步骤" }!.performClick(nil)
        inspector.refresh()
        precondition(model.selectedStepID == nil && model.workflow?.requestSteps.contains { $0.id == step.id } == false)
    }

    static func checkRemovalHeaderEditing() {
        let model = WorkspaceModel(); model.addProject(); model.addStep(.removeHeader, response: false)
        var workflow = model.workflow!; workflow.requestSteps[0].name = "X-Legacy"; model.updateWorkflow(workflow)
        let inspector = StepInspectorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 440), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = inspector; inspector.refresh()
        window.setContentSize(NSSize(width: 400, height: 440))
        defer { window.close() }
        func settle() {
            for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func button(_ title: String) -> NSButton { descendants(inspector.view).compactMap { $0 as? ActionButton }.first { $0.title == title }! }
        func scroll() -> NSScrollView { descendants(inspector.view).compactMap { $0 as? NSScrollView }.first! }
        settle()
        precondition(descendants(inspector.view).compactMap { $0 as? RulesTextArea }.allSatisfy(\.isHiddenOrHasHiddenAncestor), "Removal edits names only")
        let legacyField = descendants(inspector.view).compactMap { $0 as? HeaderNameField }.first!
        precondition(legacyField.stringValue == "X-Legacy")
        let firstBox = descendants(inspector.view).compactMap { $0 as? NSBox }.first { $0.identifier?.rawValue == "rules.headerEntry" }!
        precondition(firstBox.frame.height >= legacyField.frame.height + 28, "A name-only box must enclose its control and padding")
        precondition(scroll().contentView.bounds.contains(legacyField.convert(legacyField.bounds, to: scroll().contentView)), "A short form must start fully visible: clip=\(scroll().contentView.bounds), field=\(legacyField.convert(legacyField.bounds, to: scroll().contentView)), doc=\(scroll().documentView!.frame), scroll=\(scroll().frame)")
        button("Header 修改").performClick(nil); inspector.refresh(); settle()
        let fields = descendants(inspector.view).compactMap { $0 as? HeaderNameField }
        fields[1].stringValue = "Host"; fields[1].controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields[1])); inspector.refresh(); settle()
        precondition(model.selectedStep?.headerEntries.map(\.name) == ["X-Legacy", "Host"])
        precondition(descendants(inspector.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("此 Header 由代理维护") && !$0.isHiddenOrHasHiddenAncestor })
        for _ in 0..<10 { button("Header 修改").performClick(nil); inspector.refresh() }; settle()
        let scrolling = scroll(), document = scrolling.documentView!
        precondition(document.frame.height > scrolling.contentSize.height)
        for style in [NSScroller.Style.overlay, .legacy] {
            scrolling.scrollerStyle = style; settle()
            let scrollFrame = scrolling.convert(scrolling.bounds, to: inspector.view)
            precondition(abs(scrollFrame.maxX - inspector.view.bounds.maxX) < 1, "The form scroller reaches the inspector's outer edge")
            let box = descendants(inspector.view).first { $0.identifier?.rawValue == "rules.headerEntry" }!
            let boxFrame = box.convert(box.bounds, to: inspector.view)
            precondition(scrollFrame.maxX - boxFrame.maxX >= 20, "Header fields keep their gutter inside the scroll region")
        }
        let allFields = descendants(inspector.view).compactMap { $0 as? HeaderNameField }
        precondition(allFields.count == 12 && allFields.allSatisfy { $0.frame.width > 100 })
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY)); settle()
        let add = button("Header 修改"), remove = button("删除")
        let footer = descendants(inspector.view).first { $0.identifier?.rawValue == "rules.stepFooter" }!
        precondition(add.isDescendant(of: footer) && remove.isDescendant(of: footer) && !add.isDescendant(of: scrolling), "Header addition stays in the fixed footer")
        precondition(add.convert(add.bounds, to: footer).maxX < remove.convert(remove.bounds, to: footer).minX, "Footer actions occupy opposite sides")
        if #available(macOS 26.0, *) { precondition(add.bezelStyle == .glass && remove.bezelStyle == .glass) }
        for _ in 0..<12 {
            descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "删除 Header" }!.performClick(nil)
            inspector.refresh()
        }
        settle(); precondition(model.selectedStep?.headerEntries.isEmpty == true)
        button("Header 修改").performClick(nil); inspector.refresh(); settle()
        precondition(model.selectedStep?.headerEntries.count == 1)
        let newField = descendants(inspector.view).compactMap { $0 as? HeaderNameField }.first!
        precondition(scroll().contentView.bounds.contains(newField.convert(newField.bounds, to: scroll().contentView)), "Returning to a short form must restore a visible first row")
    }

    static func checkMatchFieldScrolling() {
        let model = WorkspaceModel(); model.addProject()
        var workflow = model.workflow!
        let value = "https://example.test/" + String(repeating: "long-path/", count: 30)
        workflow.matchConditions.conditions = [.init(field: .url, operation: .contains, value: value), .init(field: .header, operation: .equals, name: "X-Route", value: value)]
        model.updateWorkflow(workflow)
        let controller = FlowEditorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.close() }
        controller.refresh()
        let fields = descendants(controller.view).compactMap { $0 as? ActionTextField }.filter {
            ["匹配值", "Header 匹配值"].contains($0.accessibilityLabel() ?? "")
        }
        precondition(fields.count == 2)
        for field in fields {
            window.makeFirstResponder(field)
            let editor = field.currentEditor() as! NSTextView
            editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            for width: CGFloat in [900, 420, 680, 420] {
                window.setContentSize(NSSize(width: width, height: 900))
                for _ in 0..<3 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                editor.scrollRangeToVisible(editor.selectedRange())
                let layout = editor.layoutManager!
                layout.ensureLayout(for: editor.textContainer!)
                var lineCount = 0
                layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in lineCount += 1 }
                precondition(lineCount == 1, "Long matching values must remain on one line during resizing")
                precondition(editor.isHorizontallyResizable && !editor.textContainer!.widthTracksTextView,
                             "The native field editor must allow horizontal scrolling instead of wrapping")
                precondition(field.currentEditor() === editor && editor.string == value)
            }
            editor.insertText("x", replacementRange: editor.selectedRange())
            precondition(field.stringValue == value + "x")
            precondition(model.workflow!.matchConditions.conditions.contains { $0.value == value + "x" })
            window.makeFirstResponder(nil)
        }
    }

    static func checkStepActivation() {
        let model = WorkspaceModel(); model.addProject()
        model.addStep(.setHeader, response: false); model.addStep(.replaceBody, response: true)
        let flow = FlowEditorViewController(model: model)
        _ = flow.view; flow.refresh()
        let receiver = StepInspectorReceiver(); flow.nextResponder = receiver
        let tables = descendants(flow.view).compactMap { $0 as? NSTableView }
        precondition(tables.count == 2)
        for table in tables {
            precondition(table.action != nil && table.target != nil)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let selected = model.selectedStepID
            for _ in 0..<2 {
                let count = receiver.count
                precondition(table.sendAction(table.action, to: table.target))
                precondition(receiver.count == count + 1 && model.selectedStepID == selected,
                             "Every row activation must request its inspector, including unchanged selection")
            }
            let count = receiver.count
            flow.refresh()
            precondition(receiver.count == count, "Programmatic refresh must not reopen a collapsed inspector")
            table.deselectAll(nil)
            _ = table.sendAction(table.action, to: table.target)
            precondition(receiver.count == count, "An empty selection must not request an inspector")
        }
    }

    static func checkTemplateCaret() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let area = RulesTextArea(template: true)
        window.contentView = area
        defer { window.close() }
        let text = area.textView
        let layout = text.layoutManager as! TemplateLayoutManager
        func caret(_ index: Int) -> NSRect {
            text.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
        }
        for prefix in ["pre", "普通文字", "e\u{301}", "👨‍👩‍👧‍👦", "pre "] {
            area.string = prefix + "post"
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            window.contentView?.layoutSubtreeIfNeeded()
            let boundary = (prefix as NSString).length
            let ordinaryCaret = caret(boundary)
            area.string = prefix + "{{$env.api}}post"
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let tokenCaret = caret(boundary)
            precondition(abs(tokenCaret.minX - ordinaryCaret.minX) < 0.01,
                         "The caret must stay at the ordinary text advance, excluding decoration padding: \(prefix) \(ordinaryCaret) \(tokenCaret)")
            let local = text.convert(window.convertFromScreen(tokenCaret), from: nil)
            let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: boundary), effectiveRange: nil)
            precondition(line.height >= 24 && tokenCaret.height <= ceil(text.font!.ascender - text.font!.descender),
                         "The caret must use the font height while preserving the padded line height")
            precondition(abs(local.midY - (line.midY + text.textContainerOrigin.y)) < 0.01,
                         "The shorter caret must remain vertically centered in its line")
            for offset: CGFloat in [0, 2, 6] {
                precondition(text.characterIndexForInsertion(at: NSPoint(x: local.minX + offset, y: local.midY)) == boundary,
                             "Clicks at the caret or in the decorative gap must insert before the token")
            }
            window.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: boundary, length: 0))
            text.moveRight(nil)
            precondition(text.selectedRange().location == boundary + 1)
            text.moveLeft(nil)
            text.insertText("x", replacementRange: text.selectedRange())
            precondition(area.string == prefix + "x{{$env.api}}post")
            precondition(text.selectedRange().location == boundary + 1)
        }
        area.string = "{{$uuid}}{{$env.api}}\n{{$timestamp}}"
        for token in layout.tokenRanges { precondition(layout.leadingPadding(at: token.location) == 0) }
        area.string = "12345678{{$uuid}}"
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainer!.widthTracksTextView = false
        // Keep a 70 pt usable line width after removing the former 5 pt padding on each side.
        text.textContainer!.containerSize = NSSize(width: 70, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: text.textContainer!)
        let token = layout.tokenRanges[0]
        let before = layout.glyphIndexForCharacter(at: token.location - 1)
        let after = layout.glyphIndexForCharacter(at: token.location)
        precondition(layout.lineFragmentRect(forGlyphAt: before, effectiveRange: nil).minY != layout.lineFragmentRect(forGlyphAt: after, effectiveRange: nil).minY)
        precondition(layout.leadingPadding(at: token.location) == 0, "Wrapped line starts must retain their native caret")
        area.string = "pre{{$env.api}}"
        text.textContainer!.widthTracksTextView = true
        text.textContainer!.containerSize = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)
        window.contentView?.layoutSubtreeIfNeeded()
        text.setSelectedRange(NSRange(location: 3, length: 0))
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 3, length: 0))
        precondition(text.hasMarkedText() && area.string == "pre拼{{$env.api}}")
        text.insertText("拼音", replacementRange: text.markedRange())
        precondition(!text.hasMarkedText() && area.string == "pre拼音{{$env.api}}")
    }

    static func checkTemplateValues() {
        var copied: String?
        let controller = TemplateValuesViewController(response: true, environment: [NamedValue(name: "api", value: "secret")]) { copied = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        precondition(controller.rows.map(\.template).contains("{{$env.api}}"))
        precondition(controller.rows.map(\.template).contains("{{$response.status}}"))
        precondition(controller.rows.allSatisfy { $0.frame.height >= 22 })
        let row = controller.rows[0]
        row.setHovered(true); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(row.copyButton.alphaValue == 1)
        row.copyButton.performClick(nil); precondition(copied == row.template)
        row.setHovered(false); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(row.copyButton.alphaValue == 0)
        precondition(window.makeFirstResponder(row.copyButton))
        precondition(row.copyButton.hasKeyboardFocus && row.copyButton.alphaValue == 1)
        let request = TemplateValuesViewController(response: false, environment: [])
        precondition(!request.rows.map(\.template).contains("{{$response.status}}"))
    }

    static func checkDelayEditing() {
        let model = WorkspaceModel(); model.addProject(); model.addStep(.delay, response: true)
        let inspector = StepInspectorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = inspector; inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded()
        let field = descendants(inspector.view).compactMap { $0 as? ActionTextField }.first { $0.accessibilityLabel() == "延迟时间（ms）" }!
        let error = descendants(inspector.view).first { $0.identifier?.rawValue == "rules.delayError" }!
        precondition(field.stringValue == "1000" && error.isHidden)
        for value in ["250", "-1", "0"] {
            field.stringValue = value; field.onChange(value); inspector.refresh()
            precondition(model.selectedStep?.value == value && field.stringValue == value)
            precondition(error.isHidden == (value != "-1"))
        }
        precondition(descendants(inspector.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "ms" })
        let data = try! JSONEncoder().encode(model.document)
        let saved = try! JSONDecoder().decode(WorkspaceDocument.self, from: data)
        precondition(saved.projects[0].workflows[0].responseSteps[0].value == "0")
    }

    static func checkScriptEditing() {
        let code = "// const 123 😀\nconst data = JSON.parse(response.body);\n/* return true */\ndata.name = `中文😀`;\ndata.enabled = true;\ndata.count = 0xff + 1_000 + 2.5e2;\nresponse.body = JSON.stringify(data);\nreturn response;\n"
        var step = ModificationStep(kind: .script); step.value = code
        var saved = step
        let editor = ScriptEditorViewController(step: step, response: true, environment: [:]) { saved = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = editor
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        let area = descendants(editor.view).compactMap { $0 as? CodeEditorView }.first!
        let text = area.textView
        settleEditor(area)
        precondition(text.layoutManager.lineCount == 9)
        func color(_ fragment: String) -> NSColor? {
            let range = (text.string as NSString).range(of: fragment)
            return text.textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        precondition(color("// const") != color("const data") && color("true;") != color("0xff"))
        precondition(text.string == code, "Highlighting must preserve source")
        window.makeFirstResponder(text)
        text.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        text.insertText("let changed = 42;\n", replacementRange: text.selectedRange())
        precondition(saved.value == text.string && text.layoutManager.lineCount == 10)
        text.undoManager?.undo()
        precondition(saved.value == code && text.string == code && text.layoutManager.lineCount == 9)
        text.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: text.selectedRange())
        precondition(text.hasMarkedText())
        text.insertText("拼音", replacementRange: text.markedRange())
        precondition(text.string.hasPrefix("拼音") && saved.value == text.string)
        for (value, lineCount) in [("", 1), ("\n", 2), ("const text = 'unterminated", 1), ("/* open\ncomment", 2), ("const s = `a\\`b`;", 1), ("// comment\r\nreturn request;\r\n", 3), ("const long = '" + String(repeating: "中文😀", count: 160) + "';\n", 2)] {
            area.string = value; window.contentView?.layoutSubtreeIfNeeded()
            precondition(area.string == value && text.layoutManager.lineCount == lineCount)
            text.scrollToRange(NSRange(location: (value as NSString).length, length: 0))
            let bitmap = area.bitmapImageRepForCachingDisplay(in: area.bounds)!
            area.cacheDisplay(in: area.bounds, to: bitmap)
        }
    }

    static func checkScriptTrial() {
        checkScriptEditing()
        func waitForResult(_ button: NSButton) {
            let deadline = Date().addingTimeInterval(5)
            while !button.isEnabled && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(button.isEnabled, "The trial must finish without blocking the UI")
        }
        for response in [false, true] {
            var step = ModificationStep(kind: .script)
            step.value = response ? "response.body = env.marker + request.method; return response;"
                                  : "request.body = env.marker + request.method; return request;"
            var saved = ScriptPreviewInput()
            let editor = ScriptEditorViewController(step: step, response: response, environment: [:]) { _ in }
            precondition(!descendants(editor.view).compactMap { $0 as? NSButton }.contains { $0.title == "示例输入…" })
            precondition(descendants(editor.view).compactMap { $0 as? CodeEditorView }.count == 1)
            let controller = ScriptPreviewInputViewController(input: saved, response: response, step: step, environment: ["marker": "trial-"]) { saved = $0 }
            let window = ScriptFocusCheckWindow(contentViewController: controller); window.isReleasedWhenClosed = false
            window.contentView?.layoutSubtreeIfNeeded()
            let controls = descendants(controller.view)
            let run = controls.compactMap { $0 as? NSButton }.first { $0.title == "运行" }!
            let result = controls.compactMap { $0 as? RulesTextArea }.first { $0.textView.accessibilityLabel() == "脚本运行结果" }!
            let headers = controls.compactMap { $0 as? RulesTextArea }.first { $0.textView.accessibilityLabel() == "请求 Header 数组（JSON）" }!
            let inputScroll = controls.compactMap { $0 as? NSScrollView }.first { !($0 is RulesTextArea) }!
            let focusRect = headers.convert(headers.bounds.insetBy(dx: -4, dy: -4), to: inputScroll.contentView)
            precondition(inputScroll.contentView.bounds.contains(focusRect), "The outer viewport must include the complete focus ring, including its left edge")
            window.makeFirstResponder(nil)
            precondition(window.makeFirstResponder(headers.textView))
            precondition(window.firstResponder === headers.textView)
            window.makeFirstResponder(nil)
            precondition(window.firstResponder !== headers.textView)
            precondition(controller.view.bounds.size == NSSize(width: 900, height: 620))
            precondition(result.bounds.width > 380 && result.bounds.height > 400, "Unexpected result viewport: \(result.bounds)")
            let inputRect = headers.convert(headers.bounds, to: controller.view)
            let outputRect = result.convert(result.bounds, to: controller.view)
            precondition(inputRect.maxX < outputRect.minX, "Inputs and results must remain side by side")
            let divider = controls.compactMap { $0 as? NSBox }.first { $0.boxType == .separator }!
            func checkColumnSpacing() {
                let left = headers.convert(headers.bounds, to: controller.view)
                let right = result.convert(result.bounds, to: controller.view)
                // NSBox adds 2 pt on each side of its separator's alignment rectangle.
                let middle = divider.superview!.convert(divider.alignmentRect(forFrame: divider.frame), to: controller.view)
                precondition(abs(left.width - right.width) < 1, "Input and output editors must have equal visible widths")
                precondition(abs(middle.minX - left.maxX - 24) < 1 && abs(right.minX - middle.maxX - 24) < 1,
                             "Expected symmetric divider gaps: left=\(left), divider=\(middle), right=\(right)")
            }
            checkColumnSpacing()
            if response {
                let scroll = controls.compactMap { $0 as? NSScrollView }.first { !($0 is RulesTextArea) }!
                for style in [NSScroller.Style.overlay, .legacy] {
                    scroll.scrollerStyle = style
                    window.contentView?.layoutSubtreeIfNeeded()
                    checkColumnSpacing()
                    let scroller = scroll.verticalScroller!
                    let gutter = scroller.convert(scroller.bounds, to: scroll)
                    let dividerRect = divider.superview!.convert(divider.alignmentRect(forFrame: divider.frame), to: scroll)
                    precondition(gutter.maxX <= dividerRect.minX + 1, "The scrollbar must stay inside the input-side gutter")
                    for field in descendants(scroll.documentView!) where field is ActionTextField || field is RulesTextArea {
                        let rect = field.convert(field.bounds, to: scroll)
                        precondition(rect.maxX <= gutter.minX - 7, "Either system scrollbar style must leave input controls unobstructed")
                    }
                }
                let document = scroll.documentView!
                let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                window.contentView?.layoutSubtreeIfNeeded()
                let body = controls.compactMap { $0 as? RulesTextArea }.first { $0.textView.accessibilityLabel() == "响应 Body（文本）" }!
                let bodyRect = body.convert(body.bounds, to: scroll.contentView)
                precondition(scroll.contentView.bounds.contains(bodyRect), "The last input must be fully reachable after scrolling")
                scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            }
            checkInputFocusVisibility(controller.view, window: window)
            precondition(result.string.contains("点击“运行”"), "Opening the dialog must not run the script")
            run.performClick(nil); waitForResult(run)
            precondition(result.string.contains("trial-GET"), "Both phases must use the configured script and environment")
            headers.string = "invalid"; headers.onChange(headers.string)
            precondition(result.string == "输入已更改，请重新运行。" && saved.requestHeaders == "invalid")
            run.performClick(nil); waitForResult(run)
            precondition(result.string.hasPrefix("执行失败："))
            headers.string = "[]"; headers.onChange(headers.string)
            run.performClick(nil); waitForResult(run)
            precondition(result.string.contains("trial-GET"), "The user must be able to fix input and run again")
            run.performClick(nil)
            headers.string = "[ ]"; headers.onChange(headers.string)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            precondition(result.string == "输入已更改，请重新运行。", "Cancelled output must not replace the changed-input message")
            run.performClick(nil); controller.viewWillDisappear()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            precondition(result.string == "正在运行…", "Closing must invalidate the pending result")
            window.close()
        }
    }

    static func checkInputFocusVisibility(_ root: NSView, window: NSWindow) {
        let scroll = descendants(root).compactMap { $0 as? NSScrollView }.first { !($0 is RulesTextArea) }!
        let areas = descendants(scroll.documentView!).compactMap { $0 as? RulesTextArea }
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            root.layoutSubtreeIfNeeded()
            for area in areas.reversed() {
                window.makeFirstResponder(nil)
                // Start with the editor against a viewport edge, as when clicking a partially visible field.
                let rect = area.convert(area.bounds, to: scroll.documentView!)
                let bottom = max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height)
                let offset = min(bottom, max(0, rect.maxY - scroll.contentView.bounds.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                precondition(window.makeFirstResponder(area.textView))
                root.layoutSubtreeIfNeeded()
                let focusRect = area.convert(area.bounds.insetBy(dx: -4, dy: -4), to: scroll.contentView)
                precondition(scroll.contentView.bounds.contains(focusRect),
                             "Focused input and its complete ring must be visible: \(area.textView.accessibilityLabel() ?? ""), rect=\(focusRect), viewport=\(scroll.contentView.bounds)")
            }
        }
        window.makeFirstResponder(nil)
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func checkScriptPresentation() {
        checkScriptTrial()
        let model = WorkspaceModel(); model.addProject(); model.addStep(.script, response: false)
        let inspector = StepInspectorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = inspector
        defer { window.close() }
        inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded()
        func snapshot(_ view: NSView, _ name: String) {
            guard let directory = ProcessInfo.processInfo.environment["REQUESTMAN_SCRIPT_SNAPSHOTS"],
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        snapshot(inspector.view, "script")
        let note = descendants(inspector.view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "步骤备注" }!
        let remove = descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == "删除" }!
        func pixels(_ view: NSView, matching predicate: (NSColor) -> Bool) -> Int {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { return false }
                    return color.alphaComponent > 0.9 && predicate(color)
                }.count
            }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            snapshot(note, "note-\(appearance.rawValue)")
            let whitePixels = pixels(note) { $0.redComponent > 0.95 && $0.greenComponent > 0.95 && $0.blueComponent > 0.95 }
            precondition(whitePixels > 1000,
                         "The note field must actually render a white background in either appearance")
            precondition(pixels(remove) { $0.redComponent > 0.7 && $0.greenComponent < 0.5 && $0.blueComponent < 0.5 } > 40,
                         "The shared step deletion button must actually render red content")
        }
        var sample = ScriptPreviewInput()
        sample.url += "?query=" + String(repeating: "long-value", count: 50)
        for response in [false, true] {
            let input = ScriptPreviewInputViewController(input: sample, response: response) { _ in }
            let sheet = ScriptFocusCheckWindow(contentViewController: input); sheet.isReleasedWhenClosed = false
            sheet.contentView?.layoutSubtreeIfNeeded()
            print("Input response=\(response): frame=\(input.view.frame), fitting=\(input.view.fittingSize)")
            snapshot(input.view, response ? "input-response" : "input-request")
            precondition(abs(input.view.bounds.width - 600) < 1 && abs(input.view.bounds.height - 540) < 1,
                         "Sample sheets must retain their intended size with long input")
            let scroll = descendants(input.view).compactMap { $0 as? NSScrollView }.first { !($0 is RulesTextArea) }!
            precondition(scroll.contentView.bounds.height > 300)
            let document = scroll.documentView!
            precondition(abs(document.frame.width - scroll.contentView.bounds.width) < 1 && abs(document.frame.minX) < 1)
            for area in descendants(input.view).compactMap({ $0 as? RulesTextArea }) {
                precondition(area.bounds.height >= 64 && area.bounds.width > 500)
            }
            checkInputFocusVisibility(input.view, window: sheet)
            sheet.close()
        }
        let preview = WorkflowPreviewViewController(workflow: model.workflow!, environment: nil)
        let sheet = NSWindow(contentViewController: preview); sheet.isReleasedWhenClosed = false
        sheet.contentView?.layoutSubtreeIfNeeded()
        print("Preview: frame=\(preview.view.frame), fitting=\(preview.view.fittingSize)")
        snapshot(preview.view, "preview")
        precondition(abs(preview.view.bounds.width - 680) < 1 && abs(preview.view.bounds.height - 500) < 1)
        let result = descendants(preview.view).compactMap { $0 as? RulesTextArea }.first!
        precondition(result.bounds.height > 300 && result.bounds.width > 600)
        sheet.close()
    }

    static func checkMatchTesting() {
        var workflow = RequestWorkflow(name: "订单接口")
        workflow.matchConditions.conditions = [.init(field: .url, operation: .regex, value: "/v1/orders/[0-9]+$"), .init(field: .header, operation: .equals, name: "X-Environment", value: "staging")]
        let controller = WorkflowMatchTestViewController(workflow: workflow)
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: .aqua)
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        func field(_ id: String) -> NSTextField { descendants(controller.view).first { $0.identifier?.rawValue == id } as! NSTextField }
        let url = field("matchTest.url") as! ActionTextField
        let header = field("matchTest.headerValue") as! ActionTextField
        let run = descendants(controller.view).first { $0.identifier?.rawValue == "matchTest.run" } as! ActionButton
        let status = field("matchTest.status")
        let initialHeight = controller.view.bounds.height
        let done = descendants(controller.view).first { $0.identifier?.rawValue == "matchTest.done" } as! NSButton
        if #available(macOS 26.0, *) { precondition(done.bezelStyle == .glass && done.borderShape == .capsule) }
        precondition(!run.isEnabled)
        url.stringValue = "https://api.example.com/v1/orders/123"; url.onChange(url.stringValue)
        header.stringValue = "production"; header.onChange(header.stringValue)
        func runTest() {
            run.performClick(nil)
            let deadline = Date().addingTimeInterval(3)
            while run.title == "测试中…" && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(run.title == "测试")
            window.contentView?.layoutSubtreeIfNeeded()
        }
        runTest()
        precondition(status.stringValue.hasPrefix("未匹配"))
        precondition(controller.view.bounds.height > initialHeight, "Results expand the sheet to fit content")
        let details = descendants(controller.view).compactMap { $0 as? NSTextField }
        precondition(details.contains { $0.stringValue.contains("实际：production") })
        let headerDetail = details.first { $0.stringValue.contains("实际：production") }!
        precondition(descendants(controller.view).contains { $0.identifier?.rawValue == "matchTest.scroll" }, "Long diagnostics must remain reachable in a native scroll view")
        let detailRect = headerDetail.convert(headerDetail.bounds, to: controller.view)
        precondition(controller.view.bounds.contains(detailRect), "Default result must be fully visible")
        precondition(url.bounds.width > 400 && header.bounds.width > 150)
        if let directory = ProcessInfo.processInfo.environment["REQUESTMAN_MATCH_SNAPSHOTS"],
           let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("match-test.png"))
        }
        header.stringValue = "staging"; header.onChange(header.stringValue)
        precondition(abs(controller.view.bounds.height - initialHeight) < 2, "Clearing results removes their unused space")
        precondition(!status.stringValue.hasPrefix("未匹配"), "Editing clears stale results")
        url.selectText(nil)
        let editor = url.currentEditor() as! NSTextView
        editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        precondition(!url.control(url, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                     "Return confirms marked text without starting a test")
        editor.unmarkText()
        editor.string = "https://api.example.com/v1/orders/123"
        precondition(url.control(url, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        let returnDeadline = Date().addingTimeInterval(3)
        while run.title == "测试中…" && Date() < returnDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(status.stringValue.hasPrefix("匹配成功"), "Return in the URL field commits its latest text and runs matching")
        // Editing while a result is in flight must not restore an obsolete result.
        run.performClick(nil)
        url.stringValue = "bad URL"; url.onChange(url.stringValue)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(status.stringValue.contains("输入示例请求"))
        runTest(); precondition(status.stringValue.hasPrefix("无法测试"))
        workflow.matchConditions.conditions[0].value = "["
        let invalid = WorkflowMatchTestViewController(workflow: workflow)
        _ = invalid.view
        let invalidRun = descendants(invalid.view).first { $0.identifier?.rawValue == "matchTest.run" } as! NSButton
        precondition(!invalidRun.isEnabled)
        precondition(descendants(invalid.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("正则表达式无效") })
        var simpleWorkflow = workflow
        simpleWorkflow.matchConditions.conditions.removeLast(); simpleWorkflow.matchConditions.conditions[0].value = "/v1/orders/[0-9]+$"
        let simple = WorkflowMatchTestViewController(workflow: simpleWorkflow)
        let simpleWindow = NSWindow(contentViewController: simple); simpleWindow.isReleasedWhenClosed = false
        simpleWindow.contentView?.layoutSubtreeIfNeeded()
        let simpleURL = descendants(simple.view).first { $0.identifier?.rawValue == "matchTest.url" } as! ActionTextField
        simpleURL.stringValue = "https://api.example.com/v1/orders/123"; simpleURL.onChange(simpleURL.stringValue)
        let simpleRun = descendants(simple.view).first { $0.identifier?.rawValue == "matchTest.run" } as! NSButton
        simpleRun.performClick(nil)
        let deadline = Date().addingTimeInterval(3)
        while simpleRun.title == "测试中…" && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(descendants(simple.view).contains { $0.identifier?.rawValue == "matchTest.scroll" })
        precondition(simple.view.bounds.height < 600, "No-Header result must not retain the fixed 700 pt height")
        let simpleStack = simple.view.subviews.first as! NSStackView
        precondition(abs(simple.view.bounds.height - simpleStack.fittingSize.height - 44) < 3,
                     "No large empty region below the results")
        print("Match sheet heights: initial Header=\(initialHeight), no-Header result=\(simple.view.bounds.height)")
        simpleWindow.close()
        let model = WorkspaceModel(); model.addProject()
        let flow = FlowEditorViewController(model: model)
        let host = NSWindow(contentViewController: flow); host.isReleasedWhenClosed = false
        host.contentView?.layoutSubtreeIfNeeded()
        let button = descendants(flow.view).first { $0.identifier?.rawValue == "rules.testMatch" }!
        precondition(button.isDescendant(of: descendants(flow.view).first { $0.identifier?.rawValue == "rules.matching" }!))
        (button as! NSButton).performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let sheet = flow.presentedViewControllers?.first as? WorkflowMatchTestViewController
        precondition(sheet != nil, "Test button must present the native match sheet")
        sheet?.dismiss(nil)
        host.close()
        print("Match testing: native layout, success, Header mismatch, invalid pattern/input and stale-result checks passed")
    }

    static func checkFlowPresentation() {
        let model = WorkspaceModel(); model.addProject()
        var workflow = model.workflow!
        workflow.requestSteps = [ModificationStep(kind: .setHeader), ModificationStep(kind: .replaceBody)]
        workflow.requestSteps[1].enabled = false
        workflow.responseSteps = [ModificationStep(kind: .setStatus)]
        model.updateWorkflow(workflow); model.selectedStepID = workflow.requestSteps[1].id
        let controller = FlowEditorViewController(model: model)
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 720))
        controller.view.wantsLayer = true
        defer { window.close() }
        func settle() {
            controller.refresh()
            for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        settle()
        precondition(!descendants(controller.view).contains { $0.identifier?.rawValue == "rules.isSSE" })
        let toggle = descendants(controller.view).first { $0.identifier?.rawValue == "rules.enabled" } as! RulesSwitch
        let label = descendants(controller.view).first { $0.identifier?.rawValue == "rules.enabledLabel" } as! NSTextField
        precondition(label.stringValue == "已启用")
        toggle.state = .off; toggle.onChange(false); settle()
        precondition(model.workflow?.enabled == false && label.stringValue == "已关闭")
        toggle.state = .on; toggle.onChange(true); settle()
        precondition(label.stringValue == "已启用" && model.workflow?.responseSteps == workflow.responseSteps)
        let table = descendants(controller.view).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 2 }!
        let cell = table.view(atColumn: 0, row: 1, makeIfNecessary: true)!
        let pause = descendants(cell).first { $0.identifier?.rawValue == "rules.stepPaused" }!
        let pauseFrame = pause.convert(pause.bounds, to: cell)
        precondition(abs(cell.bounds.maxX - pauseFrame.maxX - 12) < 1 && pauseFrame.width == 24,
                     "Disabled step indicator stays enlarged and pinned to the trailing edge")
        precondition(table.selectedRow == 1)
        let badge = descendants(cell).first { $0.identifier?.rawValue == "rules.stepBadge" }!
        precondition(badge.bounds.width == 28, "The step number badge must not stretch into the text area")
        func checkStepAlignment() {
            for lane in descendants(controller.view).filter({ $0.identifier?.rawValue == "rules.laneBorder" }) {
                let separator = descendants(lane).first { $0.identifier?.rawValue == "rules.laneSeparator" }!
                let left = separator.convert(separator.bounds, to: lane).minX
                for badge in descendants(lane).filter({ $0.identifier?.rawValue == "rules.stepBadge" }) {
                    precondition(abs(badge.convert(badge.bounds, to: lane).minX - left) < 0.5,
                                 "Selected and unselected step badges align with the phase separator")
                }
                let table = descendants(lane).compactMap { $0 as? NSTableView }.first!
                guard table.selectedRow >= 0, let row = table.rowView(atRow: table.selectedRow, makeIfNecessary: true) else { continue }
                let bitmap = lane.bitmapImageRepForCachingDisplay(in: lane.bounds)!
                lane.cacheDisplay(in: lane.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / lane.bounds.width
                let rowCenter = row.convert(NSPoint(x: 0, y: row.bounds.midY), to: lane).y
                let y = Int((lane.isFlipped ? rowCenter : lane.bounds.height - rowCenter) * scale)
                let bluePixels = (0..<bitmap.pixelsWide).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { return false }
                    return color.blueComponent > color.redComponent + 0.15 && color.blueComponent > color.greenComponent + 0.05
                }
                guard let first = bluePixels.first, let last = bluePixels.last else { preconditionFailure("Selection outline must render") }
                let leftGap = (CGFloat(first) + 0.5) / scale
                let rightGap = lane.bounds.width - (CGFloat(last) + 0.5) / scale
                precondition(abs(leftGap - left / 2) <= 0.75, "Selection outline sits halfway between the outer border and badge")
                precondition(abs(leftGap - rightGap) <= 0.75, "Selection outline has equal outer margins")
            }
        }
        checkStepAlignment()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance); settle()
            window.appearance!.performAsCurrentDrawingAppearance {
                controller.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            if let directory = ProcessInfo.processInfo.environment["REQUESTMAN_FLOW_SNAPSHOTS"],
               let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(appearance.rawValue + ".png"))
            }
        }
        let add = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "rules.addStep" }!
        precondition(!(add is NSPopUpButton) && add.image != nil)
        if #available(macOS 26.0, *) { precondition(add.bezelStyle == .glass && add.borderShape == .capsule) }
        let count = model.workflow!.requestSteps.count
        add.menu!.performActionForItem(at: 0); settle()
        precondition(model.workflow!.requestSteps.count == count + 1, "Native add menu still executes its step action")
        window.setContentSize(NSSize(width: 420, height: 720)); settle()
        precondition(window.contentView!.bounds.width == 420)
        checkStepAlignment()
        print("Flow presentation: enabled labels, automatic SSE UI, trailing pause, native add action and narrow layout passed")
    }

    static func checkMatchingPresentation() {
        let model = WorkspaceModel(); model.addProject()
        var workflow = model.workflow!; workflow.name = "订单调试"
        workflow.matchConditions = WorkflowMatchGroup(conditions: [
            .init(field: .method, operation: .oneOf, value: "POST, PUT"),
            .init(field: .path, operation: .beginsWith, value: "/v1/orders/"),
            .init(field: .query, operation: .equals, name: "preview", value: "true"),
            .init(field: .header, operation: .equals, name: "X-Environment", value: "staging"),
            .init(field: .cookie, operation: .exists, name: "debug")], groups: [
                WorkflowMatchGroup(mode: .any, conditions: [
                    .init(field: .host, operation: .equals, value: "api.example.com"),
                    .init(field: .host, operation: .equals, value: "staging.example.com")])])
        var header = ModificationStep(kind: .setHeader); header.headers = [HeaderEntry(name: "X-Debug", value: "true")]
        workflow.requestSteps = [header]; workflow.responseSteps = [ModificationStep(kind: .replaceBody)]
        model.updateWorkflow(workflow)
        let controller = FlowEditorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 950), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1120, height: 950))
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        defer { window.close() }
        func settle() { controller.refresh(); for _ in 0..<4 { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        func button(_ id: String) -> NSButton { descendants(controller.view).first { $0.identifier?.rawValue == id } as! NSButton }
        func snapshot(_ name: String) {
            guard let directory = ProcessInfo.processInfo.environment["REQUESTMAN_MATCHING_SNAPSHOTS"],
                  let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else { return }
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        settle(); snapshot("matching-expanded")
        button("rules.collapseGroup").performClick(nil); settle(); snapshot("matching-group-collapsed")
        button("rules.collapseMatching").performClick(nil); settle(); snapshot("matching-collapsed")
        button("rules.collapseMatching").performClick(nil); button("rules.collapseGroup").performClick(nil); settle()
        let before = model.workflow!.matchConditions
        (descendants(controller.view).last { $0.identifier?.rawValue == "rules.addConditionGroup" } as! NSButton).performClick(nil); settle()
        precondition(model.workflow!.matchConditions.groups.count == before.groups.count + 1)
        let lastGroup = descendants(controller.view).filter { $0.identifier?.rawValue == "rules.conditionGroup" }.last!
        let removeGroup = descendants(lastGroup).compactMap { $0 as? ActionButton }.first { $0.accessibilityLabel() == "移除条件" }!
        removeGroup.performClick(nil); settle()
        precondition(model.workflow!.matchConditions == before)
        let queryRow = descendants(controller.view).filter { $0.identifier?.rawValue == "rules.conditionRow" }[2]
        let operation = queryRow.subviews.compactMap { $0 as? ActionPopUpButton }.first { $0.accessibilityLabel() == "匹配运算符" }!
        operation.selectItem(withTitle: "不存在"); operation.onChange(operation.indexOfSelectedItem); settle()
        let value = queryRow.subviews.compactMap { $0 as? ActionTextField }.first { $0.accessibilityLabel() == "匹配值" }!
        precondition(value.isHidden && model.workflow!.matchConditions.conditions[2].operation == .notExists)
        operation.selectItem(withTitle: "等于"); operation.onChange(operation.indexOfSelectedItem); settle()
        precondition(!value.isHidden && value.stringValue == "true")
        window.setContentSize(NSSize(width: 420, height: 950)); settle(); snapshot("matching-narrow")
        precondition(window.contentView!.bounds.width == 420)
        print("Matching presentation: group add/remove, operator changes, retained values, folding, wide/narrow native layouts passed")
    }

    static func checkJSONEditing() {
        for response in [false, true] {
            let model = WorkspaceModel(); model.addProject(); model.addStep(.modifyJSON, response: response)
            let inspector = StepInspectorViewController(model: model)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = inspector; inspector.refresh()
            defer { window.close() }
            func controls<T: NSView>(_ type: T.Type) -> [T] { descendants(inspector.view).compactMap { $0 as? T } }
            let path = controls(ActionTextField.self).first { $0.accessibilityLabel() == "JSON 路径" }!
            path.stringValue = "items[0].name"; path.onChange(path.stringValue)
            let area = controls(RulesTextArea.self).first!
            area.textView.string = #""张三""#; area.textDidChange(Notification(name: NSText.didChangeNotification))
            inspector.refresh()
            precondition(model.selectedStep?.jsonEntries.first?.path == "items[0].name")
            precondition(model.selectedStep?.jsonEntries.first?.value == #""张三""#)
            let operation = controls(ActionPopUpButton.self).first { $0.accessibilityLabel() == "JSON 修改方法" }!
            precondition(operation.itemTitles == ["添加或覆盖", "修改", "删除"])
            operation.selectItem(at: 2); operation.onChange(2); inspector.refresh()
            precondition(area.isHiddenOrHasHiddenAncestor && model.selectedStep?.jsonEntries.first?.operation == .remove)
            operation.selectItem(at: 1); operation.onChange(1); inspector.refresh()
            precondition(!area.isHiddenOrHasHiddenAncestor && area.string == #""张三""#)
            window.setContentSize(NSSize(width: 440, height: 750))
            for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            let scroll = controls(NSScrollView.self).first { $0.documentView is FlippedView }!
            precondition(scroll.documentView!.frame.height <= scroll.contentSize.height, "One JSON entry should fit without scrolling: document=\(scroll.documentView!.frame) viewport=\(scroll.contentSize) window=\(window.contentView!.frame)")
            controls(ActionButton.self).first { $0.title == "添加 JSON 修改" }!.performClick(nil); inspector.refresh()
            precondition(model.selectedStep?.jsonEntries.count == 2)
            precondition(controls(NSBox.self).filter { $0.identifier?.rawValue == "rules.jsonEntry" }.count == 2)
            controls(ActionButton.self).first { $0.accessibilityLabel() == "删除 JSON 修改" }!.performClick(nil); inspector.refresh()
            precondition(model.selectedStep?.jsonEntries.count == 1 && model.selectedStep?.jsonEntries.first?.path == "")
            for _ in 0..<5 { controls(ActionButton.self).first { $0.title == "添加 JSON 修改" }!.performClick(nil); inspector.refresh() }
            window.contentView?.layoutSubtreeIfNeeded()
            let overflow = controls(NSScrollView.self).first { $0.documentView is FlippedView }!
            precondition(overflow.documentView!.frame.height > overflow.contentSize.height)
            model.loaded = false; inspector.refresh()
            precondition(controls(ActionTextField.self).allSatisfy { !$0.isEnabled })
            precondition(controls(ActionPopUpButton.self).allSatisfy { !$0.isEnabled })
            let flow = FlowEditorViewController(model: model); _ = flow.view; flow.refresh()
            let menus = descendants(flow.view).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == "rules.addStep" }
            precondition(menus.count == 2 && menus.allSatisfy { $0.menu!.items.map(\.title).filter { $0 == "修改 JSON" }.count == 1 })
        }
        print("JSON form passed: both phases, editing, operations, retained values, add/remove, menus and layout")
    }

    static func checkSidebarScrollChrome() {
        guard #available(macOS 26.0, *) else { return }
        let model = WorkspaceModel(); model.addProject()
        let original = model.document.projects[0].workflows[0]
        model.document.projects[0].workflows = (0..<60).map { index in
            var workflow = original; workflow.id = UUID(); workflow.name = "Rule \(index)"; return workflow
        }
        model.selectedWorkflowID = model.document.projects[0].workflows[0].id
        let sidebar = ProjectSidebarViewController(model: model)
        let split = NSSplitViewController()
        let item = NSSplitViewItem(sidebarWithViewController: sidebar)
        item.allowsFullHeightLayout = true
        item.minimumThickness = 260; item.maximumThickness = 400
        split.addSplitViewItem(item)
        split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        sidebar.installBottomAccessory(on: item)
        sidebar.installBottomAccessory(on: item)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "sidebar.scrollCheck"); window.toolbarStyle = .unified
        window.contentViewController = split
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        sidebar.refresh()
        let scroll = sidebar.outline.enclosingScrollView!
        for height: CGFloat in [600, 420] {
            window.setContentSize(NSSize(width: 900, height: height))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            split.view.layoutSubtreeIfNeeded()
            precondition(item.bottomAlignedAccessoryViewControllers.count == 1)
            let accessory = item.bottomAlignedAccessoryViewControllers[0]
            let frame = scroll.convert(scroll.bounds, to: sidebar.view)
            precondition(abs(frame.minY - sidebar.view.bounds.minY) < 1 && abs(frame.maxY - sidebar.view.bounds.maxY) < 1,
                         "The rule tree must fill the sidebar behind both bars")
            precondition(scroll.contentInsets.top > 0 && scroll.contentInsets.bottom >= accessory.view.bounds.height - 1,
                         "Native insets must reserve titlebar and footer: \(scroll.contentInsets), footer=\(accessory.view.bounds)")
            let footerFrame = accessory.view.convert(accessory.view.bounds, to: nil)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
            let first = sidebar.outline.convert(sidebar.outline.rect(ofRow: 0), to: nil)
            precondition(first.maxY <= window.contentLayoutRect.maxY + 1, "First row stays below the titlebar at rest")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
            scroll.reflectScrolledClipView(scroll.contentView)
            precondition(accessory.view.convert(accessory.view.bounds, to: nil) == footerFrame, "Footer stays fixed during scrolling")
            sidebar.outline.scrollRowToVisible(sidebar.outline.numberOfRows - 1)
            let last = sidebar.outline.convert(sidebar.outline.rect(ofRow: sidebar.outline.numberOfRows - 1), to: nil)
            precondition(last.minY >= footerFrame.maxY - 1, "Last row must remain reachable above the footer")
            precondition(sidebar.searchField.isDescendant(of: accessory.view))
        }
        print("Sidebar scroll chrome passed: full-height tree, native top/bottom insets, reachable first/last rows, fixed footer and resizing. Hidden window only.")
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkSidebarScrollChrome()
        if ProcessInfo.processInfo.environment["REQUESTMAN_SIDEBAR_SCROLL_ONLY"] == "1" { return }
        if ProcessInfo.processInfo.environment["REQUESTMAN_SINGLE_LINE_BACKGROUNDS_ONLY"] == "1" { checkSingleLineBackgrounds(); return }
        if ProcessInfo.processInfo.environment["REQUESTMAN_GUTTER_ONLY"] == "1" { checkEmptyGutterRendering(); checkGutterBaselineRendering(); return }
        if ProcessInfo.processInfo.environment["REQUESTMAN_MATCHING_ONLY"] == "1" { checkMatchingPresentation(); return }
        if ProcessInfo.processInfo.environment["REQUESTMAN_FLOW_PRESENTATION_ONLY"] == "1" { checkFlowPresentation(); return }
        checkJSONEditing()
        if ProcessInfo.processInfo.environment["REQUESTMAN_JSON_FORM_ONLY"] == "1" { return }
        checkFlowPresentation()
        if ProcessInfo.processInfo.environment["REQUESTMAN_NUMBERED_EDITORS_ONLY"] == "1" {
            checkNumberedEditorGeometry(); checkCodeEditorBehavior(); checkBodyEditing(); checkScriptEditing(); print("Body and script editing passed"); return
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_STEP_ACCESSORIES_ONLY"] == "1" { checkStepAccessories(); return }
        if ProcessInfo.processInfo.environment["REQUESTMAN_BODY_FILE_ONLY"] == "1" {
            checkBodyEditing()
            print("Body source controls passed: default text, local file mode, path display, retained text and layout in both directions and Mock")
            return
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_HEADER_FORM_ONLY"] == "1" {
            let model = WorkspaceModel(); model.addProject(); model.addStep(.setHeader, response: false)
            model.addStep(.replaceBody, response: false)
            model.selectedStepID = model.workflow?.requestSteps.first?.id
            let inspector = StepInspectorViewController(model: model)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = inspector; inspector.refresh()
            defer { window.close() }
            checkHeaderEditing(inspector, model: model, window: window)
            checkRemovalHeaderEditing()
            model.addStep(.setHeader, response: false)
            var workflow = model.workflow!
            workflow.requestSteps[workflow.requestSteps.count - 1].headerEntries = [HeaderEntry(operation: .set, name: "X-Legacy", value: "old")]
            model.updateWorkflow(workflow); inspector.refresh()
            let legacy = descendants(inspector.view).compactMap { $0 as? ActionPopUpButton }.first { $0.accessibilityLabel() == "Header 修改方法" }!
            precondition(legacy.titleOfSelectedItem == "添加或覆盖")
            precondition(legacy.item(withTitle: "添加或覆盖")?.isEnabled == true && model.selectedStep?.headerEntries.first?.operation == .set)
            legacy.selectItem(at: 1); legacy.onChange(1); inspector.refresh()
            precondition(legacy.itemTitles == ["添加", "修改", "删除", "添加或覆盖"] && legacy.titleOfSelectedItem == "修改")
            precondition(model.selectedStep?.headerEntries.first?.operation == .modify && model.selectedStep?.headerEntries.first?.value == "old")
            legacy.selectItem(at: 3); legacy.onChange(3); inspector.refresh()
            precondition(legacy.titleOfSelectedItem == "添加或覆盖")
            precondition(model.selectedStep?.headerEntries.first?.operation == .set && model.selectedStep?.headerEntries.first?.value == "old")
            let flow = FlowEditorViewController(model: model)
            _ = flow.view; flow.refresh()
            let menus = descendants(flow.view).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == "rules.addStep" }
            precondition(menus.count == 2)
            for menu in menus {
                precondition(menu.menu!.items.map(\.title).filter { $0 == "修改 Header" }.count == 1)
                precondition(!menu.menu!.items.map(\.title).contains("移除 Header") && !menu.menu!.items.map(\.title).contains("添加或覆盖 Header"))
            }
            print("Header form: mixed operations, value retention, legacy editing, menu and layout checks passed")
            return
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_QUERY_FORM_ONLY"] == "1" {
            checkQueryParameterEditing()
            print("Query parameter form: editing, operations, persistence, layout and legacy checks passed")
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_URL_REWRITE_FORM_ONLY"] == "1" {
            try! checkURLRewriteEditing()
            checkURLRewriteSplitWidth()
            print("URL rewrite form: target selection, value editing, persistence, legacy defaults and layout checks passed")
            return
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_URL_REPLACEMENT_FORM_ONLY"] == "1" {
            try! checkURLReplacementEditing()
            print("URL replacement form: multiple blocks, single-line editing, description, persistence and layout checks passed")
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_QUERY_FORM_ONLY"] == "1" || ProcessInfo.processInfo.environment["REQUESTMAN_URL_REPLACEMENT_FORM_ONLY"] == "1" { return }
        checkCodeEditorBehavior()
        try! checkCapturedMockEditing()
        checkTextAreaWheelRouting()
        if ProcessInfo.processInfo.environment["REQUESTMAN_CAPTURED_MOCK_ONLY"] == "1" { return }
        checkMatchTesting()
        if ProcessInfo.processInfo.environment["REQUESTMAN_MATCH_ONLY"] == "1" { return }
        if ProcessInfo.processInfo.environment["REQUESTMAN_SCRIPT_PRESENTATION_ONLY"] == "1" {
            checkScriptPresentation()
            print("Script inspector and preview sheet presentation checks passed")
            return
        }
        checkSingleLineBackgrounds()
        try! checkURLRewriteEditing()
        checkURLRewriteSplitWidth()
        try! checkURLReplacementEditing()
        checkBodyEditing()
        checkDelayEditing()
        checkMatchFieldScrolling()
        checkStepActivation()
        checkTemplateCaret()
        checkTemplateValues()
        checkScriptPresentation()
        let model = WorkspaceModel(); model.addProject(); model.addStep(.setHeader, response: false); model.addStep(.replaceBody, response: false)
        let sidebar = ProjectSidebarViewController(model: model)
        let rules = RulesViewController(model: model)
        let inspector = StepInspectorViewController(model: model)
        let container = NSSplitViewController()
        for controller in [sidebar, rules, inspector] as [NSViewController] {
            let item = NSSplitViewItem(viewController: controller)
            if controller === sidebar { item.minimumThickness = 280; item.maximumThickness = 280 }
            if controller === inspector { item.minimumThickness = 480; item.maximumThickness = 480 }
            container.addSplitViewItem(item)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = container
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.contentView?.wantsLayer = true; window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        container.splitView.setPosition(280, ofDividerAt: 0); container.splitView.setPosition(960, ofDividerAt: 1)
        window.contentView?.layoutSubtreeIfNeeded()

        precondition(sidebar.outline.numberOfRows == 2, "Project and workflow must be visible")
        let projectItem = sidebar.outline.item(atRow: 0)!
        let flowItem = sidebar.outline.item(atRow: 1)!
        precondition(sidebar.outlineView(sidebar.outline, heightOfRowByItem: projectItem) == 30)
        precondition(sidebar.outlineView(sidebar.outline, heightOfRowByItem: flowItem) == 30)
        let flowCell = sidebar.outline.view(atColumn: 0, row: 1, makeIfNecessary: true)!
        precondition(!descendants(flowCell).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(model.workflow!.matchConditions.conditions[0].value) })
        let selectedBeforeCollapse = model.selectedWorkflowID
        // Native row selection must no longer toggle the project; disclosure remains independent.
        sidebar.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        sidebar.refresh()
        precondition(sidebar.outline.numberOfRows == 2 && model.selectedWorkflowID == selectedBeforeCollapse)
        for expectedRows in [1, 2] {
            if expectedRows == 1 { sidebar.outline.collapseItem(projectItem) }
            else { sidebar.outline.expandItem(projectItem) }
            sidebar.refresh()
            precondition(sidebar.outline.numberOfRows == expectedRows)
            precondition(model.selectedWorkflowID == selectedBeforeCollapse)
        }
        precondition(sidebar.outline.doubleAction != nil && sidebar.outline.target === sidebar,
                     "Row double clicks must use the native table action")
        for _ in 0..<2 {
            for expectedRows in [1, 2] {
                sidebar.toggleProject(at: 0)
                checkDisclosureAnimations(sidebar.outline, expanding: expectedRows == 2)
                RunLoop.main.run(until: Date().addingTimeInterval(0.22))
                precondition(sidebar.outline.numberOfRows == expectedRows, "Double-click action toggles a project exactly once")
                precondition(model.selectedWorkflowID == selectedBeforeCollapse)
            }
        }
        for expectedRows in [1, 2] {
            sidebar.outline.disclosureButton(at: 0)!.performClick(nil)
            checkDisclosureAnimations(sidebar.outline, expanding: expectedRows == 2)
            RunLoop.main.run(until: Date().addingTimeInterval(0.22))
            precondition(sidebar.outline.numberOfRows == expectedRows, "Native disclosure buttons toggle once")
        }
        precondition(!sidebar.toggleProject(at: 1), "Double-clicking a rule must not toggle a project")
        for (character, keyCode, expectedRows) in [("\u{f702}", UInt16(123), 1), ("\u{f703}", UInt16(124), 2)] {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode)!
            sidebar.outline.keyDown(with: key)
            checkDisclosureAnimations(sidebar.outline, expanding: expectedRows == 2)
            RunLoop.main.run(until: Date().addingTimeInterval(0.22))
            precondition(sidebar.outline.numberOfRows == expectedRows, "Native arrow keys expand and collapse the selected project")
        }
        let projectCell = sidebar.outline.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        window.contentView?.layoutSubtreeIfNeeded()
        let projectFields = descendants(projectCell)
        let projectTitle = projectFields.first { $0.identifier?.rawValue == "rules.sidebarTitle" }!
        let projectIcon = projectFields.first { $0.identifier?.rawValue == "rules.sidebarIcon" }!
        let titleRect = projectTitle.convert(projectTitle.bounds, to: sidebar.outline)
        let iconRect = projectIcon.convert(projectIcon.bounds, to: sidebar.outline)
        let disclosureRect = sidebar.outline.frameOfOutlineCell(atRow: 0)
        precondition(abs(titleRect.midY - iconRect.midY) < 1 && abs(disclosureRect.midY - iconRect.midY) < 2,
                     "Disclosure, icon and label must share an optical center: \(disclosureRect), \(iconRect), \(titleRect)")
        // Native text fields and SF Symbols have optical alignment insets; compare
        // their Auto Layout alignment rectangles, not the exterior view frames.
        let titleAlignment = projectTitle.superview!.convert(projectTitle.alignmentRect(forFrame: projectTitle.frame), to: sidebar.outline)
        let iconAlignment = projectIcon.superview!.convert(projectIcon.alignmentRect(forFrame: projectIcon.frame), to: sidebar.outline)
        precondition(abs(titleAlignment.minX - iconAlignment.maxX - 8) < 1,
                     "Optical icon/title gap: \(iconAlignment), \(titleAlignment)")
        let currentFlowCell = sidebar.outline.view(atColumn: 0, row: 1, makeIfNecessary: true)!
        let flowTitle = descendants(currentFlowCell).first { $0.identifier?.rawValue == "rules.sidebarTitle" }!
        let flowTitleRect = flowTitle.convert(flowTitle.bounds, to: sidebar.outline)
        precondition(abs(flowTitleRect.minX - titleRect.minX) < 1, "Project and rule names must align vertically")
        sidebar.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let projectRow = sidebar.outline.rowView(atRow: 0, makeIfNecessary: true) as! ProjectSidebarRowView
        let hoverLayer = projectRow.layer!.sublayers!.first { $0.name == "sidebar.hoverBackground" }!
        let count = projectFields.first { $0.identifier?.rawValue == "rules.sidebarCount" }!
        let countFrame = count.frame
        let more = projectFields.first { $0.identifier?.rawValue == "rules.sidebarMore" } as! NSButton
        projectRow.setHovered(true, animated: true)
        precondition(hoverLayer.opacity == 1 && !more.isHidden && count.isHidden)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(abs(hoverLayer.animation(forKey: "sidebar.hoverOpacity")!.duration - 0.12) < 0.001)
        }
        projectRow.setHovered(false, animated: true)
        precondition(hoverLayer.opacity == 0 && more.isHidden && !count.isHidden && count.frame == countFrame)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(abs(hoverLayer.animation(forKey: "sidebar.hoverOpacity")!.duration - 0.16) < 0.001)
        }
        projectRow.setHovered(true, animated: false)
        precondition(hoverLayer.opacity == 1 && hoverLayer.animationKeys()?.isEmpty != false)
        sidebar.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        precondition(hoverLayer.opacity == 0 && hoverLayer.animationKeys()?.isEmpty != false,
                     "Native selection takes priority over hover and cancels its animation")
        precondition(!more.isHidden && count.isHidden, "Keyboard-selected rows replace the count with their native action button")
        sidebar.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        projectRow.setHovered(false, animated: false)
        var projectMenu = sidebar.menu(forRow: 0)!
        precondition(projectMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["添加请求修改", "禁用整个规则组", "复制整个规则组", "重命名", "修改图标", "导出整组…", "删除规则组"])
        projectMenu.performActionForItem(at: projectMenu.indexOfItem(withTitle: "禁用整个规则组")); sidebar.refresh()
        precondition(!model.document.projects[0].enabled && model.workflow!.enabled)
        projectMenu = sidebar.menu(forRow: 0)!
        precondition(projectMenu.item(withTitle: "启用整个规则组") != nil)
        projectMenu.performActionForItem(at: projectMenu.indexOfItem(withTitle: "启用整个规则组"))
        let icons = projectMenu.item(withTitle: "修改图标")!.submenu!
        let palettes = icons.items.compactMap(\.submenu)
        let iconChoices = palettes.flatMap(\.items)
        precondition(palettes.count == 8 && palettes.allSatisfy { $0.presentationStyle == .palette && $0.numberOfItems == 6 })
        precondition(iconChoices.count == 48 && iconChoices.allSatisfy { $0.title.isEmpty && $0.image != nil && $0.toolTip?.isEmpty == false })
        if #available(macOS 27.0, *) { precondition(iconChoices.allSatisfy { $0.preferredImageVisibility == .visible }) }
        palettes[0].performActionForItem(at: 1); sidebar.refresh()
        precondition(iconChoices.filter { $0.state == .on }.count == 1)
        palettes[7].performActionForItem(at: 5); sidebar.refresh()
        precondition(model.document.projects[0].symbol == "speedometer" && iconChoices.filter { $0.state == .on }.count == 1)
        palettes[0].performActionForItem(at: 1); sidebar.refresh()
        precondition(model.document.projects[0].symbol == "network")
        let flowMenu = sidebar.menu(forRow: 1)!
        precondition(flowMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["禁用", "重命名", "复制", "导出…", "删除"])
        flowMenu.performActionForItem(at: 0); sidebar.refresh()
        precondition(!model.workflow!.enabled)
        sidebar.menu(forRow: 1)!.performActionForItem(at: 0); sidebar.refresh()
        precondition(model.workflow!.enabled)
        let addButton = descendants(sidebar.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "rules.sidebarAdd" }!
        let addRect = addButton.convert(addButton.bounds, to: sidebar.view)
        let searchRect = sidebar.searchField.convert(sidebar.searchField.bounds, to: sidebar.view)
        precondition(abs(addRect.height - searchRect.height) < 1 && abs(addRect.midY - searchRect.midY) < 1,
                     "Bottom add and search controls share height and center")
        precondition(abs(addRect.minX - 12) < 1 && abs(searchRect.minX - addRect.maxX - 10) < 1,
                     "Bottom controls retain their original margins and spacing")
        precondition(abs(searchRect.maxX - sidebar.view.bounds.width + 12) < 1 && searchRect.minY < 20)
        let titleField = descendants(rules.view).compactMap { $0 as? ActionTextField }.first { $0.placeholderString == "请求修改名称" }!
        titleField.selectText(nil)
        let titleEditor = titleField.currentEditor() as! NSTextView
        titleEditor.insertText("Changed flow", replacementRange: NSRange(location: 0, length: titleEditor.string.utf16.count))
        titleEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(titleField.currentEditor() == nil, "Return must remove focus from the workflow title")
        rules.refresh()
        precondition(model.workflow?.name == "Changed flow")
        model.document.projects[0].workflows[0].name = "Externally updated"
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(titleField.stringValue == "Externally updated", "Observation must refresh external model edits")
        precondition(descendants(rules.view).contains { $0 === titleField }, "Editing must retain the original field")
        let tables = descendants(rules.view).compactMap { $0 as? NSTableView }
        precondition(tables.count == 2 && tables.map(\.numberOfRows).sorted() == [0, 2])
        precondition(tables.allSatisfy { $0.selectionHighlightStyle == .regular }, "Step selection uses the system table appearance")
        precondition(rules.view.bounds.width >= 420)
        let laneFrames = tables.map { $0.convert($0.bounds, to: rules.view) }.sorted { $0.minX < $1.minX }
        precondition(laneFrames[0].maxX < laneFrames[1].minX, "Request and response lanes must remain side by side")
        precondition(abs(laneFrames[0].maxY - laneFrames[1].maxY) < 1, "Lane content must align at the top")
        precondition(abs(laneFrames[0].minY - laneFrames[1].minY) < 1, "Both lanes and their add buttons must share the bottom edge")
        precondition(tables.allSatisfy { $0.rowHeight == 56 + 4 * 2 }, "Step content preserves 56pt plus 4pt vertical insets")
        let editor = rules.children.first!.view
        let editorScroll = descendants(editor).first { $0.identifier?.rawValue == "rules.editorScroll" } as! NSScrollView
        precondition(abs(editorScroll.documentView!.subviews.first!.frame.minX - 24) < 1, "Flow editor must preserve 24pt horizontal padding")
        let pickers = descendants(rules.view).compactMap { $0 as? NSButton }
        let boxes = descendants(rules.view).compactMap { $0 as? NSBox }
        let laneBorders = boxes.filter { $0.identifier?.rawValue == "rules.laneBorder" }
        precondition(laneBorders.count == 2)
        precondition(!boxes.contains { ["rules.stepCard", "rules.stepAccent"].contains($0.identifier?.rawValue ?? "") }, "Step rows must not add a second custom selection surface")
        for border in laneBorders {
            let heading = descendants(border).first { $0.identifier?.rawValue == "rules.laneHeading" }!
            let add = descendants(heading).first { $0.identifier?.rawValue == "rules.addStep" } as! NSButton
            let table = descendants(border).compactMap { $0 as? NSTableView }.first!
            precondition(add.convert(add.bounds, to: border).minY > table.convert(table.bounds, to: border).maxY)
            if #available(macOS 26.0, *) { precondition(add.bezelStyle == .glass) }
        }
        let addMenus = pickers.filter { $0.identifier?.rawValue == "rules.addStep" }
        precondition(addMenus.count == 2 && addMenus.allSatisfy { !($0 is NSPopUpButton) && $0.title == "添加步骤" && ($0.menu?.numberOfItems ?? 0) > 0 }, "Add step uses a native glass button with a menu and no disclosure arrow")
        for menu in addMenus {
            let response = menu.accessibilityLabel() == "添加响应步骤"
            let kinds = ModificationKind.allCases.filter { $0 != .removeHeader && $0.supports(response: response) }
            let items = menu.menu!.items
            precondition(items.contains { $0.title == ModificationKind.delay.title } == response)
            precondition(items.map(\.title) == kinds.map(\.title))
            for item in items {
                precondition(item.image != nil, "Every modification type must have a menu icon")
                if #available(macOS 27.0, *) {
                    precondition(item.preferredImageVisibility == .visible, "Step icons must remain visible when macOS hides menu images by default")
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["REQUESTMAN_RULES_SNAPSHOT"],
           let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        precondition(!descendants(inspector.view).compactMap { $0 as? NSButton }.contains { ["上移", "下移"].contains($0.title) })
        model.selectedStepID = model.workflow?.requestSteps.first?.id; inspector.refresh()
        let combo = descendants(inspector.view).compactMap { $0 as? HeaderNameField }.first!
        combo.stringValue = "X-Custom"; combo.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo)); inspector.refresh()
        precondition(model.selectedStep?.headerEntries.first?.name == "X-Custom")
        precondition(descendants(inspector.view).contains { $0 === combo }, "Header editing must retain focus and selection")
        checkHeaderEditing(inspector, model: model, window: window)
        checkRemovalHeaderEditing()
        checkQueryParameterEditing()
        sidebar.search = "does-not-match"; precondition(sidebar.outline.numberOfRows == 1)
        sidebar.addRequest(); sidebar.refresh(); precondition(sidebar.search.isEmpty && model.document.projects[0].workflows.count == 2)
        sidebar.outline.collapseItem(sidebar.outline.item(atRow: 0))
        sidebar.search = "does-not-match"
        model.addWorkflow(projectID: model.document.projects[0].id)
        sidebar.refresh()
        precondition(sidebar.search.isEmpty && sidebar.searchField.stringValue.isEmpty)
        precondition(sidebar.outline.numberOfRows == 4 && sidebar.outline.selectedRow == 3,
                     "A newly selected workflow must reveal its collapsed project and clear a hiding search")
        for kind in ModificationKind.allCases {
            model.addStep(kind, response: kind == .setStatus); inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded()
            precondition(!descendants(inspector.view).compactMap { $0 as? NSBox }.contains { $0.title == "动态值" })
            precondition(!inspector.view.hasAmbiguousLayout, "Inspector layout should be determined for \(kind)")
            if [.setQueryParameter, .replaceURLString].contains(kind) {
                let nameLabel = kind == .setQueryParameter ? "参数名称" : "查找字符串"
                let field = descendants(inspector.view).compactMap { $0 as? ActionTextField }.first { $0.accessibilityLabel() == nameLabel }!
                field.stringValue = "test"; field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                inspector.refresh()
                precondition((kind == .setQueryParameter ? model.selectedStep?.queryParameterEntries.first?.name : model.selectedStep?.urlReplacementEntries.first?.search) == "test" && descendants(inspector.view).contains { $0 === field })
                precondition(!kind.supports(response: true) && kind.supports(response: false))
                let valueLabel = kind == .setQueryParameter ? "参数值" : "替换为"
                precondition(descendants(inspector.view).compactMap { $0 as? NSTextView }.contains { $0.accessibilityLabel() == valueLabel })
            }
        }
        inspector.isPresented = false
        let narrow = FlowEditorViewController(model: model)
        let narrowWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        narrowWindow.isReleasedWhenClosed = false; narrowWindow.contentViewController = narrow
        defer { narrowWindow.close() }
        narrow.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        narrow.view.layoutSubtreeIfNeeded()

        var headerFlow = model.workflow!
        headerFlow.matchConditions = WorkflowMatchGroup(conditions: [
            .init(field: .url, operation: .equals, value: "https://example.test/"),
            .init(field: .header, operation: .equals, name: "X-Environment", value: "staging")], groups: [
                WorkflowMatchGroup(mode: .any, conditions: [.init(field: .cookie, operation: .exists, name: "debug")])])
        model.updateWorkflow(headerFlow); narrow.refresh(); narrow.view.layoutSubtreeIfNeeded()
        func settleMatching() {
            narrow.refresh()
            for _ in 0..<4 { narrow.view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        let matchHeader = descendants(narrow.view).compactMap { $0 as? ActionTextField }.first { $0.stringValue == "X-Environment" }!
        for width: CGFloat in [420, 680, 900, 420] {
            narrowWindow.setContentSize(NSSize(width: width, height: 900)); settleMatching()
            for row in descendants(narrow.view).filter({ $0.identifier?.rawValue == "rules.conditionRow" }) {
                for control in row.subviews where !control.isHidden {
                    let rect = control.convert(control.bounds, to: narrow.view)
                    precondition(rect.minX >= 24 && rect.maxX <= width - 24 + 1, "Matching controls must fit narrow layouts: \(control), \(rect), row=\(row.bounds), root=\(narrow.view.bounds), width=\(width)")
                }
            }
        }
        matchHeader.stringValue = "X-Custom"; matchHeader.onChange("X-Custom"); settleMatching()
        precondition(model.workflow?.matchConditions.conditions[1].name == "X-Custom")
        precondition(descendants(narrow.view).contains { $0 === matchHeader }, "Value editing retains field identity")
        let collapse = descendants(narrow.view).first { $0.identifier?.rawValue == "rules.collapseMatching" } as! NSButton
        let groupCollapse = descendants(narrow.view).first { $0.identifier?.rawValue == "rules.collapseGroup" } as! NSButton
        let groupView = descendants(narrow.view).first { $0.identifier?.rawValue == "rules.conditionGroup" }!
        let expandedGroupHeight = groupView.bounds.height
        groupCollapse.performClick(nil); settleMatching()
        precondition(groupView.bounds.height < expandedGroupHeight)
        groupCollapse.performClick(nil); settleMatching()
        let matching = descendants(narrow.view).first { $0.identifier?.rawValue == "rules.matching" }!
        let expandedHeight = matching.bounds.height
        let width = narrow.view.bounds.width
        collapse.performClick(nil); settleMatching()
        precondition(matching.bounds.height < expandedHeight && matchHeader.isHiddenOrHasHiddenAncestor)
        precondition(narrow.view.bounds.width == width)
        collapse.performClick(nil); settleMatching()
        precondition(!matchHeader.isHiddenOrHasHiddenAncestor && matchHeader.stringValue == "X-Custom")
        precondition(!descendants(narrow.view).contains { $0.identifier?.rawValue == "rules.isSSE" })
        let rootAdd = descendants(matching).first { $0.identifier?.rawValue == "rules.addCondition" } as! NSButton
        let previousCount = model.workflow!.matchConditions.conditionCount
        rootAdd.performClick(nil); settleMatching()
        precondition(model.workflow!.matchConditions.conditionCount == previousCount + 1)
        let preview = WorkflowPreviewViewController(workflow: model.workflow!, environment: nil)
        _ = preview.view; preview.view.layoutSubtreeIfNeeded()
        let input = ScriptPreviewInputViewController(input: ScriptPreviewInput(), response: true) { _ in }
        _ = input.view; input.view.layoutSubtreeIfNeeded()
        precondition(descendants(input.view).compactMap { $0 as? RulesTextArea }.count == 4)
        let originalSelection = model.selectedWorkflowID
        model.addWorkflow(projectID: model.document.projects[0].id)
        let contextID = model.selectedWorkflowID!
        model.selectedWorkflowID = originalSelection
        sidebar.refresh(); window.contentView?.layoutSubtreeIfNeeded()
        let targetRow = sidebar.outline.numberOfRows - 1
        let targetPoint = sidebar.outline.convert(NSPoint(x: sidebar.outline.bounds.midX,
                                                         y: sidebar.outline.rect(ofRow: targetRow).midY), to: nil)
        let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: targetPoint, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let selectedRow = sidebar.outline.selectedRow
        let contextMenu = sidebar.outline.menu(for: contextEvent)!
        precondition(sidebar.outline.clickedRow == targetRow, "Native menu handling must track the row for its contextual outline")
        precondition(sidebar.outline.selectedRow == selectedRow && model.selectedWorkflowID == originalSelection,
                     "Right-clicking an unselected rule must preserve the editor selection")
        contextMenu.performActionForItem(at: 0)
        precondition(model.document.projects[0].workflows.first { $0.id == contextID }?.enabled == false,
                     "The menu belongs to the clicked rule, not the selected rule")
        sidebar.outline.didCloseMenu(contextMenu, with: contextEvent)
        // Focus determines the target; editing text must never delete or duplicate a rule.
        window.makeFirstResponder(sidebar.outline)
        sidebar.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        precondition(sidebar.canPerform(.duplicate) && sidebar.canPerform(.toggleEnabled))
        let enabledBefore = model.document.projects[0].enabled
        sidebar.perform(.toggleEnabled)
        precondition(model.document.projects[0].enabled != enabledBefore && sidebar.outline.selectedRow == 0)
        let projectCount = model.document.projects.count
        sidebar.perform(.duplicate)
        precondition(model.document.projects.count == projectCount + 1)
        sidebar.outline.selectRowIndexes(IndexSet(integer: sidebar.outline.numberOfRows - 1), byExtendingSelection: false)
        sidebar.searchField.selectText(nil)
        let workflowsBefore = model.document.projects.flatMap(\.workflows).count
        precondition(!sidebar.canPerform(.delete) && !sidebar.canPerform(.rename))
        sidebar.perform(.delete)
        precondition(model.document.projects.flatMap(\.workflows).count == workflowsBefore)
        window.makeFirstResponder(sidebar.outline)
        sidebar.perform(.delete)
        precondition(model.document.projects.flatMap(\.workflows).count == workflowsBefore, "Opening confirmation must preserve the rule")
        func respondToDeletion(_ title: String) {
            guard let sheet = window.attachedSheet,
                  let button = descendants(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                preconditionFailure("Expected native deletion confirmation: \(title)")
            }
            if title == "取消" { precondition(sheet.defaultButtonCell === button.cell, "Cancel must remain the native default button") }
            else { precondition(button.hasDestructiveAction && button.keyEquivalent.isEmpty) }
            button.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        respondToDeletion("取消")
        precondition(model.document.projects.flatMap(\.workflows).count == workflowsBefore)
        window.makeFirstResponder(sidebar.outline)
        sidebar.perform(.delete)
        respondToDeletion("删除规则")
        precondition(model.document.projects.flatMap(\.workflows).count == workflowsBefore - 1)
        // Context menus confirm the clicked group even when another rule is selected.
        sidebar.refresh()
        let groupID = model.document.projects.last!.id
        let groupItem = sidebar.outlineView(sidebar.outline, child: model.document.projects.count - 1, ofItem: nil)
        let groupRow = sidebar.outline.row(forItem: groupItem)
        model.selectedWorkflowID = model.document.projects[0].workflows[0].id
        let selectionBeforeDeletion = model.selectedWorkflowID
        sidebar.refresh()
        let groupMenu = sidebar.menu(forRow: groupRow)!
        groupMenu.performActionForItem(at: groupMenu.items.firstIndex { $0.title == "删除规则组" }!)
        precondition(model.document.projects.count == projectCount + 1)
        respondToDeletion("取消")
        precondition(model.document.projects.count == projectCount + 1)
        groupMenu.performActionForItem(at: groupMenu.items.firstIndex { $0.title == "删除规则组" }!)
        respondToDeletion("删除规则组")
        precondition(model.document.projects.count == projectCount && !model.document.projects.contains { $0.id == groupID })
        precondition(model.selectedWorkflowID == selectionBeforeDeletion, "Deleting a context-menu target preserves another selected rule")
        // Add a step in each lane and target the focused lane, independent of model selection.
        model.selectedWorkflowID = model.document.projects[0].workflows[0].id
        model.addStep(.setHeader, response: false)
        model.addStep(.setHeader, response: true)
        rules.refresh()
        let lanes = descendants(rules.view).compactMap { $0 as? NSTableView }
        let responseTable = lanes.first { $0.accessibilityLabel() == "响应步骤" }!
        responseTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.makeFirstResponder(responseTable)
        precondition(rules.canPerform(.toggleEnabled) && !rules.canPerform(.duplicate))
        let responseEnabled = model.workflow!.responseSteps[0].enabled
        rules.perform(.toggleEnabled)
        precondition(model.workflow!.responseSteps[0].enabled != responseEnabled)
        let requestCount = model.workflow!.requestSteps.count
        let responseCount = model.workflow!.responseSteps.count
        rules.perform(.delete)
        precondition(model.workflow!.responseSteps.count == responseCount - 1 && model.workflow!.requestSteps.count == requestCount)
        checkRapidSidebarDisclosure()
        checkSidebarWidths()
        print("Rules UI checks passed: Body JSON formatting/save/undo, syntax colors and ruler rendering, native sidebar, live field identity, both lanes, multiple headers, template marks and clipboard/undo, deletion confirmation, all inspector kinds and preview inputs. Hidden CLI window only; no App built or run.")
    }
    private static func checkDisclosureAnimations(_ outline: ProjectOutlineView, expanding: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        guard let button = outline.disclosureButton(at: 0),
              let rotation = button.layer?.animation(forKey: "sidebar.disclosureRotation") as? CAKeyframeAnimation else {
            preconditionFailure("The native disclosure button must have a rotation animation")
        }
        precondition(rotation.duration == 0.18 && rotation.values?.count == 33)
        let pivot = CGPoint(x: button.layer!.bounds.midX - button.layer!.bounds.width * button.layer!.anchorPoint.x,
                            y: button.layer!.bounds.midY - button.layer!.bounds.height * button.layer!.anchorPoint.y)
        for value in rotation.values as! [NSValue] {
            let transformed = pivot.applying(CATransform3DGetAffineTransform(value.caTransform3DValue))
            precondition(hypot(transformed.x - pivot.x, transformed.y - pivot.y) < 0.001,
                         "Every rotation sample must preserve the arrow center: \(pivot) -> \(transformed)")
        }
        let buttonFrame = button.convert(button.bounds, to: outline)
        let cell = outline.view(atColumn: 0, row: 0, makeIfNecessary: false)!
        let icon = descendants(cell).first { $0.identifier?.rawValue == "rules.sidebarIcon" }!
        let iconFrame = icon.superview!.convert(icon.alignmentRect(forFrame: icon.frame), to: outline)
        precondition(abs(buttonFrame.midY - iconFrame.midY) < 0.5,
                     "The actual arrow button and folder icon must share a center: \(buttonFrame), \(iconFrame)")
        precondition(button.image === button.alternateImage, "Disclosure must never swap arrow glyphs")
        if let directory = ProcessInfo.processInfo.environment["REQUESTMAN_ARROW_SNAPSHOT_DIR"],
           let rowView = outline.rowView(atRow: 0, makeIfNecessary: false) {
            let wasSelected = rowView.isSelected
            rowView.isSelected = false
            rowView.display()
            defer { rowView.isSelected = wasSelected }
            let context = CGContext(data: nil, width: Int(rowView.bounds.width * 2), height: Int(rowView.bounds.height * 2),
                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: rowView.bounds.width * 2, height: rowView.bounds.height * 2))
            context.translateBy(x: 0, y: rowView.bounds.height * 2)
            context.scaleBy(x: 2, y: -2)
            rowView.layer!.render(in: context)
            let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
            let name = expanding ? "expanded.png" : "collapsed.png"
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        if expanding {
            let layer = outline.rowView(atRow: 1, makeIfNecessary: false)?.layer
            precondition(layer?.animation(forKey: "sidebar.rowPosition") != nil,
                         "Entering children must actually animate their position")
            precondition(layer?.animation(forKey: "sidebar.rowOpacity") != nil)
        } else {
            let snapshot = outline.layer?.sublayers?.first { $0.name == "sidebar.disappearingRow" }
            precondition(snapshot?.animation(forKey: "sidebar.rowOpacity") != nil,
                         "Collapsing children must fade out instead of disappearing instantly")
        }
    }
    private static func checkRapidSidebarDisclosure() {
        let model = WorkspaceModel()
        var project = WorkflowProject(name: "快速展开")
        project.workflows = (0..<24).map { index in
            var flow = RequestWorkflow(); flow.name = "规则 \(index)"
            flow.requestSteps = (0..<16).map { _ in ModificationStep(kind: .setHeader) }; return flow
        }
        model.document.projects = [project, WorkflowProject(name: "第二个规则组")]
        model.selectedWorkflowID = project.workflows[0].id
        let sidebar = ProjectSidebarViewController(model: model)
        let rules = RulesViewController(model: model)
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: sidebar))
        split.addSplitViewItem(NSSplitViewItem(viewController: rules))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 800))
        defer { window.close() }
        sidebar.view.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            sidebar.toggleProject(at: 0)
            sidebar.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            for table in descendants(rules.view).compactMap({ $0 as? NSTableView }) {
                for row in 0..<table.numberOfRows {
                    let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                    let queried = table.delegate?.tableView?(table, viewFor: table.tableColumns[0], row: row)
                    precondition(cell === queried, "Repeated offscreen and accessibility requests reuse step cells")
                }
                _ = table.accessibilityChildren()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(sidebar.outline.numberOfRows == 26)
        precondition(model.selectedWorkflowID == project.workflows[0].id)
        precondition(sidebar.outline.layer?.sublayers?.contains { $0.name == "sidebar.disappearingRow" } != true,
                     "Completed animations must release row snapshots")
        for index in 0..<40 {
            model.selectedWorkflowID = project.workflows[index % 2].id
            rules.refresh(); sidebar.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            for table in descendants(rules.view).compactMap({ $0 as? NSTableView }) {
                for row in 0..<table.numberOfRows { _ = table.view(atColumn: 0, row: row, makeIfNecessary: true) }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        sidebar.toggleProject(at: 0)
        sidebar.search = "规则 0"
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        precondition(sidebar.outline.layer?.sublayers?.contains { $0.name == "sidebar.disappearingRow" } != true,
                     "Search reloads must cancel obsolete animation snapshots")
        print("Rapid sidebar disclosure: 100 reversals, 24 children, 16 editor steps, 40 editor replacements and search interruption passed")
    }
    private static func checkSidebarWidths() {
        let model = WorkspaceModel()
        var first = WorkflowProject(name: "新规则组")
        var firstFlow = RequestWorkflow(); firstFlow.name = "test"
        var duplicate = RequestWorkflow(); duplicate.name = "test 副本"
        first.workflows = [firstFlow, duplicate]
        var second = WorkflowProject(name: "商城规则组")
        second.workflows = ["创建订单", "获取订单详情", "用户信息 Mock"].map { name in
            var flow = RequestWorkflow(); flow.name = name; return flow
        }
        model.document.projects = [first, second]
        model.selectedWorkflowID = firstFlow.id
        let sidebar = ProjectSidebarViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 540),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = sidebar
        defer { window.close() }
        for width: CGFloat in [260, 320, 400] {
            window.setContentSize(NSSize(width: width, height: 540))
            sidebar.refresh(); sidebar.view.layoutSubtreeIfNeeded()
            let firstCell = sidebar.outline.view(atColumn: 0, row: 0, makeIfNecessary: true)!
            let secondCell = sidebar.outline.view(atColumn: 0, row: 3, makeIfNecessary: true)!
            func field(_ cell: NSView, _ identifier: String) -> NSView {
                descendants(cell).first { $0.identifier?.rawValue == identifier }!
            }
            let firstCount = field(firstCell, "rules.sidebarCount")
            let secondCount = field(secondCell, "rules.sidebarCount")
            let firstRect = firstCount.convert(firstCount.bounds, to: sidebar.outline)
            let secondRect = secondCount.convert(secondCount.bounds, to: sidebar.outline)
            precondition(abs(firstRect.maxX - secondRect.maxX) < 1, "Counts align between project groups")
            let secondRow = sidebar.outline.rowView(atRow: 3, makeIfNecessary: true) as! ProjectSidebarRowView
            let titleFrame = field(secondCell, "rules.sidebarTitle").frame
            precondition(!secondCount.isHidden)
            secondRow.setHovered(true, animated: false)
            secondCell.layoutSubtreeIfNeeded()
            let more = field(secondCell, "rules.sidebarMore")
            let moreRect = more.convert(more.bounds, to: sidebar.outline)
            precondition(abs(secondRect.midX - moreRect.midX) < 1 && moreRect.maxX <= sidebar.outline.bounds.width,
                         "Single-digit counts and hover buttons share the trailing slot center")
            precondition(secondCount.isHidden && !more.isHidden && field(secondCell, "rules.sidebarTitle").frame == titleFrame,
                         "Hover replaces the count without shifting the title")
            precondition(!sidebar.outline.enclosingScrollView!.hasHorizontalScroller)
            secondRow.setHovered(false, animated: false)
            precondition(!secondCount.isHidden && more.isHidden)
        }
        window.setContentSize(NSSize(width: 320, height: 540))
        sidebar.view.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["REQUESTMAN_SIDEBAR_SNAPSHOT"] {
            let row = sidebar.outline.rowView(atRow: 3, makeIfNecessary: true) as! ProjectSidebarRowView
            row.isShowingMenu = true
            if let bitmap = sidebar.view.bitmapImageRepForCachingDisplay(in: sidebar.view.bounds) {
                sidebar.view.cacheDisplay(in: sidebar.view.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            }
            row.isShowingMenu = false
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for expanded in [false, true] {
                sidebar.toggleProject(at: 0)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                let secondProjectRow = expanded ? 3 : 1
                let animation = sidebar.outline.rowView(atRow: secondProjectRow, makeIfNecessary: false)?
                    .layer?.animation(forKey: "sidebar.rowPosition") as? CABasicAnimation
                let start = (animation?.fromValue as? NSValue)?.pointValue
                let end = (animation?.toValue as? NSValue)?.pointValue
                precondition(start != nil && end != nil && abs(start!.y - end!.y) > 1,
                             "Following project rows must visibly slide when a folder changes height")
                RunLoop.main.run(until: Date().addingTimeInterval(0.22))
            }
        }
        model.document.projects[1].name = String(repeating: "很长的规则组名称", count: 8)
        sidebar.refresh(); sidebar.view.layoutSubtreeIfNeeded()
        let cell = sidebar.outline.view(atColumn: 0, row: 3, makeIfNecessary: true)!
        let title = descendants(cell).first { $0.identifier?.rawValue == "rules.sidebarTitle" } as! NSTextField
        let suffix = descendants(cell).first { $0.identifier?.rawValue == "rules.sidebarCount" }!
        precondition(title.frame.maxX <= suffix.frame.minX && title.lineBreakMode == .byTruncatingMiddle)
        precondition(title.toolTip == model.document.projects[1].name)
        let menu = sidebar.menu(forRow: 3)!
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "添加请求修改"))
        sidebar.refresh()
        precondition(model.document.projects[0].workflows.count == 2 && model.document.projects[1].workflows.count == 4,
                     "The project action must add into its own group, not the previously selected group")
        precondition(model.selectedWorkflowID == model.document.projects[1].workflows.last?.id)
    }
    static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
