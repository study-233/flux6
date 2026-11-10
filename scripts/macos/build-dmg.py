#!/usr/bin/env python3
"""Build and verify the native FreeV6 disk image on a Mac."""
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
import release_rpaths
import sign_flutter_host
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "dist/macos"
GUIDE = ROOT / "apps/macos/Resources/安装说明.txt"
BINARIES = (
    "MacOS/FreeV6", "Helpers/freev6-worker", "Helpers/freev6-service-installer", "Helpers/freev6-login-launcher",
    "Helpers/FreeV6UpdateAgent.app/Contents/MacOS/freev6-update-agent",
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
    agent = payload / "Helpers/FreeV6UpdateAgent.app"
    agent_info = plistlib.loads((agent / "Contents/Info.plist").read_bytes())
    if agent_info.get("FreeV6UpdateProbeBuild") is not False:
        raise RuntimeError("Product bundles must contain the production update helper")
    rights = plistlib.loads(output("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", agent))
    if rights != {"com.apple.security.cs.disable-library-validation": True}:
        raise RuntimeError("Unexpected update helper entitlements")
    dependencies = output("/usr/bin/otool", "-L", payload / "MacOS/FreeV6").decode()
    if "@rpath/FlutterMacOS.framework/" not in dependencies or "Sparkle.framework" in dependencies:
        raise RuntimeError("The host must load Flutter, with Sparkle confined to the update helper")
    host = plistlib.loads((payload / "Info.plist").read_bytes())
    if host["LSMinimumSystemVersion"] != "14.0" or agent_info["LSMinimumSystemVersion"] != "14.0":
        raise RuntimeError("The host and its update helper must target macOS 14")
    if host.get("CFBundleIdentifier") != "dev.freev6.desktop" or host.get("CFBundleExecutable") != "FreeV6" or host.get("NSMainNibFile") != "MainMenu":
        raise RuntimeError("Missing the production Flutter application identity or main nib")
    if not (payload / "Resources/Base.lproj/MainMenu.nib").exists():
        raise RuntimeError("Missing compiled app entry nib")
    allowed_helpers = {"freev6-worker", "freev6-service-installer", "freev6-login-launcher", "FreeV6UpdateAgent.app"}
    if {item.name for item in (payload / "Helpers").iterdir()} != allowed_helpers:
        raise RuntimeError("Unexpected executables in the production Helpers directory")
    runner = (payload / "MacOS/FreeV6").read_bytes()
    for marker in (b"FreeV6QAStartupNotices", b"qaWindowInfo", b"freev6-session-fixture", b"dev.freev6.flutter-host.qa."):
        if marker in runner:
            raise RuntimeError("An acceptance-only backend or channel was linked into the release")
    frameworks = sign_flutter_host.host_libraries(app)
    assets = frameworks[0] / "Resources/flutter_assets"
    if not (assets / "AssetManifest.bin").is_file() or (assets / "kernel_blob.bin").exists():
        raise RuntimeError("Missing release Flutter assets or unexpected debug Dart kernel")
    for lib in frameworks:
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", lib], check=True)
    framework_bins = [str((lib / lib.stem).relative_to(payload)) for lib in frameworks]
    identities = {"MacOS/FreeV6": "dev.freev6.desktop", "Helpers/freev6-worker": "dev.freev6.worker",
                  "Helpers/freev6-service-installer": "dev.freev6.service-installer",
                  "Helpers/freev6-login-launcher": "dev.freev6.desktop.login",
                  BINARIES[-2]: "dev.freev6.desktop.update-agent", BINARIES[-1]: "dev.freev6.network-service"}
    for relative in (*BINARIES, *framework_bins):
        binary = payload / relative
        signature = subprocess.run(["/usr/bin/codesign", "-dvv", binary], check=True, capture_output=True, text=True).stderr
        if not re.search(r"^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)", signature, re.M):
            raise RuntimeError(f"The hardened runtime is missing on {relative}")
        if relative in identities and f"Identifier={identities[relative]}\n" not in signature:
            raise RuntimeError(f"Unexpected code identity on {relative}")
        if relative in BINARIES:
            release_rpaths.verify(binary, updater=binary.name in ("FreeV6", "freev6-update-agent"))
        if output("/usr/bin/lipo", "-archs", binary).decode().split() != [arch]:
            raise RuntimeError(f"Unexpected architecture in {relative}")
        build = output("/usr/bin/xcrun", "vtool", "-show-build", binary).decode()
        minima = re.findall(r"^\s*minos\s+([\d.]+)$", build, re.M)
        if not re.search(r"^\s*platform\s+MACOS$", build, re.M) or len(minima) != 1:
            raise RuntimeError(f"Missing macOS deployment target in {relative}")
        version = tuple(int(part) for part in minima[0].split("."))
        if version + (0,) * (3 - len(version)) > (14, 0, 0):
            raise RuntimeError(f"{relative} requires macOS {minima[0]}")
        if relative == "MacOS/FreeV6":
            sdk = re.search(r"^\s*sdk\s+([\d.]+)$", build, re.M)
            if version[:2] != (14, 0) or not sdk or int(sdk[1].split(".")[0]) < 26:
                raise RuntimeError(f"Expected a macOS 14 app linked against a modern SDK: {build}")
    manifest = json.loads(output(payload / "Helpers/freev6-service-installer", "manifest"))
    digest = hashlib.sha256((payload / BINARIES[-1]).read_bytes()).hexdigest()
    if manifest.get("flutterClientSeal"):
        rights = plistlib.loads(output("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app))
        if rights != sign_flutter_host.LOCAL_RIGHTS:
            raise RuntimeError("The local Flutter program must carry only its pinned library constraint exception")
        probe = Path(output("bash", ROOT / "scripts/macos/swift.sh", "build", "-c", "release", "--show-bin-path").decode().strip()) / "freev6-probe"
        if output(probe, "flutter-client-seal", payload / "MacOS/FreeV6").decode().strip() != manifest["flutterClientSeal"]:
            raise RuntimeError("Flutter client's program or kernel constraint does not match the trusted installer")
    elif output("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app).strip():
        raise RuntimeError("Unexpected entitlements in a Team-signed production host")
    if manifest["serviceSHA256"] != digest:
        raise RuntimeError("Packaged service does not match its signed installer manifest")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-app", type=Path, help="verify an already built candidate and exit")
    parser.add_argument("--from-app", type=Path, help="package an already built candidate without rebuilding")
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
    app = (args.from_app or OUTPUT / "FreeV6.app").resolve()
    verify_bundle(app, arch)
    notices = app / "Contents/Resources/Notices"
    expected_privacy = (ROOT / "apps/macos/Resources/privacy-macos.md").read_bytes() + b"\n\n" + (ROOT / "docs/privacy.md").read_bytes()
    if (notices / "privacy.md").read_bytes() != expected_privacy or (notices / "agreement.md").read_bytes() != (ROOT / "docs/agreement.md").read_bytes():
        raise RuntimeError("The packaged startup notices do not match this build")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+(?:\.\d+){1,2}", version) or info["LSMinimumSystemVersion"] != "14.0":
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
        zip_name = f"FreeV6_{version}_{info['CFBundleVersion']}_{arch}.zip"
        archive = stage / zip_name
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive], check=True)
        unpacked = stage / "unpacked"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", archive, unpacked], check=True)
        verify_bundle(unpacked / app.name, arch)
        if sign_flutter_host.cdhash(unpacked / app.name) != sign_flutter_host.cdhash(app):
            raise RuntimeError("The ZIP contains a different app")
        sums = stage / "SHA256SUMS"
        sums.write_text("".join(f"{hashlib.sha256(item.read_bytes()).hexdigest()}  {item.name}\n" for item in (image, archive)))
        image.replace(OUTPUT / filename)
        archive.replace(OUTPUT / zip_name)
        sums.replace(OUTPUT / "SHA256SUMS")
    artifact = OUTPUT / filename
    print(f"{artifact}\nSHA256 {hashlib.sha256(artifact.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
