import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var workflowSearch = ""
    @State private var showsRequestInspector = false
    @State private var showsEnvironmentPopover = false
    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { model.selection == .rules ? sidebarVisibility : .detailOnly },
            set: { visibility in
                guard model.selection == .rules else { return }
                withAnimation(sidebarAnimation) { sidebarVisibility = visibility }
            }
        )) {
            ProjectSidebarView(model: model, search: $workflowSearch)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch model.selection {
                    case .rules: RulesView(model: model)
                    case .requests: RequestsView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar
            }
            // Bind workspace items to the detail column, not the outer split/inspector container.
            .toolbar { workspaceToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(WorkspaceToolbarAppearance())
        // Outside NavigationSplitView so the inspector spans the full window height.
        .inspector(isPresented: requestInspectorPresentation) {
            RequestInspectorView(history: model.history)
                .inspectorColumnWidth(min: 320, ideal: 360, max: 420)
                .toolbar {
                    if model.selection == .requests {
                        ToolbarItem(placement: .automatic) {
                            Button {
                                withAnimation(sidebarAnimation) { showsRequestInspector.toggle() }
                            } label: {
                                Label(showsRequestInspector ? "收起请求详情" : "展开请求详情", systemImage: "sidebar.right")
                            }
                            .help(showsRequestInspector ? "收起请求详情" : "展开请求详情")
                            .disabled(model.history.selected == nil)
                        }
                    }
                }
        }
        .onChange(of: model.history.selectedID) { _, id in
            withAnimation(sidebarAnimation) { showsRequestInspector = id != nil }
        }
        .alert("Requestman", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .task { await model.load(); await model.collectRecords() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await model.flushSave() } } }
    }

    private var requestInspectorPresentation: Binding<Bool> {
        Binding(
            get: { model.selection == .requests && model.history.selected != nil && showsRequestInspector },
            set: { showsRequestInspector = $0 }
        )
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(model.isCapturing ? .green : .secondary).frame(width: 7, height: 7)
            Text(verbatim: model.isCheckingUpstream ? "正在检查上游代理…" : (model.listenPort.map { "本地代理 127.0.0.1:\(String($0))" } ?? "代理未启动"))
            Spacer()
            if model.selection == .rules { Text("\(model.document.projects.flatMap(\.workflows).count) 个请求修改") }
            if model.selection == .requests { Text("最近 \(model.history.records.count) 条 · 内存记录") }
            Text(model.saveState).foregroundStyle(model.saveState.contains("失败") ? .red : .secondary)
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9)
            .background(.bar)
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            sectionTabs.sharedBackgroundVisibility(.visible)
            environmentSelector.sharedBackgroundVisibility(.visible)
        } else {
            sectionTabs
            environmentSelector
        }
        if #available(macOS 26.0, *) {
            if model.selection == .requests {
                searchField.sharedBackgroundVisibility(.hidden)
            }
        } else {
            if model.selection == .requests { searchField }
        }
        ToolbarItem(placement: .automatic) {
            Button { Task { await model.toggleCapture() } } label: {
                Label {
                    Text(model.isCapturing ? "停止捕获" : "开始捕获")
                } icon: {
                    Image(systemName: model.isCapturing ? "stop.fill" : "play.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(model.isCapturing ? Color.red : Color.green)
                }
            }
            .help(model.isCapturing ? "停止捕获" : "开始捕获")
            .disabled(!model.loaded || model.isTransitioning)
        }
    }

    private var searchField: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            WorkspaceSearchField(
                text: Binding(
                    get: { model.history.search },
                    set: { model.history.search = $0 }
                ),
                prompt: "搜索 URL 或请求修改"
            )
            .frame(width: 240)
            .disabled(!model.loaded)
        }
    }

    private var sectionTabs: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            WorkspaceSectionControl(selection: Binding(
                get: { model.selection },
                set: { section in
                    withAnimation(sidebarAnimation) { model.selection = section }
                }
            ))
                .fixedSize()
        }
    }

    private var sidebarAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.25)
    }

    private var environmentSelector: some ToolbarContent {
        // The environment is a centered workspace control, independent of capture actions.
        ToolbarItem(placement: .principal) {
            Button {
                showsEnvironmentPopover.toggle()
            } label: {
                Text(model.document.environment?.name ?? "无环境")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 140)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("切换环境")
            .accessibilityValue(model.document.environment?.name ?? "无环境")
            .help("切换环境")
            .disabled(!model.loaded)
            .popover(isPresented: $showsEnvironmentPopover, arrowEdge: .bottom) {
                EnvironmentSelectionPopover(model: model)
            }
        }
    }

}

private struct EnvironmentSelectionPopover: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let environments = model.document.environments.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }
        let showsNoEnvironment = query.isEmpty || "无环境".localizedStandardContains(query)
        let rowCount = environments.count + (showsNoEnvironment ? 1 : 0)

        VStack(alignment: .leading, spacing: 10) {
            TextField("筛选环境", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("筛选环境")

            Text("环境").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            if rowCount == 0 {
                Text("没有匹配的环境")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if showsNoEnvironment { environmentRow(id: nil, name: "无环境") }
                        ForEach(environments) { environment in
                            environmentRow(id: environment.id, name: environment.name)
                        }
                    }
                }
                .frame(height: CGFloat(min(rowCount, 7)) * 36 - 4)
            }

            Divider()
            Button {
                model.settingsSection = .environments
                dismiss()
                openSettings()
            } label: {
                Text("管理环境…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { search = ""; searchFocused = true }
        .onExitCommand { dismiss() }
    }

    private func environmentRow(id: UUID?, name: String) -> some View {
        let isSelected = model.document.selectedEnvironmentID == id
        return Button {
            model.document.selectedEnvironmentID = id
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                Image(systemName: "externaldrive")
                Text(name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct WorkspaceSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var controlSize: NSControl.ControlSize = .regular

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        field.controlSize = controlSize
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private struct WorkspaceToolbarAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            content
        }
    }
}
