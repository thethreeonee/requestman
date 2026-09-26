import AppKit
import UniformTypeIdentifiers
import RequestmanCore

@MainActor
enum WorkspaceTransfer {
    static let preferencesDomain = Bundle.main.bundleIdentifier ?? "com.requestman.macos"
    static let preferencesRestored = Notification.Name("Requestman.preferencesRestored")

    static func exportAll(model: WorkspaceModel, window: NSWindow?) {
        guard model.loaded else { return }
        do {
            let preferences = try PropertyListSerialization.data(
                fromPropertyList: UserDefaults.standard.persistentDomain(forName: preferencesDomain) ?? [:],
                format: .binary, options: 0)
            export(WorkspaceArchive(document: model.document, preferences: preferences), name: "Requestman", window: window)
        } catch { show(error, window: window) }
    }

    static func export(_ archive: WorkspaceArchive, name: String, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".requestman.json"
        present(panel, window: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached {
                        try archive.encoded().write(to: url, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }.value
                } catch { show(error, window: window) }
            }
        }
    }

    static func importFile(model: WorkspaceModel, window: NSWindow?) {
        guard model.loaded, !model.isTransitioning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        present(panel, window: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let archive = try await Task.detached { try WorkspaceArchive.decode(Data(contentsOf: url)) }.value
                    try await model.importArchive(archive)
                    if archive.scope == .workspace {
                        for window in NSApp.windows where !window.frameAutosaveName.isEmpty {
                            window.setFrameUsingName(window.frameAutosaveName, force: true)
                        }
                    }
                } catch { show(error, window: window) }
            }
        }
    }

    private static func present(_ panel: NSSavePanel, window: NSWindow?, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private static func show(_ error: any Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
