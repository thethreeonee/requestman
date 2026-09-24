import AppKit

@MainActor
struct ApplicationCatalog {
    func runningApplications() -> [RunningApplication] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  let identifier = application.bundleIdentifier,
                  identifier != Bundle.main.bundleIdentifier,
                  let bundleURL = application.bundleURL,
                  seen.insert(identifier).inserted else { return nil }
            return RunningApplication(
                id: identifier,
                name: application.localizedName ?? bundleURL.deletingPathExtension().lastPathComponent,
                bundleURL: bundleURL
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
