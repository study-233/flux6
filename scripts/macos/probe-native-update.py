#!/usr/bin/env python3
"""Run the shipping Swift update helper against signed local release fixtures."""
import argparse
import base64
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import plistlib
import runpy
import shutil
import subprocess
import threading
import time
import uuid
from xml.sax.saxutils import quoteattr

ROOT = Path(__file__).resolve().parents[2]
ARCH = platform.machine()


def run(args, **kwargs):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=180, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr[-3000:])
    return result.stdout.strip()


class FeedHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=["upgrade", "bad-archive", "unsigned-feed", "wrong-arch", "cancel", "cancel-download", "lost-host"], default="upgrade")
    exercise(parser.parse_args().scenario)


def exercise(scenario, *, before_check=None, confirm_installation=None):
    assert os.geteuid() != 0
    work = ROOT / "build/native-update-probes" / str(uuid.uuid4())
    work.mkdir(parents=True, mode=0o700)
    print(work, flush=True)
    sdk = Path(run(["python3", ROOT / "scripts/macos/prepare-sparkle.py", "--directory", work / "sdk"]))
    env = dict(os.environ, FREEV6_SPARKLE_FRAMEWORK_DIR=str(sdk), FREEV6_UPDATE_PROBE_BUILD="1")
    run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--product", "freev6-update-agent"], env=env)
    binary_dir = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path"], env=env))
    agent_binary = work / "agent"
    shutil.copy2(binary_dir / "freev6-update-agent", agent_binary)
    env.update(DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer", CLANG_MODULE_CACHE_PATH=str(ROOT / "build/macos-module-cache"))
    host_binary = work / "FreeV6"
    support = ROOT / "macos/Sources/FreeV6UpdateSupport"
    run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-target", ARCH + "-apple-macos13.0",
         support / "UpdateRelease.swift", support / "UpdatePipe.swift",
         ROOT / "macos/Probes/NativeUpdateHost.swift", "-o", host_binary], env=env)
    keygen = work / "keygen"
    run(["/usr/bin/xcrun", "swiftc", ROOT / "macos/Probes/UpdateKey.swift", "-o", keygen], env=env)
    key = work / "ephemeral-key"
    public = run([keygen, key])
    feed = work / "feed"
    feed.mkdir()
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(FeedHandler, directory=str(feed)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = "http://127.0.0.1:" + str(server.server_port)
    events = work / "events.jsonl"
    identifier = "dev.freev6.update-probe." + uuid.uuid4().hex
    embed = runpy.run_path(str(ROOT / "scripts/macos/bundle-updater.py"))["bundle"]

    def make_app(parent, version):
        app = parent / "FreeV6.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        shutil.copy2(host_binary, app / "Contents/MacOS/FreeV6")
        info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": "FreeV6", "CFBundlePackageType": "APPL",
                "CFBundleName": "FreeV6 Update Fixture", "CFBundleVersion": str(version), "CFBundleShortVersionString": str(version),
                "LSMinimumSystemVersion": "13.0", "LSUIElement": True,
                "SUFeedURL": base + "/appcast-" + ARCH + ".xml", "SUPublicEDKey": public,
                "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True, "SUSignedFeedFailureExpirationInterval": 0,
                "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False,
                "SUShowReleaseNotes": False, "SUEnableSystemProfiling": False,
                "SURelaunchHostBundle": True,
                "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
                "ProbeResultPath": str(events), "ProbeDecision": "await-service" if confirm_installation else {
                    "cancel": "cancel", "cancel-download": "cancel-download", "lost-host": "crash"}.get(scenario, "install")}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        embed(app, agent_binary, sdk, probe=True)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", app])
        return app

    child = None
    try:
        app = make_app(work / "installed", 1)
        next_app = make_app(work / "next", 2)
        package = feed / "update.zip"
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", next_app, package])
        signature = run([sdk / "bin/sign_update", "--ed-key-file", key, "-p", package])
        if scenario == "bad-archive":
            signature = base64.b64encode(bytes(64)).decode()
        requirements = {"format": 1, "build": 2, "minimumSourceBuild": 1, "maximumSourceBuild": 1,
                        "architecture": ({"arm64": "x86_64", "x86_64": "arm64"}[ARCH] if scenario == "wrong-arch" else ARCH),
                        "workerProtocol": 1, "serviceProtocol": 6, "settingsSchema": 1,
                        "runtimeCatalogSHA256": "a" * 64, "serviceSHA256": "b" * 64}
        encoded = base64.b64encode(json.dumps(requirements).encode()).decode()
        xml = ('<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
               'xmlns:freev6="urn:freev6:update:1"><channel><title>FreeV6 isolated update</title><item><title>Version 2</title>'
               '<sparkle:version>2</sparkle:version><sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>'
               f'<enclosure url={quoteattr(base + "/update.zip")} sparkle:edSignature={quoteattr(signature)} '
               f'length="{package.stat().st_size}" type="application/octet-stream" freev6:requirements={quoteattr(encoded)}/>'
               '</item></channel></rss>')
        appcast = feed / ("appcast-" + ARCH + ".xml")
        appcast.write_text(xml)
        if scenario != "unsigned-feed":
            run([sdk / "bin/sign_update", "--ed-key-file", key, appcast])
        if before_check:
            before_check()
        with (work / "process.log").open("w") as log:
            child = subprocess.Popen([app / "Contents/MacOS/FreeV6"], stdout=log, stderr=log,
                                     stdin=subprocess.PIPE if confirm_installation else subprocess.DEVNULL)
            deadline = time.monotonic() + 90
            history = []
            service_approved = None
            while time.monotonic() < deadline:
                if events.exists():
                    lines = events.read_text().splitlines()
                    history = [json.loads(line) for line in lines if line.endswith("}")]
                if confirm_installation and service_approved is None and any(e["event"] == "ready" for e in history):
                    service_approved = confirm_installation()
                    child.stdin.write(bytes([int(service_approved)]))
                    child.stdin.close()
                success = any(e["event"] == "launched" and e["version"] == "2" for e in history)
                failure = any(e["event"] == "failed" for e in history)
                if success or failure:
                    break
                if child.poll() is not None and child.returncode != 0:
                    break
                time.sleep(0.2)
        if scenario in ("cancel", "lost-host", "service-recovery-failure"):
            time.sleep(3)
        installed = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
        expected = "2" if scenario in ("upgrade", "service-upgrade") else "1"
        lost_host = scenario == "lost-host" and child.poll() == 19 and any(e["event"] == "ready" for e in history)
        passed = installed == expected and (success if expected == "2" else failure or lost_host)
        if expected == "2":
            passed = passed and any(e["event"] == "network-confirmed" for e in history)
        elif scenario not in ("cancel", "lost-host", "service-recovery-failure"):
            passed = passed and not any(e["event"] == "ready" for e in history)
        if confirm_installation:
            passed = passed and service_approved is (expected == "2")
            observed = [e["event"] for e in history]
            if service_approved:
                passed = passed and "installing" in observed and observed.index("network-confirmed") < observed.index("installing")
            else:
                passed = passed and "installation-cancelled" in observed and "installing" not in observed
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
        result = {"passed": passed, "scenario": scenario, "installedVersion": installed, "events": history,
                  "scope": ("signed fixture with the product update helper, native desktop disconnect, user-domain XPC and isolated DNS"
                            if confirm_installation else "ordinary-user signed fixture using product Swift helper; synthetic network preparation")}
        (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        if not passed:
            raise RuntimeError("Probe failed; inspect " + str(work))
        print("PASS " + scenario + " " + str(work / "result.json"))
        return work / "result.json"
    finally:
        if child and child.poll() is None:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        key.unlink(missing_ok=True)
        shutil.rmtree(sdk)
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        for name in (identifier, identifier + ".update-agent"):
            subprocess.run(["/usr/bin/defaults", "delete", name], capture_output=True, timeout=10)
            cache = Path.home() / "Library/Caches" / name
            if cache.is_dir() and not cache.is_symlink():
                shutil.rmtree(cache)


if __name__ == "__main__":
    main()
