#!/usr/bin/env python3
"""Produce a signed, architecture-specific update ZIP and appcast without publishing."""
import sign_flutter_host
import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import runpy
import stat
import subprocess
import tempfile
from urllib.parse import urlsplit
from xml.sax.saxutils import quoteattr
import github_channel

ROOT = Path(__file__).resolve().parents[2]


def run(*args, private=None):
    result = subprocess.run([str(a) for a in args], input=private, capture_output=True, timeout=180)
    if result.returncode:
        # Signing diagnostics may include input metadata. Return a fixed category.
        raise RuntimeError(Path(str(args[0])).name + " failed while preparing the update")
    return result.stdout.decode().strip()


def main(resources):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/macos/Flux6.app")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--channel", required=True, type=Path)
    parser.add_argument("--private-key", required=True, type=Path)
    parser.add_argument("--download-base", help="HTTPS asset directory for a custom channel")
    parser.add_argument("--build", required=True, type=int)
    parser.add_argument("--version", required=True)
    parser.add_argument("--minimum-source-build", required=True, type=int)
    parser.add_argument("--maximum-source-build", required=True, type=int)
    args = parser.parse_args()
    if not (0 < args.minimum_source_build <= args.maximum_source_build < args.build <= 9_999_999_999):
        parser.error("Builds must specify an increasing compatibility window")
    if not re.fullmatch(r"[0-9]{1,6}(\.[0-9]{1,6}){1,3}", args.version):
        parser.error("Use a numeric short version")
    arch = platform.machine()
    channel = json.loads(args.channel.read_text())
    if channel["feeds"].get(arch) == github_channel.feed_url(arch):
        base = github_channel.download_base(args.version)
        if args.download_base is not None and args.download_base.rstrip("/") != base:
            parser.error("The project channel requires the matching versioned GitHub release")
    elif args.download_base:
        base = args.download_base.rstrip("/")
    else:
        parser.error("A custom channel requires --download-base")
    location = urlsplit(base)
    if location.scheme != "https" or not location.hostname or location.username or location.password or location.query or location.fragment:
        parser.error("Download base must be an HTTPS directory")
    fd = os.open(args.private_key, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 256:
            raise RuntimeError("Release key must be a private, owner-controlled regular file")
        private = os.read(fd, 257)
    finally:
        os.close(fd)
    sdk_root = Path(resources.enter_context(tempfile.TemporaryDirectory(prefix="release-sdk-", dir=ROOT / "build")))
    sdk = Path(run("python3", ROOT / "scripts/macos/prepare-sparkle.py", "--directory", sdk_root / "distribution"))
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    env["CLANG_MODULE_CACHE_PATH"] = str(ROOT / "build/macos-module-cache")
    # Verify the supplied secret matches the channel's pinned public key before
    # producing an update that old clients would be unable to authenticate.
    with tempfile.TemporaryDirectory(prefix="release-check-", dir=ROOT / "build") as temporary:
        verifier = Path(temporary) / "verify-key"
        subprocess.run(["/usr/bin/xcrun", "swiftc", str(ROOT / "apps/macos/Tools/VerifyUpdateKey.swift"),
                        "-o", str(verifier)], env=env, check=True, capture_output=True)
        run(verifier, channel["publicKey"], private=private)
    verify_bundle = runpy.run_path(str(ROOT / "scripts/macos/build-dmg.py"))["verify_bundle"]
    verify_bundle(args.app, arch)
    if args.output.exists():
        parser.error("Output directory must be new")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".freev6-release-", dir=args.output.parent) as temporary:
        products = Path(temporary) / "products"
        products.mkdir()
        app = Path(temporary) / "Flux6.app"
        run("/usr/bin/ditto", args.app, app)
        file = app / "Contents/Info.plist"
        host = plistlib.loads(file.read_bytes())
        if host["CFBundleIdentifier"] != "dev.freev6.desktop":
            raise ValueError("Expected the Flux6 product bundle")
        host.update(CFBundleVersion=str(args.build), CFBundleShortVersionString=args.version)
        file.write_bytes(plistlib.dumps(host))
        runpy.run_path(str(ROOT / "scripts/macos/bundle-updater.py"))["configure_channel"](app, args.channel)
        service = app / "Contents/Library/LaunchServices/dev.freev6.network-service"
        requirements = {"format": 1, "build": args.build, "minimumSourceBuild": args.minimum_source_build,
                        "maximumSourceBuild": args.maximum_source_build, "architecture": arch,
                        "workerProtocol": 1, "serviceProtocol": 6, "settingsSchema": 1,
                        "runtimeCatalogSHA256": hashlib.sha256((app / "Contents/Resources/runtime-assets.json").read_bytes()).hexdigest(),
                        "serviceSHA256": hashlib.sha256(service.read_bytes()).hexdigest()}
        metadata = json.dumps(requirements, sort_keys=True, separators=(",", ":")).encode()
        (app / "Contents/Resources/update-compatibility.json").write_bytes(metadata)
        agent = app / "Contents/Helpers/Flux6UpdateAgent.app"
        agent_info_file = agent / "Contents/Info.plist"
        agent_info = plistlib.loads(agent_info_file.read_bytes())
        agent_info["CFBundleVersion"] = str(args.build)
        agent_info_file.write_bytes(plistlib.dumps(agent_info))
        signing = ["/usr/bin/codesign", "--force", "--sign", os.environ.get("FREEV6_CODESIGN_IDENTITY", "-"), "--options", "runtime"]
        if keychain := os.environ.get("FREEV6_CODESIGN_KEYCHAIN"):
            signing += ["--keychain", keychain]
        run(*signing, "--entitlements", agent / "Contents/Resources/update-agent.entitlements", agent)
        sign_flutter_host.sign_host(app, os.environ.get("FREEV6_CODESIGN_IDENTITY", "-"))
        verify_bundle(app, arch)
        package = products / ("Flux6_" + args.version + "_" + str(args.build) + "_" + arch + ".zip")
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, package)
        signature = run(sdk / "bin/sign_update", "--ed-key-file", "-", "-p", package, private=private)
        encoded = base64.b64encode(metadata).decode()
        xml = ('<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
               'xmlns:freev6="urn:freev6:update:1"><channel><title>Flux6 macOS</title><item>'
               f'<title>Flux6 {args.version}</title><sparkle:version>{args.build}</sparkle:version>'
               f'<sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>'
               f'<sparkle:minimumSystemVersion>{host["LSMinimumSystemVersion"]}</sparkle:minimumSystemVersion>'
               f'<enclosure url={quoteattr(base + "/" + package.name)} '
               f'sparkle:edSignature={quoteattr(signature)} length="{package.stat().st_size}" '
               f'type="application/octet-stream" freev6:requirements={quoteattr(encoded)}/></item></channel></rss>')
        appcast = products / ("appcast-" + arch + ".xml")
        appcast.write_text(xml)
        run(sdk / "bin/sign_update", "--ed-key-file", "-", appcast, private=private)
        run(sdk / "bin/sign_update", "--verify", "--ed-key-file", "-", appcast, private=private)
        run(sdk / "bin/sign_update", "--verify", "--ed-key-file", "-", package, signature, private=private)
        (products / "SHA256SUMS").write_text("\n".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name
                                                        for p in (package, appcast)) + "\n")
        products.replace(args.output)
    print(args.output.resolve())


if __name__ == "__main__":
    with contextlib.ExitStack() as resources:
        main(resources)
