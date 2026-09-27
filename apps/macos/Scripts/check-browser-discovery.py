#!/usr/bin/env python3
"""Check browser discovery, profile isolation and instance reuse without launching a browser."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
temporary = Path(tempfile.mkdtemp(prefix="requestman-browser-check-"))


def fixture(name, *, html=True, framework="Test Framework.framework", versioned=False, executable=True, identifier=None):
    app = temporary / f"{name}.app"
    contents = app / "Contents"
    binary = contents / "MacOS/Browser"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\nexit 0\n")
    binary.chmod(0o755 if executable else 0o644)
    info = {
        "CFBundleIdentifier": identifier or f"test.browser.{name}",
        "CFBundleName": name,
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "Browser",
        "CFBundleURLTypes": [{"CFBundleURLSchemes": ["http", "https"]}],
        "CFBundleDocumentTypes": [{"LSItemContentTypes": ["public.html"]}] if html else [],
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    resources = contents / "Frameworks" / framework
    if versioned:
        resources /= "Versions/1.2.3"
    resources /= "Resources"
    resources.mkdir(parents=True)
    (resources / "icudtl.dat").touch()
    (resources / "test_100_percent.pak").touch()
    return app


try:
    fixture("Browser")
    fixture("Versioned", versioned=True)
    fixture("Embedded", html=False)
    fixture("Electron", framework="Electron Framework.framework")
    fixture("CEF", framework="Chromium Embedded Framework.framework")
    fixture("NonExecutable", executable=False)
    fixture("SecondCopy", identifier="test.browser.Browser")
    fixture("Library/Caches/Updater/CachedCopy", identifier="test.browser.CachedCopy")
    runner = temporary / "Check.swift"
    runner.write_text(r'''
import AppKit

@MainActor
final class FakeBrowserApplication: BrowserApplication {
    var isTerminated = false
    var activations = 0
    func activateForCapture() { activations += 1 }
}

enum LaunchFailure: Error { case expected }

@main
struct Check {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let candidates = ["Browser", "Versioned", "Embedded", "Electron", "CEF", "NonExecutable", "Missing", "Browser", "SecondCopy", "Library/Caches/Updater/CachedCopy"]
            .map { root.appendingPathComponent("\($0).app") }
        let discovered = ChromiumBrowserCatalog.discover(candidates: candidates)
        precondition(discovered.map(\.name) == ["Browser", "Versioned"], "Browser filtering/deduplication failed")
        let chrome = BrowserLauncher.profilePath(bundleIdentifier: "com.google.Chrome", proxyPort: 9090)
        let edge = BrowserLauncher.profilePath(bundleIdentifier: "com.microsoft.edgemac", proxyPort: 9090)
        let brave = BrowserLauncher.profilePath(bundleIdentifier: "com.brave.Browser", proxyPort: 9090)
        precondition(chrome == "Requestman/Chrome/port-9090", "Existing Chrome profile changed")
        precondition(Set([chrome, edge, brave]).count == 3, "Browser profiles must be isolated")
        precondition(edge != BrowserLauncher.profilePath(bundleIdentifier: "com.microsoft.edgemac", proxyPort: 9091))
        try BrowserLauncher().validate(discovered[0])
        let missing = ChromiumBrowser(applicationURL: root.appendingPathComponent("Missing.app"), bundleIdentifier: "missing", name: "Missing")
        do {
            try BrowserLauncher().validate(missing)
            preconditionFailure("Missing browser was accepted")
        } catch {}
        print("Browser filtering, versioned engines, deduplication, missing-app validation and profile isolation OK")

        var opened: [FakeBrowserApplication] = []
        var arguments: [[String]] = []
        var failNextLaunch = false
        let support = root.appendingPathComponent("Application Support")
        let launcher = BrowserLauncher(applicationSupportDirectory: support) { _, configuration in
            if failNextLaunch {
                failNextLaunch = false
                throw LaunchFailure.expected
            }
            precondition(configuration.createsNewApplicationInstance && configuration.activates)
            let app = FakeBrowserApplication()
            opened.append(app)
            arguments.append(configuration.arguments)
            return app
        }
        let browser = discovered[0]
        try await launcher.launch(browser: browser, proxyPort: 9090)
        precondition(opened.count == 1 && opened[0].activations == 0)
        precondition(arguments[0].contains("--proxy-server=http://127.0.0.1:9090"))
        precondition(arguments[0].contains("--new-window") && arguments[0].last == "about:blank")
        let profile = support.appendingPathComponent(BrowserLauncher.profilePath(bundleIdentifier: browser.bundleIdentifier, proxyPort: 9090))
        precondition(arguments[0].contains("--user-data-dir=\(profile.path)"))
        let marker = profile.appendingPathComponent("existing-profile-data")
        try Data("keep login data".utf8).write(to: marker)

        // The same launcher outlives capture stop/start; reuse never submits --new-window again.
        try await launcher.launch(browser: browser, proxyPort: 9090)
        precondition(opened.count == 1 && opened[0].activations == 1, "Restart opened another window")
        try await launcher.launch(browser: browser, proxyPort: 9091)
        precondition(opened.count == 2 && arguments[1].contains("--proxy-server=http://127.0.0.1:9091"))
        try await launcher.launch(browser: discovered[1], proxyPort: 9090)
        precondition(opened.count == 3, "Different browsers reused a process")
        try await launcher.launch(browser: browser, proxyPort: 9090)
        precondition(opened.count == 3 && opened[0].activations == 2, "Returning to a port lost its browser")
        try await launcher.launch(browser: discovered[1], proxyPort: 9090)
        precondition(opened.count == 3 && opened[2].activations == 1)

        opened[0].isTerminated = true
        failNextLaunch = true
        do {
            try await launcher.launch(browser: browser, proxyPort: 9090)
            preconditionFailure("Launch failure was swallowed")
        } catch LaunchFailure.expected {}
        try await launcher.launch(browser: browser, proxyPort: 9090)
        precondition(opened.count == 4 && arguments[0] == arguments[3], "Exited browser did not reuse its profile")
        let savedData = try Data(contentsOf: marker)
        precondition(savedData == Data("keep login data".utf8), "Existing browser data changed")
        try await launcher.launch(browser: browser, proxyPort: 9090)
        precondition(opened.count == 4 && opened[3].activations == 1, "Replacement instance was not retained")
        try await launcher.launch(browser: browser, proxyPort: 9091)
        precondition(opened.count == 4 && opened[1].activations == 1, "Another port's live instance was lost")
        print("Browser reuse, browser/port isolation, exit/relaunch, failed-launch retry and profile preservation OK")
        let installed = await ChromiumBrowserCatalog.installedBrowsers()
        print("Installed browsers: " + installed.map { "\($0.name) [\($0.applicationURL.path)]" }.joined(separator: ", "))
        print("No browser launched; system proxy settings unchanged")
    }
}
''')
    executable = temporary / "check"
    sources = root / "Requestman/Infrastructure/Browser"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-parse-as-library",
        "-module-cache-path", str(root / "Packages/RequestmanCore/.build/host-typecheck-cache"),
        str(sources / "ChromiumBrowserCatalog.swift"), str(sources / "BrowserLauncher.swift"),
        str(runner), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable), str(temporary)], check=True)
finally:
    subprocess.run(["trash", str(temporary)], check=True)
