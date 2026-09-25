#!/usr/bin/env python3
"""Verify extension Header parity and the native editable combo binding in a hidden window."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "Requestman/Features/Rules/HeaderNameField.swift"
extension = (root.parent / "browser-extension/src/requestman/layout/config-area/forms/ModifyHeadersRuleDetail.tsx").read_text()
expected = re.findall(r"'([^']+)'", extension.split("const COMMON_HEADERS = [")[1].split("];", 1)[0])
actual = re.findall(r'"([^"\n]+)"', source.read_text().split("static let suggestions = [")[1].split("]", 1)[0])
assert actual == expected, "macOS Header suggestions must match extension names and order"
print(f"Header parity OK: {len(actual)} extension entries", flush=True)
temporary = Path(tempfile.mkdtemp(prefix="requestman-headers-check-"))
try:
    binary = temporary / "check"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                    "-module-cache-path", str(root / "Packages/RequestmanCore/.build/host-typecheck-cache"),
                    str(source), str(root / "Scripts/Fixtures/HeaderNameFieldChecks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
finally:
    subprocess.run(["trash", str(temporary)], check=True)
