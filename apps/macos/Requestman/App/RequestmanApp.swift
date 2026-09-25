import SwiftUI

@main
struct RequestmanApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceAppDelegate.self) private var appDelegate
    @State private var model = WorkspaceModel()
    var body: some Scene {
        Window("Requestman", id: "workspace") {
            WorkspaceView(model: model).frame(minWidth: 1100, minHeight: 680)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        Settings { WorkspaceSettingsView(model: model) }
            .windowToolbarStyle(.unified(showsTitle: false))
            .windowResizability(.contentSize)
    }
}

@MainActor
final class WorkspaceAppDelegate: NSObject, NSApplicationDelegate {
    var model: WorkspaceModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            let saved = await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
