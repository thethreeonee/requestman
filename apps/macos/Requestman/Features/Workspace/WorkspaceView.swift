import SwiftUI

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            List(WorkspaceSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("Requestman")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                if case let .unavailable(reason) = model.captureAvailability {
                    Label(reason, systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        } detail: {
            Group {
                switch model.selection ?? .applications {
                case .applications: ApplicationsView(model: model)
                case .requests: RequestsView()
                case .rules: RulesView()
                case .connection: ConnectionSettingsView(model: model)
                }
            }
            .navigationTitle((model.selection ?? .applications).title)
        }
    }
}
