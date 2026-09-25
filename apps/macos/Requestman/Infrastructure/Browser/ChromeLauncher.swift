import AppKit

@MainActor
struct ChromeLauncher {
    func applicationURL() throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw LaunchError.notInstalled
        }
        return url
    }

    func launch(applicationURL: URL, proxyPort: Int) async throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Requestman/Chrome/port-\(proxyPort)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let configuration = NSWorkspace.OpenConfiguration()
        // A running Chrome process keeps its original proxy arguments. Separate profiles by port
        // so a later launch cannot silently reuse a process connected to the previous listener.
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = [
            "--user-data-dir=\(directory.path)",
            "--proxy-server=http://127.0.0.1:\(proxyPort)",
            "--proxy-bypass-list=<-loopback>",
            "--no-first-run",
            "--no-default-browser-check",
            "--new-window",
            "about:blank"
        ]
        _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    private enum LaunchError: LocalizedError {
        case notInstalled
        var errorDescription: String? { "未找到 Google Chrome，请先安装后再试。" }
    }
}
