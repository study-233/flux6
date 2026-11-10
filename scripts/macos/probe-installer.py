#!/usr/bin/env python3
"""Verify real signed installation payloads without installing a root service."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(args, *, check=True):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=180)
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--app", type=Path, default=ROOT / "dist/macos/FreeV6.app",
                        help="Verify this already built application with --no-build.")
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError("This is an unprivileged payload probe")
    if not args.no_build:
        run(["bash", ROOT / "scripts/macos/build-app.sh"])
        run(["bash", ROOT / "scripts/macos/swift.sh", "build", "-c", "release", "--product", "freev6-probe"])
    binary_dir = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "-c", "release", "--show-bin-path"]).stdout.strip())
    probe = binary_dir / "freev6-probe"
    app = args.app.resolve(strict=True)
    helper = app / "Contents/Helpers/freev6-service-installer"
    service = app / "Contents/Library/LaunchServices/dev.freev6.network-service"
    manifest = json.loads(run([helper, "manifest"]).stdout)
    digest = hashlib.sha256(service.read_bytes()).hexdigest()
    if digest != manifest["serviceSHA256"]:
        raise RuntimeError("Embedded service digest does not match packaged service")
    work = ROOT / "build/installer-probes" / str(uuid.uuid4())
    work.mkdir(parents=True, mode=0o700)
    cases = []

    def verify(source, name, expected_digest, rejection=False):
        result = run([probe, "payload", source, work / name, expected_digest], check=False)
        if rejection:
            if result.returncode != 1:
                raise RuntimeError(f"Expected rejected payload: {result.stdout} {result.stderr}")
        elif result.returncode or "PASS:" not in result.stdout:
            raise RuntimeError(f"Trusted payload failed: {result.stdout} {result.stderr}")
        cases.append(name)
        print("PASS:", name, flush=True)

    verify(app, "trusted-payload", digest)
    verify(app, "wrong-service-digest", "0" * 64, rejection=True)
    altered = work / "Altered.app"
    shutil.copytree(app, altered, symlinks=True)
    entitlements = work / "relaxed.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.disable-library-validation": True}))
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier", "dev.freev6.desktop",
         "--entitlements", entitlements, altered])
    verify(altered, "relaxed-client-rejected", digest, rejection=True)
    verify(app, "trusted-payload-after-rejections", digest)
    result = run([helper, "install", app, str(os.getuid()), "a" * 40], check=False)
    if result.returncode != 1:
        raise RuntimeError("Installer accepted non-root mutation")
    cases.append("non-root-mutation-rejected")
    report = {"cases": cases, "manifest": manifest, "scope": "real signed payload verification; no privileged installation"}
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Evidence:", work / "result.json")


if __name__ == "__main__":
    main()
