"""Build/link the standalone editor for host checks (no App build)."""
from pathlib import Path
import subprocess


def editor_flags(root: Path, *, link=False):
    package = root / "Packages/RequestmanEditor"
    subprocess.run(["swift", "build", "--package-path", str(package), "--product", "RequestmanEditor"], check=True,
                   stdout=subprocess.DEVNULL)
    build = package / ".build"
    candidates = [build / "out/Products/Debug"] + list(build.glob("*/debug"))
    products = next(path for path in candidates if (path / "libRequestmanEditor.a").exists())
    modules = products / "Modules" if (products / "Modules").exists() else products
    flags = ["-I", str(modules), "-I", str(products / "include")]
    maps = list((build / "out/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"))
    maps += list(build.glob("*/debug/*.build/module.modulemap"))
    for path in maps:
        if "-Swift.h" not in path.read_text():
            flags += ["-Xcc", "-fmodule-map-file=" + str(path)]
    for path in (build / "checkouts/CodeEditTextView/Sources").rglob("module.modulemap"):
        flags += ["-I", str(path.parent)]
    if link:
        flags += ["-L", str(products), "-lRequestmanEditor"]
    return flags, products
