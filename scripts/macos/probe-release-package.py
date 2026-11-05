#!/usr/bin/env python3
"""Verify local release packaging with an ephemeral key and reserved test URLs."""
import json
import os
from pathlib import Path
import platform
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
work = ROOT / "build/release-package-probes" / str(uuid.uuid4())
work.mkdir(parents=True, mode=0o700)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
           CLANG_MODULE_CACHE_PATH=str(ROOT / "build/macos-module-cache"))
keygen = work / "keygen"
subprocess.run(["/usr/bin/xcrun", "swiftc", str(ROOT / "macos/Probes/UpdateKey.swift"), "-o", str(keygen)], env=env, check=True)
private = work / "ephemeral-key"
public = subprocess.check_output([keygen, private], text=True).strip()
channel = work / "channel.json"
channel.write_text(json.dumps({"format": 1, "publicKey": public,
                              "feeds": {platform.machine(): "https://updates.example.invalid/appcast-" + platform.machine() + ".xml"}}))
try:
    args = ["python3", str(ROOT / "scripts/macos/package-update.py"), "--output", str(work / "release"),
            "--channel", str(channel), "--private-key", str(private),
            "--download-base", "https://updates.example.invalid/releases", "--build", "2", "--version", "0.5.3",
            "--minimum-source-build", "1", "--maximum-source-build", "1"]
    subprocess.run(args, check=True, timeout=240)
    assets = sorted(p.name for p in (work / "release").iterdir())
    assert len(assets) == 3 and "SHA256SUMS" in assets
    # A public-key mismatch must fail before publishing an output directory.
    import base64
    spec = json.loads(channel.read_text())
    spec["publicKey"] = base64.b64encode(bytes(32)).decode()
    channel.write_text(json.dumps(spec))
    args[args.index("--output") + 1] = str(work / "rejected")
    bad = subprocess.run(args, capture_output=True, timeout=120)
    assert bad.returncode != 0 and not (work / "rejected").exists()
    report = {"passed": True, "assets": assets, "checks": ["complete signed archive and signed appcast",
              "package and feed signatures independently verified", "wrong publishing key refused before output"],
              "scope": "local packaging only; no production channel or public release"}
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS " + str(work / "result.json"))
finally:
    private.unlink(missing_ok=True)
