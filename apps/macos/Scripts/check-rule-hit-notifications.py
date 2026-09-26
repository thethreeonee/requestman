#!/usr/bin/env python3
"""Exercise notification delivery with a fake center; never request real permission or post notifications."""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
core = root / "Packages/RequestmanCore"
temporary = Path(tempfile.mkdtemp(prefix="requestman-rule-notification-check-"))
flags = ["-swift-version", "6", "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx14.0",
         "-module-cache-path", str(core / ".build/host-typecheck-cache")]
try:
    subprocess.run(["swiftc", *flags, "-module-name", "RequestmanCore", "-emit-library", "-static", "-emit-module",
                    "-emit-module-path", str(temporary / "RequestmanCore.swiftmodule"),
                    "-o", str(temporary / "libRequestmanCore.a"),
                    str(core / "Sources/RequestmanCore/RuleHitNotification.swift")], check=True)
    executable = temporary / "check"
    subprocess.run(["swiftc", *flags, "-I", str(temporary), "-L", str(temporary), "-lRequestmanCore",
                    str(root / "Requestman/Infrastructure/Capture/SystemRuleHitNotifications.swift"),
                    str(root / "Scripts/Fixtures/RuleHitNotificationChecks.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
finally:
    subprocess.run(["trash", str(temporary)], check=True)
