import AppKit
import SwiftUI
import RequestmanCore

struct ProjectSidebarView: View {
    @Bindable var model: WorkspaceModel
    @Binding var search: String
    @State private var collapsedProjects: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedWorkflowID) {
                ForEach($model.document.projects) { $project in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsedProjects.contains(project.id) },
                        set: { expanded in
                            if expanded { collapsedProjects.remove(project.id) }
                            else { collapsedProjects.insert(project.id) }
                        }
                    )) {
                        ForEach(project.workflows.filter(matchesSearch)) { workflow in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(workflow.name).lineLimit(1)
                                    Text("\(workflow.method) · \(workflow.matchPattern)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if !workflow.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                            }
                            .padding(.vertical, 5)
                            .opacity(workflow.enabled ? 1 : 0.55)
                            .tag(workflow.id)
                            .contextMenu {
                                Button("复制") { model.duplicateWorkflow(workflow, projectID: project.id) }
                                Button("删除", role: .destructive) { model.deleteWorkflow(workflow.id) }
                            }
                        }
                    } label: {
                        Label {
                            HStack {
                                TextField("项目名称", text: $project.name).textFieldStyle(.plain).fontWeight(.semibold)
                                Text("\(project.workflows.count)").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "folder") }
                    }
                    .contextMenu {
                        Button("添加请求修改") { model.addWorkflow(projectID: project.id) }
                        Button("删除项目", role: .destructive) {
                            let id = project.id
                            model.document.projects.removeAll { $0.id == id }
                            if model.workflow == nil {
                                model.selectedWorkflowID = nil
                                model.selectedStepID = nil
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            ProjectSidebarControls(search: $search, addRequest: addRequest, addProject: model.addProject)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .disabled(!model.loaded)
    }

    private func addRequest() {
        let project = model.document.projects.first {
            $0.workflows.contains { $0.id == model.selectedWorkflowID }
        } ?? model.document.projects.first
        search = ""
        if let project {
            collapsedProjects.remove(project.id)
            model.addWorkflow(projectID: project.id)
        } else {
            model.addProject()
        }
    }

    private func matchesSearch(_ workflow: RequestWorkflow) -> Bool {
        search.isEmpty || workflow.name.localizedCaseInsensitiveContains(search)
            || workflow.matchPattern.localizedCaseInsensitiveContains(search)
    }
}

private struct ProjectSidebarControls: NSViewRepresentable {
    @Binding var search: String
    let addRequest: () -> Void
    let addProject: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ControlsView {
        let view = ControlsView()
        view.searchField.delegate = context.coordinator
        view.addButton.target = context.coordinator
        view.addButton.action = #selector(Coordinator.showMenu(_:))
        return view
    }

    func updateNSView(_ view: ControlsView, context: Context) {
        context.coordinator.parent = self
        if view.searchField.stringValue != search { view.searchField.stringValue = search }
        view.searchField.isEnabled = context.environment.isEnabled
        view.addButton.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ControlsView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: nsView.fittingSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ProjectSidebarControls
        init(parent: ProjectSidebarControls) { self.parent = parent }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            let request = menu.addItem(withTitle: "添加请求", action: #selector(addRequest), keyEquivalent: "")
            request.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            request.target = self
            let project = menu.addItem(withTitle: "添加项目", action: #selector(addProject), keyEquivalent: "")
            project.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            project.target = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
        }

        @objc func addRequest() { parent.addRequest() }
        @objc func addProject() { parent.addProject() }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.search = field.stringValue
        }
    }

    final class ControlsView: NSView {
        let searchField = NSSearchField()
        let addButton = NSButton()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            searchField.controlSize = .large
            searchField.placeholderString = "搜索请求修改"
            searchField.setAccessibilityLabel("搜索请求修改")
            searchField.sendsSearchStringImmediately = true
            searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            addButton.title = ""
            addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加")
            addButton.imagePosition = .imageOnly
            addButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            addButton.setButtonType(.momentaryPushIn)
            addButton.controlSize = .large
            if #available(macOS 26.0, *) {
                addButton.bezelStyle = .glass
                addButton.borderShape = .circle
            } else {
                addButton.bezelStyle = .circular
            }
            addButton.toolTip = "添加"
            addButton.setAccessibilityLabel("添加")

            for control in [addButton, searchField] as [NSControl] {
                control.translatesAutoresizingMaskIntoConstraints = false
                addSubview(control)
            }
            // Align AppKit alignment rects instead of mixing SwiftUI and AppKit frames.
            NSLayoutConstraint.activate([
                searchField.heightAnchor.constraint(equalToConstant: searchField.intrinsicContentSize.height),
                searchField.topAnchor.constraint(equalTo: topAnchor),
                searchField.bottomAnchor.constraint(equalTo: bottomAnchor),
                searchField.trailingAnchor.constraint(equalTo: trailingAnchor),
                searchField.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 10),
                addButton.leadingAnchor.constraint(equalTo: leadingAnchor),
                addButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
                addButton.heightAnchor.constraint(equalTo: searchField.heightAnchor),
                addButton.widthAnchor.constraint(equalTo: addButton.heightAnchor)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

struct RulesView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Group {
            if let workflow = model.workflow {
                FlowEditorView(model: model, workflow: Binding(get: { model.workflow ?? workflow }, set: model.updateWorkflow))
            } else {
                ContentUnavailableView {
                    Label("编排一次，自动处理每次请求", systemImage: "point.3.connected.trianglepath.dotted")
                } description: { Text("在项目中创建请求修改，设置匹配条件，再添加请求和响应步骤。") }
                actions: { Button("新建项目", action: model.addProject).disabled(!model.loaded) }
            }
        }
        .disabled(!model.loaded)
        .onChange(of: model.selectedWorkflowID) { _, _ in model.selectedStepID = nil }
    }
}
