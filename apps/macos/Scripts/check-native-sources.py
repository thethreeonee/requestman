#!/usr/bin/env python3
"""Check project references; optionally typecheck host Swift sources without building an App."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--typecheck", action="store_true", help="Requires the core package to have been tested first")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
project = root / "Requestman.xcodeproj"
objects = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")]))["objects"]
sources = set((root / "Requestman").rglob("*.swift"))
ui_sources = sources | set((root / "Scripts/Fixtures").glob("*.swift"))
for source in ui_sources:
    assert not re.search(r"\bimport\s+SwiftUI\b|\bNSHosting(?:View|Controller)\b|\bNSView(?:Controller)?Representable\b|@(?:State|Binding|Bindable|Environment|FocusState)\b", source.read_text()), (
        f"AppKit-only UI contract violated: {source.relative_to(root)}"
    )
references = {key: root / value["path"] for key, value in objects.items()
              if value.get("isa") == "PBXFileReference" and value.get("path", "").endswith(".swift")}
assert set(references.values()) == sources, "Swift source files and project references differ"
compiled_refs = {objects[file]["fileRef"] for value in objects.values() if value.get("isa") == "PBXSourcesBuildPhase" for file in value["files"]}
assert compiled_refs == set(references), "Source build phase is missing files or includes stale files"
icon = root / "Requestman/Resources/AppIcon.icon"
icon_refs = {key for key, value in objects.items()
             if value.get("isa") == "PBXFileReference"
             and value.get("path") == str(icon.relative_to(root))
             and value.get("lastKnownFileType") == "folder.iconcomposer.icon"}
resource_refs = {objects[file]["fileRef"] for value in objects.values()
                 if value.get("isa") == "PBXResourcesBuildPhase" for file in value["files"]}
assert len(icon_refs) == 1 and icon_refs <= resource_refs, "AppIcon.icon must be compiled as a target resource"
assert re.search(r"^ASSETCATALOG_COMPILER_APPICON_NAME\s*=\s*AppIcon\s*$",
                 (root / "Configuration/Base.xcconfig").read_text(), re.MULTILINE), "App icon name is not configured"
icon_document = json.loads((icon / "icon.json").read_text())
icon_layers = [layer for group in icon_document["groups"] for layer in group["layers"]]
assert icon_layers, "App icon has no foreground artwork"
for layer in icon_layers:
    assert (icon / "Assets" / layer["image-name"]).is_file(), "Missing app icon layer asset"
print("Icon Composer document, layer assets and target resource reference OK")
products = {value.get("productName") for value in objects.values() if value.get("isa") == "XCSwiftPackageProductDependency"}
required_products = {"RequestmanCore", "RequestmanProxy", "RequestmanCertificates"}
assert required_products <= products, "Missing local package products"
project_object = next(value for value in objects.values() if value.get("isa") == "PBXProject")
project_configs = {
    objects[key]["name"]: objects[key]["buildSettings"]
    for key in objects[project_object["buildConfigurationList"]]["buildConfigurations"]
}
assert project_configs["Debug"].get("ONLY_ACTIVE_ARCH") == "YES", (
    "Debug must use ONLY_ACTIVE_ARCH=YES to match Swift Package dependency architectures"
)
assert project_configs["Release"].get("ONLY_ACTIVE_ARCH") == "NO", "Release must retain all supported architectures"
for value in objects.values():
    if value.get("isa") == "PBXNativeTarget":
        for key in objects[value["buildConfigurationList"]]["buildConfigurations"]:
            config = objects[key]
            expected = project_configs[config["name"]]["ONLY_ACTIVE_ARCH"]
            assert config["buildSettings"].get("ONLY_ACTIVE_ARCH", expected) == expected, (
                f"{value['name']} overrides the {config['name']} architecture policy"
            )
for scheme in (project / "xcshareddata/xcschemes").glob("*.xcscheme"):
    for ref in ET.parse(scheme).iter("BuildableReference"):
        assert objects[ref.attrib["BlueprintIdentifier"]]["isa"] == "PBXNativeTarget"
print(f"Project references OK: {len(sources)} Swift sources, local packages, shared scheme and architecture settings")
print("AppKit-only source and UI fixture checks OK")

if args.typecheck:
    build = root / "Packages/RequestmanCore/.build"
    candidates = list(build.glob("*/debug/Modules")) + [build / "out/Products/Debug"]
    product_dir = next((path for path in candidates
                        if all((path / f"{name}.swiftmodule").exists() for name in required_products)), None)
    assert product_dir, "Run swift test --package-path apps/macos/Packages/RequestmanCore first"
    command = ["swiftc", "-typecheck", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macosx14.0",
               "-module-cache-path", str(build / "host-typecheck-cache"), "-I", str(product_dir), "-I", str(product_dir / "include")]
    maps = list((build / "out/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"))
    maps += list(build.glob("*/debug/*.build/module.modulemap"))
    for module_map in maps:
        if "-Swift.h" not in module_map.read_text():
            command += ["-Xcc", "-fmodule-map-file=" + str(module_map)]
    for module_map in (build / "checkouts").rglob("module.modulemap"):
        command += ["-I", str(module_map.parent)]
    command += list(map(str, sorted(sources)))
    subprocess.run(command, check=True)
    print("Host Swift 6 typecheck OK (no App built or run)")
