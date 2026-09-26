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

@main @MainActor struct RulesUIChecks {
    static func checkHeaderEditing(_ inspector: StepInspectorViewController, model: WorkspaceModel, window: NSWindow) {
        func button(_ title: String) -> NSButton {
            descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.title == title }!
        }
        button("添加 Header").performClick(nil); inspector.refresh()
        precondition(model.selectedStep?.headerEntries.count == 2)
        window.contentView?.layoutSubtreeIfNeeded()
        let boxes = descendants(inspector.view).compactMap { $0 as? NSBox }.filter { $0.identifier?.rawValue == "rules.headerEntry" }
        precondition(boxes.count == 2 && boxes.allSatisfy { descendants($0).compactMap { $0 as? HeaderNameField }.count == 1 })
        precondition(boxes.allSatisfy { !button("添加 Header").isDescendant(of: $0) })
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
        let removeHeader = descendants(inspector.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "删除 Header" }!
        removeHeader.performClick(nil); inspector.refresh()
        precondition(model.selectedStep?.headerEntries.count == 1 && model.selectedStep?.headerEntries[0].name == "X-Token")
        for _ in 0..<10 { button("添加 Header").performClick(nil); inspector.refresh() }
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

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkTemplateCaret()
        checkTemplateValues()
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
        precondition(hoverLayer.opacity == 1 && !more.isHidden)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(abs(hoverLayer.animation(forKey: "sidebar.hoverOpacity")!.duration - 0.12) < 0.001)
        }
        projectRow.setHovered(false, animated: true)
        precondition(hoverLayer.opacity == 0 && more.isHidden && count.frame == countFrame)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(abs(hoverLayer.animation(forKey: "sidebar.hoverOpacity")!.duration - 0.16) < 0.001)
        }
        projectRow.setHovered(true, animated: false)
        precondition(hoverLayer.opacity == 1 && hoverLayer.animationKeys()?.isEmpty != false)
        sidebar.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        precondition(hoverLayer.opacity == 0 && hoverLayer.animationKeys()?.isEmpty != false,
                     "Native selection takes priority over hover and cancels its animation")
        precondition(!more.isHidden, "Keyboard-selected rows expose their native action button")
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
            let kinds = ModificationKind.allCases.filter { $0.supports(response: response) }
            let items = Array(menu.itemArray.dropFirst())
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
                let field = descendants(inspector.view).compactMap { $0 as? RulesTextArea }.first { $0.textView.accessibilityLabel() == nameLabel }!
                field.string = "test"; field.textDidChange(Notification(name: NSText.didChangeNotification, object: field.textView))
                inspector.refresh()
                precondition(model.selectedStep?.name == "test" && descendants(inspector.view).contains { $0 === field })
                precondition(!kind.supports(response: true) && kind.supports(response: false))
                let valueLabel = kind == .setQueryParameter ? "参数值 / 模板" : "替换为 / 模板"
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
        print("Rules UI checks passed: native sidebar, live field identity, both lanes, multiple headers, template marks and clipboard/undo, deletion confirmation, all inspector kinds and preview inputs. Hidden CLI window only; no App built or run.")
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
            secondRow.setHovered(true, animated: false)
            let more = field(secondCell, "rules.sidebarMore")
            let moreRect = more.convert(more.bounds, to: sidebar.outline)
            precondition(moreRect.minX >= secondRect.maxX && moreRect.maxX <= sidebar.outline.bounds.width,
                         "Hover actions and counts must fit at the narrow sidebar width")
            precondition(!sidebar.outline.enclosingScrollView!.hasHorizontalScroller)
            secondRow.setHovered(false, animated: false)
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
