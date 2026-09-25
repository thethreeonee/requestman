import SwiftUI

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        WorkspaceSplitView(model: model, snapshot: WorkspaceToolbarSnapshot(model: model),
                           openSettings: { openSettings() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .alert("Requestman", isPresented: Binding(get: { model.errorMessage != nil }, set: {
                if !$0 { model.errorMessage = nil }
            })) {
                Button("好") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .task {
                await model.certificateSetup.prepareForStartup()
                await model.load()
                await model.collectRecords()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.certificateSetup.prepareForStartup() } }
                else { Task { await model.flushSave() } }
            }
    }
}

struct WorkspaceSidebarContent: View {
    let model: WorkspaceModel
    @State private var search = ""

    var body: some View {
        ProjectSidebarView(model: model, search: $search)
    }
}

struct WorkspaceMainContent: View {
    let model: WorkspaceModel

    var body: some View {
        Group {
            switch model.selection {
            case .rules: RulesView(model: model)
            case .requests: RequestsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EnvironmentSelectionPopover: View {
    @Bindable var model: WorkspaceModel
    let onDismiss: () -> Void
    let openSettings: () -> Void
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
                onDismiss()
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
        .onExitCommand { onDismiss() }
    }

    private func environmentRow(id: UUID?, name: String) -> some View {
        let isSelected = model.document.selectedEnvironmentID == id
        return Button {
            model.document.selectedEnvironmentID = id
            onDismiss()
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
