#!/usr/bin/env python3
"""Build and verify the native FreeV6 disk image on a Mac."""
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "dist/macos"
GUIDE = ROOT / "macos/Resources/安装说明.txt"
BINARIES = (
    "MacOS/FreeV6", "Helpers/freev6-worker", "Helpers/freev6-service-installer",
    "Library/LaunchServices/dev.freev6.network-service",
)


def output(*args):
    return subprocess.check_output(args)


@contextmanager
def readonly_volume(image):
    # Keep the mount outside recursive staging cleanup. On detach failure
    # leave its exact mountpoint visible for the developer to eject.
    mount = Path(tempfile.mkdtemp(prefix="freev6-mount-")).resolve()
    try:
        attached = output("/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-readonly",
                          "-mountpoint", mount, "-plist", image)
        entities = plistlib.loads(attached)["system-entities"]
        mounts = [Path(e["mount-point"]).resolve() for e in entities if "mount-point" in e]
        if mounts != [mount] or not (os.statvfs(mount).f_flag & os.ST_RDONLY):
            raise RuntimeError("Expected a single read-only volume at " + str(mount))
        yield mount
    finally:
        if mount.is_mount():
            subprocess.run(["/usr/bin/hdiutil", "detach", mount], check=True)
        if mount.exists():
            mount.rmdir()


def verify_bundle(app, arch):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    payload = app / "Contents"
    for relative in BINARIES:
        binary = payload / relative
        if output("/usr/bin/lipo", "-archs", binary).decode().split() != [arch]:
            raise RuntimeError(f"Unexpected architecture in {relative}")
        build = output("/usr/bin/xcrun", "vtool", "-show-build", binary).decode()
        minima = re.findall(r"^\s*minos\s+([\d.]+)$", build, re.M)
        if not re.search(r"^\s*platform\s+MACOS$", build, re.M) or len(minima) != 1:
            raise RuntimeError(f"Missing macOS deployment target in {relative}")
        version = tuple(int(part) for part in minima[0].split("."))
        if version + (0,) * (3 - len(version)) > (13, 0, 0):
            raise RuntimeError(f"{relative} requires macOS {minima[0]}")
    manifest = json.loads(output(payload / "Helpers/freev6-service-installer", "manifest"))
    digest = hashlib.sha256((payload / BINARIES[-1]).read_bytes()).hexdigest()
    if manifest["serviceSHA256"] != digest:
        raise RuntimeError("Packaged service does not match its signed installer manifest")


def main():
    arch = platform.machine()
    if platform.system() != "Darwin" or arch not in ("arm64", "x86_64") or os.geteuid() == 0:
        raise SystemExit("Run as an ordinary user on an arm64 or x86_64 Mac")
    subprocess.run(["/bin/bash", ROOT / "scripts/macos/build-app.sh"], cwd=ROOT, check=True,
                   env={**os.environ, "CONFIGURATION": "release"})
    app = OUTPUT / "FreeV6.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+(?:\.\d+){1,2}", version) or info["LSMinimumSystemVersion"] != "13.0":
        raise RuntimeError("Unexpected release metadata")
    filename = f"FreeV6_{version}-preview_{arch}.dmg"
    with tempfile.TemporaryDirectory(prefix=".disk-image-", dir=OUTPUT) as tmp:
        stage = Path(tmp)
        source = stage / "volume"
        source.mkdir()
        subprocess.run(["/usr/bin/ditto", app, source / app.name], check=True)
        (source / "Applications").symlink_to("/Applications")
        shutil.copyfile(GUIDE, source / GUIDE.name)
        image = stage / filename
        subprocess.run(["/usr/bin/hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "UDZO",
                        "-volname", "FreeV6", "-srcfolder", source, image], check=True)
        subprocess.run(["/usr/bin/hdiutil", "verify", "-quiet", image], check=True)
        with readonly_volume(image) as volume:
            if os.readlink(volume / "Applications") != "/Applications" or (volume / GUIDE.name).read_bytes() != GUIDE.read_bytes():
                raise RuntimeError("Drag-install link or installation guide did not survive imaging")
            # Reproduce a drag-copy without touching the user's Applications.
            copied = stage / "Applications" / app.name
            subprocess.run(["/usr/bin/ditto", volume / app.name, copied], check=True)
            verify_bundle(copied, arch)
        image.replace(OUTPUT / filename)
    artifact = OUTPUT / filename
    print(f"{artifact}\nSHA256 {hashlib.sha256(artifact.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
