import SwiftUI

@main
struct RequestmanApp: App {
    @State private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 720)

        Settings {
            ConnectionSettingsView(model: model)
                .frame(width: 520)
        }
    }
}
