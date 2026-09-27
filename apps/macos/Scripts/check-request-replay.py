#!/usr/bin/env python3
"""Check the replay editor with a send stub in hidden component windows."""
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
core = root / "Packages/RequestmanCore"
temporary = Path(tempfile.mkdtemp(prefix="requestman-replay-editor-check-"))
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
    import runpy
    editor_flags, editor_products = runpy.run_path(str(root / "Scripts/editor-package.py"))["editor_flags"](root, link=True)
    for bundle in editor_products.glob("*.bundle"):
        shutil.copytree(bundle, temporary / bundle.name)
    executable = temporary / "check"
    subprocess.run([
        "swiftc", *flags, "-I", str(temporary), "-L", str(temporary), "-lRequestmanCore", *editor_flags,
        str(root / "Requestman/Features/Workspace/AppKitSupport.swift"),
        str(root / "Requestman/Features/Requests/RequestReplayEditor.swift"),
        str(root / "Requestman/Features/Requests/ExecutionHistoryModel.swift"),
        str(root / "Scripts/Fixtures/RequestReplayEditorChecks.swift"), "-o", str(executable),
    ], check=True)
    try:
        subprocess.run([str(executable)], check=True, timeout=45)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("Replay editor CLI checks did not pass; inspect the assertion or runtime error above. "
              "WindowServer connection errors require a macOS GUI session. No visual acceptance is implied.", file=sys.stderr)
        raise
finally:
    try:
        cleanup = subprocess.run(["trash", str(temporary)], check=False)
        if cleanup.returncode:
            print(f"Temporary check files need cleanup with trash: {temporary}", file=sys.stderr)
    except OSError as error:
        print(f"Temporary check files need cleanup with trash: {temporary} ({error})", file=sys.stderr)
