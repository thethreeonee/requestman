#!/usr/bin/env python3
"""Check idle CPU using the actual inspector and table in a hidden CLI window."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
core = root / "Packages/RequestmanCore"
temporary = Path(tempfile.mkdtemp(prefix="requestman-inspector-performance-"))
architecture = platform.machine()
flags = ["-swift-version", "6", "-parse-as-library", "-target", f"{architecture}-apple-macosx14.0",
         "-module-cache-path", str(core / ".build/host-typecheck-cache")]

try:
    subprocess.run([
        "swiftc", *flags, "-module-name", "RequestmanCore", "-emit-library", "-static", "-emit-module",
        "-emit-module-path", str(temporary / "RequestmanCore.swiftmodule"),
        "-o", str(temporary / "libRequestmanCore.a"),
        *map(str, sorted((core / "Sources/RequestmanCore").glob("*.swift"))),
    ], check=True)
    executable = temporary / "check"
    subprocess.run([
        "swiftc", *flags, "-I", str(temporary), "-L", str(temporary), "-lRequestmanCore",
        str(root / "Requestman/Features/Workspace/AppKitSupport.swift"),
        str(root / "Requestman/Features/Workspace/WorkspaceView.swift"),
        str(root / "Requestman/Features/Workspace/WorkspaceSection.swift"),
        str(root / "Requestman/Features/Workspace/WorkspaceSplitView.swift"),
        str(root / "Requestman/Features/Rules/TemplateValuesView.swift"),
        str(root / "Requestman/Features/Workspace/WorkspaceSectionControl.swift"),
        *map(str, sorted(p for p in (root / "Requestman/Features/Requests").glob("Request*.swift"))),
        str(root / "Requestman/Features/Workspace/JSONSyntax.swift"),
        str(root / "Scripts/Fixtures/InspectorPerformanceChecks.swift"), "-o", str(executable),
    ], check=True)
    try:
        subprocess.run([str(executable)], check=True, timeout=60)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("Inspector performance CLI checks did not pass; inspect the assertion or runtime error above. "
              "WindowServer connection errors require a macOS GUI session. No visual acceptance is implied.", file=sys.stderr)
        raise
finally:
    try:
        cleanup = subprocess.run(["trash", str(temporary)], check=False)
        if cleanup.returncode:
            print(f"Temporary check files need cleanup with trash: {temporary}", file=sys.stderr)
    except OSError as error:
        print(f"Temporary check files need cleanup with trash: {temporary} ({error})", file=sys.stderr)
