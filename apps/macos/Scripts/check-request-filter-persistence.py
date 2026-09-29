#!/usr/bin/env python3
"""Check filter persistence using the history model without creating any UI."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
core = root / "Packages/RequestmanCore"
temporary = Path(tempfile.mkdtemp(prefix="requestman-filter-persistence-"))
flags = ["-swift-version", "6", "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx14.0",
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
        str(root / "Requestman/Features/Requests/ExecutionHistoryModel.swift"),
        str(root / "Scripts/Fixtures/RequestFilterPersistenceChecks.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
finally:
    subprocess.run(["trash", str(temporary)], check=True)
