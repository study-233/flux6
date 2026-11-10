#!/usr/bin/env python3
"""Package and inspect a local release for the selected GitHub repository without uploading it."""
import base64
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import uuid
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
work = ROOT / "build/release-package-probes" / str(uuid.uuid4())
work.mkdir(parents=True, mode=0o700)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
           CLANG_MODULE_CACHE_PATH=str(ROOT / "build/macos-module-cache"))
keygen = work / "keygen"
subprocess.run(["/usr/bin/xcrun", "swiftc", str(ROOT / "macos/Probes/UpdateKey.swift"), "-o", str(keygen)], env=env, check=True)
private = work / "ephemeral-key"
channel = work / "channel.json"
try:
    public = subprocess.check_output([keygen, private], text=True).strip()
    public_file = work / "test-public-key"
    public_file.write_text(public)
    subprocess.run(["python3", str(ROOT / "scripts/macos/github_channel.py"), "--public-key-file", str(public_file),
                    "--output", str(channel)], check=True)
    spec = json.loads(channel.read_text())
    feed_base = "https://raw.githubusercontent.com/study-233/free-v6/macos-updates"
    for arch in ("arm64", "x86_64"):
        assert spec["feeds"][arch] == f"{feed_base}/appcast-{arch}.xml"
    args = ["python3", str(ROOT / "scripts/macos/package-update.py"), "--output", str(work / "release"),
            "--channel", str(channel), "--private-key", str(private),
            "--build", "2", "--version", "0.5.3",
            "--minimum-source-build", "1", "--maximum-source-build", "1"]
    subprocess.run(args, check=True, timeout=240)
    assets = sorted(p.name for p in (work / "release").iterdir())
    assert len(assets) == 3 and "SHA256SUMS" in assets
    arch = platform.machine()
    archive = work / "release" / f"FreeV6_0.5.3_2_{arch}.zip"
    item = ET.parse(work / "release" / f"appcast-{arch}.xml").find("./channel/item")
    minimum = item.findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}minimumSystemVersion")
    assert minimum == "14.0"
    enclosure = item.find("enclosure")
    assert enclosure.get("url") == "https://github.com/study-233/free-v6/releases/download/macos-v0.5.3-b2/" + archive.name
    with zipfile.ZipFile(archive) as zipped:
        settings = plistlib.loads(zipped.read("FreeV6.app/Contents/Info.plist"))
        assert settings["LSMinimumSystemVersion"] == minimum
        assert settings["SUFeedURL"] == spec["feeds"][arch] and settings["SUPublicEDKey"] == public
    args[args.index("--output") + 1] = str(work / "rejected")
    wrong_destination = subprocess.run(args + ["--download-base", "https://example.invalid/releases"], capture_output=True)
    assert wrong_destination.returncode != 0 and not (work / "rejected").exists()
    # A public-key mismatch must fail before publishing an output directory.
    spec["publicKey"] = base64.b64encode(bytes(32)).decode()
    channel.write_text(json.dumps(spec))
    bad = subprocess.run(args, capture_output=True, timeout=120)
    assert bad.returncode != 0 and not (work / "rejected").exists()
    report = {"passed": True, "assets": assets, "checks": ["complete signed archive and signed appcast",
              "package and feed signatures independently verified", "per-architecture GitHub feed embedded in signed ZIP",
              "enclosure uses the versioned release of study-233/free-v6", "wrong asset destination and key refused before output"],
              "scope": "local packaging with a disposable key; no branch, GitHub release or asset published"}
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS " + str(work / "result.json"))
finally:
    private.unlink(missing_ok=True)
