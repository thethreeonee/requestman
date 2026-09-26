import AppKit
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
}

@MainActor private final class ScriptFocusCheckWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main @MainActor struct RulesUIChecks {
    static func checkSingleLineBackgrounds() {
        let model = WorkspaceModel(); model.addProject()
        let inspector = StepInspectorViewController(model: model)
        let flow = FlowEditorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var checked = 0
        func check(_ controller: NSViewController) {
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 640, height: 1000))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for _ in 0..<3 {
                    controller.view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                let fields = descendants(controller.view).compactMap { $0 as? NSTextField }.filter {
                    ($0 is ActionTextField || $0 is HeaderNameField) && $0.isEditable && $0.isBezeled
                        && $0.bezelStyle != .roundedBezel && !$0.isHiddenOrHasHiddenAncestor
                }
                precondition(!fields.isEmpty)
                for field in fields {
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
                        precondition(field is HeaderNameField || white > bitmap.pixelsWide * bitmap.pixelsHigh / 3,
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
        workflow.matchHeaderEnabled = true
        model.updateWorkflow(workflow)
        check(flow)
        for kind in [ModificationKind.setHeader, .setQueryParameter, .replaceURLString, .mock, .delay, .script] {
            model.addStep(kind, response: kind == .delay); inspector.refresh()
            check(inspector)
        }
        print("Single-line inputs: \(checked) rendered background and editing checks passed")
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
        let description = descendants(inspector.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "rules.stepDescription" }!
        precondition((description.superview as? NSStackView)?.arrangedSubviews[1] === description)
        precondition(description.stringValue.contains("区分大小写") && description.stringValue.contains("所有匹配"))
        precondition(!description.isDescendant(of: boxes()[0]))
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
        let descriptions = descendants(inspector.view).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "rules.stepDescription" }
        precondition(descriptions.count == 1)
        let description = descriptions[0]
        precondition((description.superview as? NSStackView)?.arrangedSubviews[1] === description)
        precondition(!description.stringValue.contains("旧配置"))
        precondition(boxes().allSatisfy { !description.isDescendant(of: $0) })
        precondition(descendants(boxes()[0]).compactMap { $0 as? NSTextField }.filter { !$0.isEditable }.map(\.stringValue) == ["操作", "参数名称", "参数值"])
        precondition(buttons().first { $0.title == "添加参数操作" }?.imagePosition == .imageLeading)
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
        let legacyDescription = descendants(inspector.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "rules.stepDescription" }!
        precondition(legacyDescription.stringValue.contains("旧配置"))
        let legacyRule = descendants(boxes()[0]).compactMap { $0 as? ActionPopUpButton }.first { $0.accessibilityLabel() == "参数名称匹配规则" }!
        precondition(legacyRule.indexOfSelectedItem == 0 && !legacyRule.isHiddenOrHasHiddenAncestor)
        legacyRule.selectItem(at: 1); legacyRule.onChange(1); settle()
        precondition(!legacyDescription.stringValue.contains("旧配置"))
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
        let area = RulesTextArea(template: true, bodyEditor: true) { saved = $0 }
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
        let ruler = area.verticalRulerView as! BodyLineRuler
        precondition(ruler.lineStarts.count == 4 && ruler.lineStarts.last == (area.string as NSString).length)
        precondition(area.rulersVisible && ruler.clientView === area.textView)
        area.string = #"{"key":true,"id":"{{$uuid}}"}"#
        let layout = area.textView.layoutManager!
        precondition((layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 2, effectiveRange: nil) as? NSColor) == .systemBlue)
        precondition((layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 7, effectiveRange: nil) as? NSColor) == .systemPurple)
        precondition((layout as! TemplateLayoutManager).tokenRanges.count == 1)
        // Exercise native ruler drawing for empty text, wrapped lines and scrolling.
        for source in ["", formatted, "[\n" + Array(repeating: "  \"" + String(repeating: "long ", count: 30) + "\"", count: 40).joined(separator: ",\n") + "\n]\n"] {
            area.string = source
            window.contentView?.layoutSubtreeIfNeeded()
            area.textView.scrollRangeToVisible(NSRange(location: (source as NSString).length, length: 0))
            guard let bitmap = area.bitmapImageRepForCachingDisplay(in: area.bounds) else { preconditionFailure("Missing editor rendering") }
            area.cacheDisplay(in: area.bounds, to: bitmap)
        }
        if let path = ProcessInfo.processInfo.environment["REQUESTMAN_BODY_EDITOR_PREVIEW"] {
            area.string = formatted; area.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
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
            let editor = descendants(inspector.view).compactMap { $0 as? RulesTextArea }.first!
            precondition(editor.frame.height == 360)
            let form = descendants(inspector.view).compactMap { $0 as? NSScrollView }.first { !($0 is RulesTextArea) }!
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
            let textLayout = editor.textView.layoutManager!
            textLayout.ensureLayout(for: editor.textView.textContainer!)
            let usedHeight = textLayout.usedRect(for: editor.textView.textContainer!).maxY + editor.textView.textContainerOrigin.y
            precondition(editor.textView.frame.height >= usedHeight, "Long Body document is clipped: frame=\(editor.textView.frame), used=\(usedHeight), max=\(editor.textView.maxSize)")
            editor.textView.scrollRangeToVisible(NSRange(location: (longBody as NSString).length - 1, length: 1))
            precondition(editor.contentView.bounds.maxY >= usedHeight - 24, "The last Body line must be reachable: \(editor.contentView.bounds), used=\(usedHeight)")
            editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 1))
            let beforeScroll = editor.contentView.bounds.minY
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0)!
            editor.scrollWheel(with: NSEvent(cgEvent: wheel)!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(editor.contentView.bounds.minY > beforeScroll, "Wheel scrolling must move the Body viewport")
            precondition(editor.formatJSON())
            window.contentView?.layoutSubtreeIfNeeded()
            textLayout.ensureLayout(for: editor.textView.textContainer!)
            precondition(editor.textView.frame.height >= textLayout.usedRect(for: editor.textView.textContainer!).maxY, "Formatting must resize the document")
            editor.string = loose; editor.textDidChange(Notification(name: NSText.didChangeNotification))
            descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == "格式化 JSON" }!.performClick(nil)
            precondition(model.selectedStep?.value == normalized, "Object literal input must save as formatted JSON in both directions")
            editor.string = original; editor.textDidChange(Notification(name: NSText.didChangeNotification))
            descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == "格式化 JSON" }!.performClick(nil)
            precondition(model.selectedStep?.value == formatted, "Formatting must persist in both directions")
            editor.string = ""
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(editor.textView.frame.height >= editor.contentSize.height, "An empty editor must remain clickable throughout its viewport")
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
        let hint = descendants(inspector.view).first { $0.identifier?.rawValue == "rules.stepDescription" }!
        precondition(boxes.allSatisfy { !hint.isDescendant(of: $0) })
        precondition(hint.superview === button("删除").superview?.superview, "The type description belongs to the heading stack")
        let fields = descendants(inspector.view).compactMap { $0 as? HeaderNameField }
        fields[1].stringValue = "X-Token"; fields[1].controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields[1]))
        let area = descendants(inspector.view).compactMap { $0 as? RulesTextArea }[1]
        window.makeFirstResponder(area.textView)
        let original = "pre{{$env.api}}post\n{{$uuid}}end / {{unfinished"
        area.textView.insertText(original, replacementRange: NSRange(location: 0, length: 0))
        inspector.refresh()
        precondition(model.selectedStep?.headerEntries[1].value == original)
        let layout = area.textView.layoutManager as! TemplateLayoutManager
        precondition(layout.tokenRanges.count == 2 && area.layer?.cornerRadius == 8)
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
        precondition(operations.count == 2 && operations.allSatisfy { $0.itemTitles == ["添加", "修改", "删除"] })
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
        func button(_ title: String) -> NSButton { descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == title }! }
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
        let allFields = descendants(inspector.view).compactMap { $0 as? HeaderNameField }
        precondition(allFields.count == 12 && allFields.allSatisfy { $0.frame.width > 100 })
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY)); settle()
        precondition(scrolling.contentView.bounds.contains(button("Header 修改").convert(button("Header 修改").bounds, to: scrolling.contentView)), "The last add button must be reachable by scrolling")
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
        workflow.matchPattern = value
        workflow.matchHeaderEnabled = true; workflow.matchHeaderName = "X-Route"; workflow.matchHeaderPattern = value
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
            precondition(field.accessibilityLabel() == "匹配值" ? model.workflow?.matchPattern == value + "x" : model.workflow?.matchHeaderPattern == value + "x")
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
        text.textContainer!.containerSize = NSSize(width: 80, height: CGFloat.greatestFiniteMagnitude)
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
        let area = descendants(editor.view).compactMap { $0 as? RulesTextArea }.first!
        let text = area.textView, layout = text.layoutManager!, ruler = area.verticalRulerView as! BodyLineRuler
        precondition(area.rulersVisible && ruler.lineStarts.count == 9)
        func color(_ fragment: String) -> NSColor? {
            let range = (text.string as NSString).range(of: fragment)
            return layout.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
        }
        precondition(color("// const") == .secondaryLabelColor && color("/* return") == .secondaryLabelColor)
        precondition(color("const data") == .systemPurple && color("true;") == .systemPurple)
        precondition(color("JSON.parse") == .systemTeal && color("parse(") == .systemBlue)
        precondition(color("`中文😀`") == .systemGreen && color("0xff") == .systemOrange && color("2.5e2") == .systemOrange)
        precondition(text.string == code && text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != .secondaryLabelColor,
                     "Highlighting must not modify the stored source or persist syntax attributes")
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.insertText("let changed = 42;\n", replacementRange: text.selectedRange())
        precondition(saved.value == text.string && color("let") == .systemPurple && ruler.lineStarts.count == 10)
        text.breakUndoCoalescing(); text.undoManager?.undo()
        precondition(saved.value == code && text.string == code && ruler.lineStarts.count == 9)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: text.selectedRange())
        precondition(text.hasMarkedText())
        text.insertText("拼音", replacementRange: text.markedRange())
        precondition(text.string.hasPrefix("拼音") && saved.value == text.string)
        for (value, lineCount) in [("", 1), ("\n", 2), ("const text = 'unterminated", 1), ("/* open\ncomment", 2), ("const s = `a\\`b`;", 1), ("// comment\r\nreturn request;\r\n", 3), ("const long = '" + String(repeating: "中文😀", count: 160) + "';\n", 2)] {
            area.string = value; window.contentView?.layoutSubtreeIfNeeded()
            precondition(area.string == value && ruler.lineStarts.count == lineCount)
            text.scrollRangeToVisible(NSRange(location: (value as NSString).length, length: 0))
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
            precondition(descendants(editor.view).compactMap { $0 as? RulesTextArea }.count == 1)
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
            func focusPixels() -> Int {
                let bitmap = headers.bitmapImageRepForCachingDisplay(in: headers.bounds)!
                headers.cacheDisplay(in: headers.bounds, to: bitmap)
                var count = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.alphaComponent > 0.2, color.blueComponent > color.redComponent + 0.15,
                           color.blueComponent > color.greenComponent + 0.05 { count += 1 }
                    }
                }
                return count
            }
            window.makeFirstResponder(nil)
            let unfocusedPixels = focusPixels()
            precondition(window.makeFirstResponder(headers.textView))
            precondition(focusPixels() > unfocusedPixels + 50, "Focused text areas must visibly render the native blue focus ring")
            window.makeFirstResponder(nil)
            precondition(focusPixels() == unfocusedPixels, "Moving focus away must remove the focus ring")
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
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
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
        workflow.method = "GET"; workflow.matchRule = .regex; workflow.matchPattern = "/v1/orders/[0-9]+$"
        workflow.matchHeaderEnabled = true; workflow.matchHeaderName = "X-Environment"; workflow.matchHeaderPattern = "staging"
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
        precondition(!descendants(controller.view).contains { $0 is NSScrollView }, "The dialog body must not scroll")
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
        workflow.matchPattern = "["
        let invalid = WorkflowMatchTestViewController(workflow: workflow)
        _ = invalid.view
        let invalidRun = descendants(invalid.view).first { $0.identifier?.rawValue == "matchTest.run" } as! NSButton
        precondition(!invalidRun.isEnabled)
        precondition(descendants(invalid.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("正则表达式无效") })
        var simpleWorkflow = workflow
        simpleWorkflow.matchHeaderEnabled = false; simpleWorkflow.matchPattern = "/v1/orders/[0-9]+$"
        let simple = WorkflowMatchTestViewController(workflow: simpleWorkflow)
        let simpleWindow = NSWindow(contentViewController: simple); simpleWindow.isReleasedWhenClosed = false
        simpleWindow.contentView?.layoutSubtreeIfNeeded()
        let simpleURL = descendants(simple.view).first { $0.identifier?.rawValue == "matchTest.url" } as! ActionTextField
        simpleURL.stringValue = "https://api.example.com/v1/orders/123"; simpleURL.onChange(simpleURL.stringValue)
        let simpleRun = descendants(simple.view).first { $0.identifier?.rawValue == "matchTest.run" } as! NSButton
        simpleRun.performClick(nil)
        let deadline = Date().addingTimeInterval(3)
        while simpleRun.title == "测试中…" && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(!descendants(simple.view).contains { $0 is NSScrollView }, "The no-Header dialog must not scroll")
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
        precondition(button.superview?.identifier?.rawValue == "rules.matchMethodRow")
        (button as! NSButton).performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let sheet = flow.presentedViewControllers?.first as? WorkflowMatchTestViewController
        precondition(sheet != nil, "Test button must present the native match sheet")
        sheet?.dismiss(nil)
        host.close()
        print("Match testing: native layout, success, Header mismatch, invalid pattern/input and stale-result checks passed")
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkMatchTesting()
        if ProcessInfo.processInfo.environment["REQUESTMAN_MATCH_ONLY"] == "1" { return }
        if ProcessInfo.processInfo.environment["REQUESTMAN_SINGLE_LINE_BACKGROUNDS_ONLY"] == "1" {
            checkSingleLineBackgrounds()
            try! checkURLReplacementEditing()
            checkQueryParameterEditing()
            checkScriptPresentation()
            return
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_SCRIPT_PRESENTATION_ONLY"] == "1" {
            checkScriptPresentation()
            print("Script inspector and preview sheet presentation checks passed")
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
            precondition(legacy.titleOfSelectedItem == "添加或覆盖（旧配置）")
            precondition(legacy.item(at: 0)?.isEnabled == false && model.selectedStep?.headerEntries.first?.operation == .set)
            legacy.selectItem(at: 2); legacy.onChange(2); inspector.refresh()
            precondition(legacy.itemTitles == ["添加", "修改", "删除"] && legacy.titleOfSelectedItem == "修改")
            precondition(model.selectedStep?.headerEntries.first?.operation == .modify && model.selectedStep?.headerEntries.first?.value == "old")
            let flow = FlowEditorViewController(model: model)
            _ = flow.view; flow.refresh()
            let menus = descendants(flow.view).compactMap { $0 as? NSPopUpButton }.filter { $0.identifier?.rawValue == "rules.addStep" }
            precondition(menus.count == 2)
            for menu in menus {
                precondition(menu.itemTitles.filter { $0 == "修改 Header" }.count == 1)
                precondition(!menu.itemTitles.contains("移除 Header") && !menu.itemTitles.contains("添加或覆盖 Header"))
            }
            print("Header form: mixed operations, value retention, legacy editing, menu and layout checks passed")
            return
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_QUERY_FORM_ONLY"] == "1" {
            checkQueryParameterEditing()
            print("Query parameter form: editing, operations, persistence, layout and legacy checks passed")
            return
        }
        if ProcessInfo.processInfo.environment["REQUESTMAN_URL_REPLACEMENT_FORM_ONLY"] == "1" {
            try! checkURLReplacementEditing()
            print("URL replacement form: multiple blocks, single-line editing, description, persistence and layout checks passed")
            return
        }
        checkSingleLineBackgrounds()
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
        precondition(!descendants(flowCell).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(model.workflow!.matchPattern) })
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
        precondition(projectMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["添加请求修改", "禁用整个项目", "复制整个项目", "重命名", "修改图标", "导出整组…", "删除项目"])
        projectMenu.performActionForItem(at: projectMenu.indexOfItem(withTitle: "禁用整个项目")); sidebar.refresh()
        precondition(!model.document.projects[0].enabled && model.workflow!.enabled)
        projectMenu = sidebar.menu(forRow: 0)!
        precondition(projectMenu.item(withTitle: "启用整个项目") != nil)
        projectMenu.performActionForItem(at: projectMenu.indexOfItem(withTitle: "启用整个项目"))
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
        precondition(tables.allSatisfy { $0.selectionHighlightStyle == .none }, "Selection styling belongs to the existing step card, without a second row backdrop")
        precondition(rules.view.bounds.width >= 420)
        let laneFrames = tables.map { $0.convert($0.bounds, to: rules.view) }.sorted { $0.minX < $1.minX }
        precondition(laneFrames[0].maxX < laneFrames[1].minX, "Request and response lanes must remain side by side")
        precondition(abs(laneFrames[0].maxY - laneFrames[1].maxY) < 1, "Lane content must align at the top")
        precondition(abs(laneFrames[0].minY - laneFrames[1].minY) < 1, "Both lanes and their add buttons must share the bottom edge")
        precondition(tables.allSatisfy { $0.rowHeight == 56 + 4 * 2 }, "Step content preserves 56pt plus 4pt vertical insets")
        let editor = rules.children.first!.view
        precondition(abs(editor.subviews.first!.frame.minX - 24) < 1, "Flow editor must preserve 24pt horizontal padding")
        let pickers = descendants(rules.view).compactMap { $0 as? NSPopUpButton }
        precondition(abs(pickers.first { $0.accessibilityLabel() == "地址匹配目标" }!.frame.width - 130) < 1)
        precondition(abs(pickers.first { $0.accessibilityLabel() == "地址匹配规则" }!.frame.width - 90) < 1)
        let boxes = descendants(rules.view).compactMap { $0 as? NSBox }
        let laneBorders = boxes.filter { $0.identifier?.rawValue == "rules.laneBorder" }
        precondition(laneBorders.count == 2 && laneBorders.allSatisfy { $0.cornerRadius == 10 && $0.borderWidth == 1 && $0.fillColor.alphaComponent == 0 && $0.borderColor == .separatorColor }, "Lane borders must retain their original transparent 10pt outline")
        let cards = boxes.filter { $0.identifier?.rawValue == "rules.stepCard" }
        precondition(cards.count == 2 && cards.allSatisfy { $0.cornerRadius == 8 && $0.borderWidth == 1 && abs($0.frame.height - 56) < 1 }, "Step cards must retain their 56pt height and 8pt corners")
        precondition(cards.contains { abs($0.fillColor.alphaComponent - 0.12) < 0.001 && abs($0.borderColor.alphaComponent - 0.55) < 0.001 }, "Selected card must retain its blue fill and outline")
        precondition(cards.contains { abs($0.fillColor.alphaComponent - 0.045) < 0.001 && $0.borderColor.alphaComponent == 0 }, "Unselected card must retain its subtle fill")
        let badges = boxes.filter { $0.identifier?.rawValue == "rules.stepNumber" }
        precondition(badges.allSatisfy { abs($0.frame.width - 26) < 1 && abs($0.frame.height - 28) < 1 && $0.cornerRadius == 6 })
        let accents = boxes.filter { $0.identifier?.rawValue == "rules.stepAccent" }
        precondition(accents.filter { !$0.isHidden }.count == 1 && accents.allSatisfy { abs($0.frame.width - 3) < 1 })
        precondition(accents.allSatisfy { accent in
            guard let card = cards.first(where: { accent.isDescendant(of: $0) }) else { return false }
            let frame = accent.convert(accent.bounds, to: card)
            return abs(frame.minY - card.bounds.minY) < 0.5
                && abs(frame.maxY - card.bounds.maxY) < 0.5
                && card.layer?.masksToBounds == true && card.layer?.cornerRadius == card.cornerRadius
        }, "Selection accents must span the card height and clip to its rounded corners")
        let addMenus = pickers.filter { $0.identifier?.rawValue == "rules.addStep" }
        precondition(addMenus.count == 2 && addMenus.allSatisfy { $0.pullsDown && $0.itemTitle(at: 0) == "添加步骤" && $0.numberOfItems > 1 }, "Add step must use a native pull-down menu")
        for menu in addMenus {
            let response = menu.accessibilityLabel() == "添加响应步骤"
            let kinds = ModificationKind.allCases.filter { $0 != .removeHeader && $0.supports(response: response) }
            let items = Array(menu.itemArray.dropFirst())
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
        narrow.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        narrow.view.layoutSubtreeIfNeeded()

        var headerFlow = model.workflow!
        headerFlow.matchTarget = .url; headerFlow.matchRule = .equals; headerFlow.matchPattern = "https://example.test/"
        headerFlow.matchHeaderEnabled = true; headerFlow.matchHeaderRule = .equals
        headerFlow.matchHeaderName = "X-Environment"; headerFlow.matchHeaderPattern = "staging"
        model.updateWorkflow(headerFlow); narrow.refresh(); narrow.view.layoutSubtreeIfNeeded()
        let matchHeader = descendants(narrow.view).compactMap { $0 as? HeaderNameField }.first { $0.accessibilityLabel() == "匹配 Header 名称" }!
        precondition(!matchHeader.isHiddenOrHasHiddenAncestor && matchHeader.stringValue == "X-Environment")
        for width: CGFloat in [420, 680, 900, 420] {
            narrow.view.setFrameSize(NSSize(width: width, height: 900))
            for _ in 0..<5 {
                narrow.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            let controls = descendants(narrow.view)
            let methodRow = controls.first { $0.identifier?.rawValue == "rules.matchMethodRow" }!
            let addressRow = controls.first { $0.identifier?.rawValue == "rules.matchAddressRow" }!
            let headerRow = controls.first { $0.identifier?.rawValue == "rules.matchHeaderRow" }!
            let rows = [methodRow, addressRow, headerRow].map { $0.convert($0.bounds, to: narrow.view) }
            precondition(rows[0].minY > rows[1].maxY && rows[1].minY > rows[2].maxY, "Method, address and Header occupy separate condition groups")
            precondition(rows.allSatisfy { $0.minX >= 24 && $0.maxX <= width - 24 })
            let method = controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "请求方法匹配" }!
            let addressRule = controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "地址匹配规则" }!
            precondition(abs(method.convert(method.bounds, to: narrow.view).minX - addressRule.convert(addressRule.bounds, to: narrow.view).minX) < 1)
            let value = controls.compactMap { $0 as? ActionTextField }.first { $0.accessibilityLabel() == "Header 匹配值" }!
            let nameRect = matchHeader.convert(matchHeader.bounds, to: narrow.view)
            let valueRect = value.convert(value.bounds, to: narrow.view)
            precondition(abs(nameRect.width - 240) < 1 && valueRect.width >= 100)
            precondition(valueRect.maxX <= width - 24 && nameRect.maxX <= width - 24)
            if width == 420 { precondition(valueRect.maxY < nameRect.minY, "Narrow Header group wraps internally") }
            else { precondition(abs(valueRect.midY - nameRect.midY) < 3, "Wide Header controls stay on one line: width=\(width), name=\(nameRect), value=\(valueRect), group=\(headerRow.frame), parent=\(matchHeader.superview!.bounds)") }
        }
        matchHeader.stringValue = "X-Custom"
        matchHeader.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: matchHeader))
        narrow.refresh(); precondition(model.workflow?.matchHeaderName == "X-Custom")
        let target = descendants(narrow.view).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == WorkflowMatchTarget.allCases.map(\.title) }!
        precondition(target.itemTitles == ["URL 匹配", "Host 匹配"])
        target.selectItem(at: 1); precondition(target.sendAction(target.action, to: target.target))
        narrow.refresh(); precondition(!matchHeader.isHiddenOrHasHiddenAncestor && model.workflow?.matchHeaderName == "X-Custom")
        let headerValue = descendants(narrow.view).compactMap { $0 as? ActionTextField }.first { $0.accessibilityLabel() == "Header 匹配值" }!
        headerValue.stringValue = "prod"; headerValue.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: headerValue))
        narrow.refresh(); precondition(model.workflow?.matchHeaderPattern == "prod" && model.workflow?.matchPattern == "https://example.test/")
        let toggle = descendants(narrow.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "同时匹配 Header" }!
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let windowFrame = window.frame
        let rulesWidth = rules.view.bounds.width
        let narrowWidth = narrow.view.bounds.width
        for active in [false, true, false, true] {
            toggle.performClick(nil); narrow.refresh()
            for _ in 0..<5 {
                narrow.view.layoutSubtreeIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            precondition(model.workflow!.matchHeaderEnabled == active && matchHeader.isHiddenOrHasHiddenAncestor == !active)
            if !active {
                let headerRow = descendants(narrow.view).first { $0.identifier?.rawValue == "rules.matchHeaderRow" }!
                precondition(abs(headerRow.bounds.height - toggle.bounds.height) < 1,
                             "Disabled Header matching must occupy only the checkbox height")
                let box = descendants(narrow.view).compactMap { $0 as? NSBox }.first { toggle.isDescendant(of: $0) }!
                let checkboxRect = toggle.convert(toggle.bounds, to: box)
                precondition(abs(checkboxRect.minY - 12) < 1,
                             "Matching box must keep only its bottom inset below the disabled Header checkbox")
            }
            precondition(window.frame == windowFrame && abs(rules.view.bounds.width - rulesWidth) < 1 && narrow.view.bounds.width == narrowWidth,
                         "Toggling Header must preserve the window and split-pane widths")
            precondition(headerValue.stringValue == "prod")
        }
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
        precondition(model.document.projects.flatMap(\.workflows).count == workflowsBefore - 1)
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
        model.document.projects = [project, WorkflowProject(name: "第二个项目")]
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
        var first = WorkflowProject(name: "新项目")
        var firstFlow = RequestWorkflow(); firstFlow.name = "test"
        var duplicate = RequestWorkflow(); duplicate.name = "test 副本"
        first.workflows = [firstFlow, duplicate]
        var second = WorkflowProject(name: "商城项目")
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
        model.document.projects[1].name = String(repeating: "很长的项目名称", count: 8)
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
