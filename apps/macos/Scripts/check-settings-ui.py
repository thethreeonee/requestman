#!/usr/bin/env python3
"""Check native settings in a hidden CLI window with an in-memory workspace and certificate fake."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
core = root / "Packages/RequestmanCore"
source = root / "Requestman"
temporary = Path(tempfile.mkdtemp(prefix="requestman-settings-check-"))
flags = ["-swift-version", "6", "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx14.0",
         "-module-cache-path", str(core / ".build/host-typecheck-cache")]
try:
    for name, files in [
        ("RequestmanCore", sorted((core / "Sources/RequestmanCore").glob("*.swift"))),
        ("RequestmanCertificates", [core / "Sources/RequestmanCertificates" / filename for filename in ["CertificateService.swift", "CertificateSetupModel.swift"]]),
    ]:
        subprocess.run(["swiftc", *flags, "-module-name", name, "-emit-library", "-static", "-emit-module",
                        "-emit-module-path", str(temporary / f"{name}.swiftmodule"),
                        "-o", str(temporary / f"lib{name}.a"), *map(str, files)], check=True)
    files = [source / "Features/Workspace/AppKitSupport.swift", source / "Features/Workspace/WorkspaceSectionControl.swift"]
    files += sorted((source / "Features/Settings").glob("*.swift"))
    files += sorted((source / "Features/Environments").glob("*.swift"))
    files += [source / "Features/Connection/ConnectionSettingsView.swift", source / "Features/Connection/CertificateSetupView.swift"]
    for file in files:
        assert "import SwiftUI" not in file.read_text() and "NSHosting" not in file.read_text(), file
    executable = temporary / "check"
    subprocess.run(["swiftc", *flags, "-I", str(temporary), "-L", str(temporary), "-lRequestmanCore", "-lRequestmanCertificates",
                    *map(str, files), str(root / "Scripts/Fixtures/SettingsUIChecks.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
finally:
    subprocess.run(["trash", str(temporary)], check=True)
