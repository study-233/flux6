#!/usr/bin/env python3
"""Embed and sign the ordinary-user updater in an unsealed staged application."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def bundle(app, executable, sdk, *, probe=False):
    agent = app / "Contents/Helpers/FreeV6UpdateAgent.app"
    contents = agent / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    shutil.copy2(executable, contents / "MacOS/freev6-update-agent")
    host = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    info = {"CFBundleIdentifier": host["CFBundleIdentifier"] + ".update-agent",
            "CFBundleName": "FreeV6 更新", "CFBundleExecutable": "freev6-update-agent",
            "CFBundlePackageType": "APPL", "CFBundleVersion": host["CFBundleVersion"],
            "LSMinimumSystemVersion": "13.0", "LSUIElement": True,
            "FreeV6UpdateProbeBuild": probe,
            "NSPrincipalClass": "NSApplication"}
    if probe:
        info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    framework = contents / "Frameworks/Sparkle.framework"
    shutil.copytree(sdk / "Sparkle.framework", framework, symlinks=True)
    for component in ("XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "Autoupdate", "Updater.app"):
        run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", framework / "Versions/B" / component)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", framework)
    rights = contents / "Resources"
    rights.mkdir()
    entitlement = rights / "update-agent.entitlements"
    entitlement.write_bytes(plistlib.dumps({"com.apple.security.cs.disable-library-validation": True}))
    run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlement, agent)
    notices = app / "Contents/Resources/Notices"
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(sdk / "LICENSE", notices / "Sparkle-LICENSE.txt")


def configure_channel(app, path):
    spec = json.loads(path.read_text())
    if set(spec) != {"format", "publicKey", "feeds"} or spec["format"] != 1:
        raise ValueError("Invalid release channel configuration")
    import base64
    import platform
    from urllib.parse import urlsplit
    arch = platform.machine()
    feed = spec["feeds"][arch]
    location = urlsplit(feed)
    if (len(base64.b64decode(spec["publicKey"], validate=True)) != 32 or location.scheme != "https"
            or not location.hostname or location.username or location.password or location.query or location.fragment
            or not location.path.endswith("/appcast-" + arch + ".xml")):
        raise ValueError("Release channel requires HTTPS and an Ed25519 public key")
    file = app / "Contents/Info.plist"
    info = plistlib.loads(file.read_bytes())
    info.update(SUFeedURL=feed, SUPublicEDKey=spec["publicKey"], SURequireSignedFeed=True,
                SUVerifyUpdateBeforeExtraction=True, SUSignedFeedFailureExpirationInterval=0,
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                SUEnableSystemProfiling=False, SUShowReleaseNotes=False, SURelaunchHostBundle=True)
    file.write_bytes(plistlib.dumps(info))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("executable", type=Path)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("--channel", type=Path)
    args = parser.parse_args()
    if args.channel:
        configure_channel(args.app, args.channel)
    bundle(args.app, args.executable, args.sdk)
