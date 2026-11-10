#!/usr/bin/env python3
"""Launch the signed product on a read-only image and/or in a disposable writable home.

The exact product identity and bytes are used. macOS sandbox rules prevent
access to the actual Flux6 user stores, settings, credentials, network and
service. The harness never accepts the agreement or requests a connection.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ID = "dev.freev6.desktop"
REAL_LIBRARY = Path.home() / "Library"
STORES = ("Application Support/" + ID, "Logs/" + ID, "Caches/" + ID, "Preferences/" + ID + ".plist")


def metadata():
    # Observe file metadata only. Do not read settings, logs, or credentials.
    rows = []
    for name in STORES:
        top = REAL_LIBRARY / name
        if top.exists():
            for path in [top, *top.rglob("*")]:
                stat = path.lstat()
                rows.append((str(path.relative_to(REAL_LIBRARY)), stat.st_size, stat.st_mtime_ns))
    return sorted(rows)


def run(args, *, check=True, timeout=20):
    return subprocess.run(args, capture_output=True, text=True, check=check, timeout=timeout)


def exercise(app, mounted, folder, observer):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert (info["CFBundleIdentifier"], info["CFBundleVersion"]) == (ID, "2")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    profile = folder / "isolation.sb"
    home = folder / "private-home"
    for entry in ("Library/Logs", "Library/Preferences", "Library/Caches", "Library/Application Support"):
        (home / entry).mkdir(parents=True, mode=0o700, exist_ok=True)
    profile.write_text('(version 1)\n(allow default)\n'
        '(deny user-preference-write)\n'
        '(deny user-preference-read (preference-domain "dev.freev6.desktop"))\n'
        '(deny mach-lookup (global-name "dev.freev6.network-service") '
        '(global-name "com.apple.securityd") (global-name "com.apple.Secrets"))\n'
        '(deny network-outbound (remote ip "*:*"))\n'
        '(deny file-write* (subpath ' + json.dumps(str(REAL_LIBRARY)) + '))\n'
        '(deny file-read* ' + " ".join("(subpath " + json.dumps(str(REAL_LIBRARY / p)) + ")" for p in STORES)
        + ' (subpath ' + json.dumps(str(REAL_LIBRARY / "Keychains")) + '))\n')
    initial = metadata()
    sent = ["-acceptedNotices", "P6-FIRST-RUN", "-autoRunProxy", "NO", "-silentStart", "NO",
            "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"]
    args = ["/usr/bin/sandbox-exec", "-f", str(profile), app / "Contents/MacOS/Flux6", *sent]
    with (folder / "startup.log").open("w") as stream:
        child = subprocess.Popen(args, env={**os.environ, "CFFIXED_USER_HOME": str(home)},
                                 stdout=stream, stderr=stream, stdin=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise RuntimeError(f"Product exited early; see {folder}/startup.log")
                observation = run([observer, "inspect", str(child.pid)], check=False)
                if observation.returncode == 0:
                    window = json.loads(observation.stdout)
                    if (window["finished"] and Path(window["bundle"]).resolve() == app.resolve()
                            and (window["width"] < 520 if mounted else window["width"] >= 700)):
                        break
                time.sleep(.15)
            else:
                raise RuntimeError(f"Could not observe the {'installation' if mounted else 'Flutter'} window")
            time.sleep(1)
            mapped = run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(child.pid), "-d", "txt"]).stdout
            dart_running = "App.framework/" in mapped
            assert dart_running is not mounted, "Wrong executable mapped for the volume type"
            screenshot = folder / "window.png"
            words = []
            if window["captureAvailable"]:
                run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window["window"]), str(screenshot)])
                recognized = run([observer, "recognize", screenshot]).stdout
                text = "".join(recognized.split())
                possible = ["安装", "Flux6", "应用程序", "退出"] if mounted else ["欢迎使用", "用户协议", "隐私政策", "同意", "退出"]
                words = [word for word in possible if word in text]
                if len(words) < 2:
                    raise RuntimeError(f"Cannot identify expected UI in {screenshot}: {words}")
            children = run(["/usr/bin/pgrep", "-P", str(child.pid)], check=False)
            for pid in children.stdout.split():
                path = run(["/bin/ps", "-p", pid, "-o", "comm="], check=False).stdout
                if "freev6-worker" in path or "network-service" in path:
                    raise RuntimeError("Running a Flux6 helper before consent")
            writes = [entry for entry in STORES if (home / "Library" / entry).exists()]
            if mounted and writes:
                raise RuntimeError("Installation guide created product data in the test home")
            if not mounted and "Logs/" + ID not in writes:
                raise RuntimeError("Writable launch did not initialize the coordinator's isolated event journal")
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
    assert initial == metadata(), "Production store metadata changed while the test was running"
    return {"identity": ID, "build": "2", "readOnlyVolume": mounted, "window": {key: window[key] for key in
            ["title", "width", "height", "finished", "captureAvailable"]}, "dartAOTMapped": dart_running,
            "recognizedLabels": words, "createdTestStores": writes, "productionStoreMetadataUnchanged": True,
            "acceptedAgreement": False, "screenshot": str(screenshot.relative_to(ROOT)) if screenshot.is_file() else None}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert os.geteuid() != 0 and (args.candidate or args.image)
    folder = ROOT / "build/p6-release-validation" / str(uuid.uuid4())
    folder.mkdir(mode=0o700, parents=True)
    print(folder, flush=True)
    observer = folder / "window-observer"
    run(["/usr/bin/xcrun", "swiftc", ROOT / "apps/macos/Probes/ReleaseWindow.swift", "-o", observer], timeout=120)
    result = {}
    if args.candidate:
        result["writable"] = exercise(args.candidate.resolve(strict=True), False, folder / "writable", observer)
    if args.image:
        volume = runpy.run_path(str(ROOT / "scripts/macos/build-dmg.py"))["readonly_volume"]
        with args.image.open("rb") as image:
            digest = hashlib.sha256(image.read()).hexdigest()
        with volume(args.image.resolve(strict=True)) as mount:
            result["mounted"] = exercise(mount / "Flux6.app", True, folder / "mounted", observer)
            result["imageSHA256"] = digest
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print("PASS", args.output)
