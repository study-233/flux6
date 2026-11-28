#!/usr/bin/env python3
"""Build and verify the native Flux6 disk image on a Mac."""
import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import sign_flutter_host
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "dist/macos"
GUIDE = ROOT / "apps/macos/Resources/安装说明.txt"
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
    meta = plistlib.loads((payload / "Info.plist").read_bytes())
    release = plistlib.loads((ROOT / "apps/macos/Resources/Info.plist").read_bytes())
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
        if meta.get(key) != release[key]:
            raise RuntimeError(f"Unexpected {key} in {app}")
    for binary in ("Flux6", "FlClashCore"):
        slices = output("lipo", "-archs", payload / "MacOS" / binary).decode().split()
        if arch not in slices:
            raise RuntimeError(f"{binary} missing {arch}")
    sign_flutter_host.host_libraries(app)
    for name in ("FlClash-LICENSE.txt", "mihomo-LICENSE.txt", "PrismUI-NOTICE.txt"):
        if not (payload / "Resources/Notices" / name).is_file():
            raise RuntimeError(f"Missing license or notice: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-app", type=Path, help="verify an already built candidate and exit")
    parser.add_argument("--from-app", type=Path, help="package an already built candidate without rebuilding")
    parser.add_argument("--output-dir", type=Path, help="directory for versioned release artifacts")
    args = parser.parse_args()
    arch = platform.machine()
    if platform.system() != "Darwin" or arch not in ("arm64", "x86_64") or os.geteuid() == 0:
        raise SystemExit("Run as an ordinary user on an arm64 or x86_64 Mac")
    if args.verify_app:
        verify_bundle(args.verify_app, arch)
        return
    if not args.from_app:
        subprocess.run(["/bin/bash", ROOT / "scripts/macos/build-app.sh"], cwd=ROOT, check=True,
                       env={**os.environ, "CONFIGURATION": "release"})
    app = (args.from_app or OUTPUT / "Flux6.app").resolve()
    verify_bundle(app, arch)
    notices = app / "Contents/Resources/Notices"
    for name in ("privacy.md", "agreement.md"):
        if (notices / name).read_bytes() != (ROOT / "docs" / name).read_bytes():
            raise RuntimeError(f"Packaged notice differs: {name}")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+(?:\.\d+){1,2}", version) or info["LSMinimumSystemVersion"] != "14.0":
        raise RuntimeError("Unexpected release metadata")
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"[1-9]\d*", build):
        raise RuntimeError("Unexpected build number")
    destination = args.output_dir or OUTPUT / f"{version}-b{build}"
    filename = f"Flux6-{version}-macos-{arch}.dmg"
    zip_name = f"Flux6-{version}-b{build}-{arch}.zip"
    source_name = f"Flux6-{version}-b{build}-source.zip"
    artifact_names = (filename, zip_name, source_name, "SHA256SUMS")
    if any((destination / name).exists() for name in artifact_names):
        raise SystemExit(f"Release output already exists: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".disk-image-", dir=destination) as tmp:
        stage = Path(tmp)
        source = stage / "volume"
        source.mkdir()
        subprocess.run(["/usr/bin/ditto", app, source / app.name], check=True)
        (source / "Applications").symlink_to("/Applications")
        shutil.copyfile(GUIDE, source / GUIDE.name)
        image = stage / filename
        subprocess.run(["/usr/bin/hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "UDZO",
                        "-volname", "Flux6", "-srcfolder", source, image], check=True)
        subprocess.run(["/usr/bin/hdiutil", "verify", "-quiet", image], check=True)
        with readonly_volume(image) as volume:
            if os.readlink(volume / "Applications") != "/Applications" or (volume / GUIDE.name).read_bytes() != GUIDE.read_bytes():
                raise RuntimeError("Drag-install link or installation guide did not survive imaging")
            # Reproduce a drag-copy without touching the user's Applications.
            copied = stage / "Applications" / app.name
            subprocess.run(["/usr/bin/ditto", volume / app.name, copied], check=True)
            verify_bundle(copied, arch)
        archive = stage / zip_name
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive], check=True)
        unpacked = stage / "unpacked"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", archive, unpacked], check=True)
        verify_bundle(unpacked / app.name, arch)
        if sign_flutter_host.cdhash(unpacked / app.name) != sign_flutter_host.cdhash(app):
            raise RuntimeError("The ZIP contains a different app")
        source_archive = stage / source_name
        subprocess.run(["git", "archive", "--format=zip", "--prefix=Flux6/", "-o",
                        source_archive, "HEAD"], cwd=ROOT, check=True)
        sums = stage / "SHA256SUMS"
        sums.write_text("".join(f"{hashlib.sha256(item.read_bytes()).hexdigest()}  {item.name}\n"
                               for item in (image, archive, source_archive)))
        for name in artifact_names:
            (stage / name).replace(destination / name)
    artifact = destination / filename
    print(f"{artifact}\nSHA256 {hashlib.sha256(artifact.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
