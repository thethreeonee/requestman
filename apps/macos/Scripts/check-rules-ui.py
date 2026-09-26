#!/usr/bin/env python3
"""Exercise real AppKit rules controllers in a hidden CLI window, without building the App."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
core = root / "Packages/RequestmanCore"
temporary = Path(tempfile.mkdtemp(prefix="requestman-rules-check-"))
flags = ["-swift-version", "6", "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx14.0",
         "-module-cache-path", str(core / ".build/host-typecheck-cache")]
try:
    subprocess.run(["swiftc", *flags, "-module-name", "RequestmanCore", "-emit-library", "-static", "-emit-module",
                    "-emit-module-path", str(temporary / "RequestmanCore.swiftmodule"), "-o", str(temporary / "libRequestmanCore.a"),
                    *map(str, sorted((core / "Sources/RequestmanCore").glob("*.swift")))], check=True)
    binary = temporary / "check"
    subprocess.run(["swiftc", *flags, "-I", str(temporary), "-L", str(temporary), "-lRequestmanCore",
                    str(root / "Requestman/Features/Workspace/AppKitSupport.swift"),
                    *map(str, sorted((root / "Requestman/Features/Rules").glob("*.swift"))),
                    str(root / "Scripts/Fixtures/RulesUIChecks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=45)
finally:
    subprocess.run(["trash", str(temporary)], check=True)
