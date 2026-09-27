import AppKit

@MainActor
protocol BrowserApplication: AnyObject {
    var isTerminated: Bool { get }
    func activateForCapture()
}

extension NSRunningApplication: BrowserApplication {
    func activateForCapture() {
        _ = activate(options: [.activateAllWindows])
    }
}

@MainActor
final class BrowserLauncher {
    private struct InstanceKey: Hashable {
        let applicationURL: URL
        let profile: String
    }

    private let applicationSupportDirectory: URL
    private let openApplication: (URL, NSWorkspace.OpenConfiguration) async throws -> any BrowserApplication
    // Kept independently of capture sessions; stopping the proxy does not quit the browser.
    private var applications: [InstanceKey: any BrowserApplication] = [:]

    init(
        applicationSupportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        openApplication: @escaping (URL, NSWorkspace.OpenConfiguration) async throws -> any BrowserApplication = {
            try await NSWorkspace.shared.openApplication(at: $0, configuration: $1)
        }
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.openApplication = openApplication
    }

    func validate(_ browser: ChromiumBrowser) throws {
        guard ChromiumBrowserCatalog.browser(at: browser.applicationURL)?.bundleIdentifier == browser.bundleIdentifier else {
            throw LaunchError.notInstalled(browser.name)
        }
    }

    func launch(browser: ChromiumBrowser, proxyPort: Int) async throws {
        try validate(browser)
        let profile = Self.profilePath(bundleIdentifier: browser.bundleIdentifier, proxyPort: proxyPort)
        let key = InstanceKey(applicationURL: browser.applicationURL.resolvingSymlinksInPath(), profile: profile)
        applications = applications.filter { !$0.value.isTerminated }
        if let application = applications[key] {
            application.activateForCapture()
            return
        }

        let directory = applicationSupportDirectory.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let configuration = NSWorkspace.OpenConfiguration()
        // A running browser process keeps its original proxy arguments. Separate profiles by browser and port
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
        applications[key] = try await openApplication(browser.applicationURL, configuration)
    }

    static func profilePath(bundleIdentifier: String, proxyPort: Int) -> String {
        // Preserve existing Chrome debugging data when upgrading.
        if bundleIdentifier == "com.google.Chrome" { return "Requestman/Chrome/port-\(proxyPort)" }
        let identifier = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "browser"
        return "Requestman/Browsers/\(identifier)/port-\(proxyPort)"
    }

    private enum LaunchError: LocalizedError {
        case notInstalled(String)
        var errorDescription: String? {
            switch self { case .notInstalled(let name): "未找到 \(name)，请刷新浏览器列表后重试。" }
        }
    }
}
