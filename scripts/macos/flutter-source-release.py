#!/usr/bin/env python3
"""Bundle the macOS source inventory and upstream notices with a local candidate."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "apps/macos/flutter_ui"
TREES = ("cmd", "internal", "apps/macos", "scripts/macos", "shared", "third_party/licenses")
FILES = ("LICENSE", "README.md", "THIRD-PARTY.txt", "go.mod", "go.sum", "notice.json",
         "docs/agreement.md", "docs/privacy.md", "assets/branding/icon.png")
SKIP = {".git", ".dart_tool", ".DS_Store", ".build", ".swiftpm", "build", "__pycache__", "ephemeral",
        "xcuserdata", "Pods", "coverage", ".flutter-plugins-dependencies", ".gradle", ".idea"}


def sources():
    paths = set(FILES)
    for directory in TREES:
        for base, dirs, names in os.walk(ROOT / directory):
            dirs[:] = [d for d in dirs if d not in SKIP]
            for name in names:
                if name in SKIP or name.endswith((".pyc", ".iml", ".xcuserstate", ".swp")):
                    continue
                path = Path(base, name)
                if path.is_symlink() or path.suffix.lower() in {".key", ".p12", ".p8", ".pem", ".mobileprovision"}:
                    raise ValueError(f"Unexpected private input or symbolic link: {path}")
                paths.add(path.relative_to(ROOT).as_posix())
    return sorted(paths)


def inventory():
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources()}


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def verify_components(vendor):
    prism = json.loads((vendor / "UPSTREAM.json").read_bytes())["Prism UI"]
    root = vendor / "prism_ui"
    for name, original in prism["files"].items():
        data = (root / name).read_bytes()
        local = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        expected = prism.get("localPatches", {}).get(name, {}).get("localGitBlob", original)
        if local != expected:
            raise ValueError(f"Prism UI file differs from its reviewed upstream or patch: {name}")


def notices(contents):
    vendor = UI / "vendor"
    verify_components(vendor)
    framework = contents / "Frameworks/App.framework/Resources/flutter_assets"
    sdk = Path(os.environ.get("FREEV6_FLUTTER_SDK", ROOT / "build/flutter-toolchain/flutter"))
    out = contents / "Resources/Notices"
    out.mkdir(parents=True, exist_ok=True)
    for src, name in ((vendor / "flclash/LICENSE", "FlClash-LICENSE.txt"),
                      (vendor / "prism_ui/LICENSE", "PrismUI-LICENSE.txt"),
                      (vendor / "prism_ui/NOTICE", "PrismUI-NOTICE.txt"),
                      (vendor / "UPSTREAM.json", "Flutter-component-sources.json"),
                      (ROOT / "apps/macos/Resources/Flutter-Sources.md", "Flutter-Sources.md"),
                      (sdk / "LICENSE", "Flutter-LICENSE.txt")):
        shutil.copyfile(src, out / name)
    with gzip.open(framework / "NOTICES.Z", "rb") as stream, (out / "Flutter-Package-Notices.txt").open("wb") as dest:
        shutil.copyfileobj(stream, dest)
    (out / "macOS-source-sha256.json").write_bytes(encoded(inventory()))


def archive(destination, contents):
    manifest = inventory()
    data = encoded(manifest)
    if data != (contents / "Resources/Notices/macOS-source-sha256.json").read_bytes():
        raise SystemExit("Sources changed after candidate signing. Rebuild the candidate before making its source archive.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = destination.with_suffix(".tmp")
    with zipfile.ZipFile(temp, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for name, payload in [("macOS-source-sha256.json", data), *[(n, None) for n in manifest]]:
            path = ROOT / name
            info = zipfile.ZipInfo("FreeV6-source/" + name)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if payload is None and os.access(path, os.X_OK) else 0o100644) << 16
            bundle.writestr(info, payload if payload is not None else path.read_bytes())
    temp.replace(destination)
    print(hashlib.sha256(destination.read_bytes()).hexdigest(), destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("notices", "archive"):
        sub = commands.add_parser(command)
        sub.add_argument("--contents", type=Path, required=True)
        if command == "archive":
            sub.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "notices":
        notices(args.contents)
    else:
        archive(args.output, args.contents)
