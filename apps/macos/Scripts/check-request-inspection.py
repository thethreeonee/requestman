#!/usr/bin/env python3
"""Exercise inspector diff/tree data and bounded body decoding without launching an App."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
temporary = Path(tempfile.mkdtemp(prefix="requestman-inspection-check-"))
core = root / "Packages/RequestmanCore"
flags = ["-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macosx14.0",
         "-module-cache-path", str(core / ".build/host-typecheck-cache")]

try:
    # Use actual public contracts, independent of stale Xcode/SwiftPM module caches.
    subprocess.run([
        "swiftc", *flags, "-module-name", "RequestmanCore", "-emit-library", "-static", "-emit-module",
        "-emit-module-path", str(temporary / "RequestmanCore.swiftmodule"),
        "-o", str(temporary / "libRequestmanCore.a"),
        *map(str, sorted((core / "Sources/RequestmanCore").glob("*.swift"))),
    ], check=True)
    sources = root / "Requestman/Features/Requests"
    executable = temporary / "check"
    subprocess.run([
        "swiftc", *flags, "-I", str(temporary), "-L", str(temporary), "-lRequestmanCore",
        str(sources / "RequestDataOutline.swift"), str(sources / "RequestInspectionData.swift"),
        str(sources / "RequestBodyDecoding.swift"), str(sources / "RequestPayloadPresentation.swift"),
        str(sources / "RequestCURL.swift"),
        str(root / "Scripts/Fixtures/RequestInspectionChecks.swift"),
        str(root / "Scripts/Fixtures/RequestBodyDecodingChecks.swift"),
        str(root / "Scripts/Fixtures/RequestPayloadPresentationChecks.swift"),
        str(root / "Scripts/Fixtures/RequestCURLChecks.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
finally:
    # A sandbox may allow the checks but deny writing to the system Trash.
    # Keep that cleanup issue separate from the compiler/algorithm result.
    try:
        cleanup = subprocess.run(["trash", str(temporary)], check=False)
        if cleanup.returncode:
            print(f"Temporary check files need cleanup with trash: {temporary}", file=sys.stderr)
    except OSError as error:
        print(f"Temporary check files need cleanup with trash: {temporary} ({error})", file=sys.stderr)
