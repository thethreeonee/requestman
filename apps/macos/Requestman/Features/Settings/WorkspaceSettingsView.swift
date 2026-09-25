import SwiftUI

enum WorkspaceSettingsSection { case connection, environments }

struct WorkspaceSettingsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        TabView(selection: $model.settingsSection) {
            ConnectionSettingsView(model: model)
                .tabItem { Label("连接", systemImage: "network") }
                .tag(WorkspaceSettingsSection.connection)

            EnvironmentsView(model: model)
                .tabItem { Label("环境管理", systemImage: "externaldrive") }
                .tag(WorkspaceSettingsSection.environments)
        }
        .frame(width: model.settingsSection == .connection ? 640 : 800, height: 540)
    }
}
