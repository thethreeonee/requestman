import AppKit

struct ChromiumBrowser: Identifiable, Equatable, Sendable {
    let applicationURL: URL
    let bundleIdentifier: String
    let name: String
    var id: String { applicationURL.path }
}

enum ChromiumBrowserCatalog {
    @MainActor
    static func installedBrowsers() async -> [ChromiumBrowser] {
        // Launch Services also finds registered apps outside the Applications folders.
        let registered = ["http://localhost", "https://localhost"].flatMap {
            NSWorkspace.shared.urlsForApplications(toOpen: URL(string: $0)!)
        }
        return await Task.detached(priority: .utility) {
            discover(candidates: registered + applicationFolderURLs())
        }.value
    }

    static func discover(candidates: [URL]) -> [ChromiumBrowser] {
        var seenURLs = Set<URL>()
        var seenIdentifiers = Set<String>()
        // Keep Launch Services' preferred copy; updater caches can also be registered handlers.
        let browsers = candidates.compactMap { candidate -> ChromiumBrowser? in
            let url = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard seenURLs.insert(url).inserted,
                  !["/Library/Caches/", "/.Trash/", "/.Trashes/", "/AppTranslocation/"].contains(where: { url.path.contains($0) }),
                  let browser = browser(at: url),
                  seenIdentifiers.insert(browser.bundleIdentifier).inserted else { return nil }
            return browser
        }
        return browsers.sorted {
            if $0.bundleIdentifier == "com.google.Chrome", $1.bundleIdentifier != "com.google.Chrome" { return true }
            if $1.bundleIdentifier == "com.google.Chrome", $0.bundleIdentifier != "com.google.Chrome" { return false }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func browser(at url: URL) -> ChromiumBrowser? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let info = bundle.infoDictionary else { return nil }
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() }
        let documents = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let handlesHTML = documents.contains {
            let types = $0["LSItemContentTypes"] as? [String] ?? []
            let extensions = $0["CFBundleTypeExtensions"] as? [String] ?? []
            return types.contains("public.html") || extensions.contains("html") || extensions.contains("htm")
        }
        // HTTP handlers alone include media players and embedded web views, not just browsers.
        guard schemes.contains("http"), schemes.contains("https"), handlesHTML,
              containsChromiumEngine(in: url) else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return ChromiumBrowser(applicationURL: url, bundleIdentifier: identifier, name: name)
    }

    private static func containsChromiumEngine(in application: URL) -> Bool {
        let manager = FileManager.default
        let frameworks = (try? manager.contentsOfDirectory(at: application.appendingPathComponent("Contents/Frameworks"),
                                                           includingPropertiesForKeys: nil)) ?? []
        for framework in frameworks where framework.pathExtension == "framework" {
            // Electron/CEF hosts do not offer the Chrome browser launch contract.
            guard !["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains(framework.lastPathComponent) else { continue }
            let versions = (try? manager.contentsOfDirectory(at: framework.appendingPathComponent("Versions"),
                                                             includingPropertiesForKeys: nil)) ?? []
            for root in [framework] + versions {
                let resources = root.appendingPathComponent("Resources")
                guard manager.fileExists(atPath: resources.appendingPathComponent("icudtl.dat").path) else { continue }
                let files = (try? manager.contentsOfDirectory(atPath: resources.path)) ?? []
                if files.contains(where: { $0.hasSuffix("_100_percent.pak") }) { return true }
            }
        }
        return false
    }

    private static func applicationFolderURLs() -> [URL] {
        let manager = FileManager.default
        let roots = manager.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        return roots.flatMap { root -> [URL] in
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "app" }
        }
    }
}
