import AppKit
import Observation
import RequestmanCore

@MainActor @Observable final class WorkspaceModel {
    var document = WorkspaceDocument()
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
    func addStep(_ kind: ModificationKind, response: Bool) {
        guard var workflow else { return }; let step = ModificationStep(kind: kind)
        if response { workflow.responseSteps.append(step) } else { workflow.requestSteps.append(step) }
        updateWorkflow(workflow); editingResponse = response; selectedStepID = step.id
    }
}

@main @MainActor struct RulesUIChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
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
        let addButton = descendants(sidebar.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "rules.sidebarAdd" }!
        let addRect = addButton.convert(addButton.bounds, to: sidebar.view)
        let searchRect = sidebar.searchField.convert(sidebar.searchField.bounds, to: sidebar.view)
        precondition(abs(addRect.height - searchRect.height) < 1 && abs(addRect.midY - searchRect.midY) < 1, "Sidebar add and search controls must retain equal heights and vertical centers")
        precondition(abs(addRect.minX - 12) < 1 && abs(searchRect.minX - addRect.maxX - 10) < 1, "Sidebar footer retains 12pt margin and 10pt control spacing")
        let titleField = descendants(rules.view).compactMap { $0 as? ActionTextField }.first { $0.placeholderString == "请求修改名称" }!
        titleField.stringValue = "Changed flow"; titleField.onChange(titleField.stringValue); rules.refresh()
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
        precondition(pickers.filter { abs($0.frame.width - 130) < 1 }.count == 2, "Both match pickers preserve 130pt width")
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
        let addMenus = pickers.filter { $0.identifier?.rawValue == "rules.addStep" }
        precondition(addMenus.count == 2 && addMenus.allSatisfy { $0.pullsDown && $0.itemTitle(at: 0) == "添加步骤" && $0.numberOfItems > 1 }, "Add step must use a native pull-down menu")
        if let path = ProcessInfo.processInfo.environment["REQUESTMAN_RULES_SNAPSHOT"],
           let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        let selected = model.selectedStepID!; inspector.move(-1); inspector.refresh()
        precondition(model.workflow?.requestSteps.first?.id == selected)
        model.selectedStepID = model.workflow?.requestSteps.last?.id; inspector.refresh()
        let combo = descendants(inspector.view).compactMap { $0 as? HeaderNameField }.first!
        combo.stringValue = "X-Custom"; combo.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo)); inspector.refresh()
        precondition(model.selectedStep?.name == "X-Custom")
        precondition(descendants(inspector.view).contains { $0 === combo }, "Header editing must retain focus and selection")
        sidebar.search = "does-not-match"; precondition(sidebar.outline.numberOfRows == 1)
        sidebar.addRequest(); sidebar.refresh(); precondition(sidebar.search.isEmpty && model.document.projects[0].workflows.count == 2)
        for kind in ModificationKind.allCases {
            model.addStep(kind, response: kind == .setStatus); inspector.refresh(); window.contentView?.layoutSubtreeIfNeeded()
            precondition(!inspector.view.hasAmbiguousLayout, "Inspector layout should be determined for \(kind)")
        }
        inspector.isPresented = false
        let narrow = FlowEditorViewController(model: model)
        narrow.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        narrow.view.layoutSubtreeIfNeeded()
        let narrowGrid = descendants(narrow.view).compactMap { $0 as? NSGridView }.first!
        precondition(narrowGrid.frame.maxX <= 420 - 23, "Matching controls must stay inside the narrow content")
        let preview = WorkflowPreviewViewController(workflow: model.workflow!, environment: nil)
        _ = preview.view; preview.view.layoutSubtreeIfNeeded()
        let input = ScriptPreviewInputViewController(input: ScriptPreviewInput(), response: true) { _ in }
        _ = input.view; input.view.layoutSubtreeIfNeeded()
        precondition(descendants(input.view).compactMap { $0 as? RulesTextArea }.count == 4)
        print("Rules UI checks passed: native sidebar, live field identity, both lanes, step ordering, all inspector kinds and preview inputs. Hidden CLI window only; no App built or run.")
    }
    static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
