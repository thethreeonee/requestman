#!/usr/bin/env python3
"""Check browser discovery/profile isolation without launching a browser or changing system proxies."""
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
