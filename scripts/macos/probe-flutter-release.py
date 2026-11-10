#!/usr/bin/env python3
"""Verify the actual Flutter release, local Sparkle upgrade and supported rollback.

The two worker versions share a private test directory. All GUI upgrades use a
new, unique identity. Nothing is installed into Applications, no default
keychain is opened, and nothing is uploaded.
"""
import argparse
import base64
import hashlib
import json
import os
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import platform
import plistlib
import re
import runpy
import struct
import subprocess
import threading
import uuid
from xml.etree import ElementTree as ET

from sign_flutter_host import cdhash
from worker_probe import call

ROOT = Path(__file__).resolve().parents[2]
ARCH = platform.machine()


def run(*args, timeout=240):
    child = subprocess.run(list(map(str, args)), capture_output=True, timeout=timeout, text=True,
                           env={**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                                "CLANG_MODULE_CACHE_PATH": str(ROOT / "build/macos-module-cache")})
    if child.returncode:
        raise RuntimeError(child.stderr[-5000:])
    return child.stdout.strip()


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def text_digest(file):
    """Hash the arm64 program instructions, independently of the re-signed Mach-O envelope."""
    blob = file.read_bytes()
    if struct.unpack_from(">I", blob)[0] == 0xCAFEBABE:
        count = struct.unpack_from(">I", blob, 4)[0]
        assert count == 1
        cpu, _, offset, size, _ = struct.unpack_from(">IIIII", blob, 8)
        assert cpu == 0x0100000C and offset + size <= len(blob)
        blob = blob[offset:offset + size]
    if struct.unpack_from("<I", blob)[0] != 0xfeedfacf:
        raise ValueError(f"Expected thin arm64 Mach-O: {file.name}")
    count = struct.unpack_from("<I", blob, 16)[0]
    pos = 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", blob, pos)
        if command == 0x19 and blob[pos + 8:pos + 24].rstrip(b"\0") == b"__TEXT":
            for n in range(struct.unpack_from("<I", blob, pos + 64)[0]):
                section = pos + 72 + n * 80
                if blob[section:section + 16].rstrip(b"\0") == b"__text":
                    length = struct.unpack_from("<Q", blob, section + 40)[0]
                    offset = struct.unpack_from("<I", blob, section + 48)[0]
                    assert length > 0 and offset + length <= len(blob)
                    return hashlib.sha256(blob[offset:offset + length]).hexdigest()
        pos += size
    raise ValueError(f"No executable text section in {file.name}")


def runtime_identity(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    contents = app / "Contents"
    return {
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "id": info["CFBundleIdentifier"], "minimumOS": info["LSMinimumSystemVersion"],
        "runnerInstructions": text_digest(contents / "MacOS/Flux6"),
        "dartAOTInstructions": text_digest(contents / "Frameworks/App.framework/Versions/A/App"),
        "engineInstructions": text_digest(contents / "Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"),
        "worker": digest(contents / "Helpers/freev6-worker"),
        "service": digest(contents / "Library/LaunchServices/dev.freev6.network-service"),
    }


def worker_roundtrip(app, data, action):
    args = [app / "Contents/Helpers/freev6-worker", "--data-dir", data / "settings", "--resource-dir",
            app / "Contents/Resources", "--log-dir", data / "logs", "--cache-dir", data / "cache"]
    with subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as child:
        def request(method, params=None):
            result = call(child, method, params)
            assert "result" in result, (method, result.get("error", {}).get("code"))
            return result["result"]
        try:
            hello = request("initialize", {"protocolVersion": 1})
            assert hello["protocolVersion"] == 1 and hello["platform"] == "darwin"
            return action(request)
        finally:
            child.stdin.close()
            if child.wait(timeout=5) != 0:
                raise RuntimeError("Packaged worker failed to exit on EOF")


@contextmanager
def subscription():
    content = (ROOT / "shared/fixtures/chain-proxies.yaml").read_bytes()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/subscription":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        def log_message(self, *_):
            pass
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/subscription"
        finally:
            server.shutdown()
            thread.join(timeout=5)


def compatible_data(baseline, candidate, installed, folder, source):
    folder.mkdir(mode=0o700)
    session_id = str(uuid.uuid4())
    key = base64.b64encode(os.urandom(32)).decode()

    def seed(request):
        original = request("settings.get")
        saved = request("settings.patch", {"expectedRevision": original["revision"],
              "changes": {"mode": "global", "campusCidrs": ["edu.cn"], "blacklist": ["example.test"]}})
        imported = request("chain.preview", {"expectedRevision": saved["revision"], "key": key, "url": source})
        saved = request("chain.commit", {"expectedRevision": saved["revision"], "token": imported["token"]})
        usage = request("traffic.observe", {"sessionID": session_id, "upload": 31_000, "download": 85_000})
        assert saved["chain"]["names"] and saved["settings"]["mode"] == "global" and usage["total"]["upload"] > 0
        return saved, usage["total"]

    old_settings, old_totals = worker_roundtrip(baseline, folder, seed)

    def edit_new(request):
        assert request("settings.get") == old_settings
        assert request("traffic.get")["total"] == old_totals
        refreshed = request("chain.preview", {"expectedRevision": old_settings["revision"], "key": key, "refresh": True})
        assert [node["name"] for node in refreshed["nodes"]] == old_settings["chain"]["names"]
        saved = request("settings.patch", {"expectedRevision": old_settings["revision"], "changes": {"mode": "direct"}})
        usage = request("traffic.observe", {"sessionID": session_id, "upload": 51_000, "download": 105_000})
        assert saved["chain"] == old_settings["chain"] and saved["revision"] > old_settings["revision"]
        assert usage["total"]["upload"] == old_totals["upload"] + 20_000
        return saved, usage["total"]

    next_settings, next_totals = worker_roundtrip(candidate, folder, edit_new)
    # Restore a *verified complete bundle* only in this probe's directory.
    # The application data, worker ledger, and secrets never enter that swap.
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", baseline)
    prior = installed.parent / "restored.app"
    run("/usr/bin/ditto", baseline, prior)
    replaced = installed.parent / "replaced-build2.app"
    installed.rename(replaced)
    try:
        prior.rename(installed)
    except OSError:
        replaced.rename(installed)
        raise
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", installed)
    assert plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "1"
    def read_rollback(request):
        assert request("settings.get") == next_settings and request("traffic.get")["total"] == next_totals
        # The saved encrypted chain can still be used with its isolated key on rollback.
        response = request("chain.preview", {"expectedRevision": next_settings["revision"], "key": key, "refresh": True})
        assert [node["name"] for node in response["nodes"]] == next_settings["chain"]["names"]
    worker_roundtrip(installed, folder, read_rollback)
    return {"workerProtocol": 1, "schema": next_settings["schemaVersion"], "baselineBuild": 1, "candidateBuild": 2,
            "rollbackBuild": 1, "oldReadsNew": True, "newReadsOld": True, "chainMembers": len(next_settings["chain"]["names"]),
            "oldMode": old_settings["settings"]["mode"], "finalMode": next_settings["settings"]["mode"],
            "oldRevision": old_settings["revision"], "finalRevision": next_settings["revision"],
            "ledgerUploadBefore": old_totals["upload"], "ledgerUploadAfterRollback": next_totals["upload"]}


def audit(candidate, baseline, destination):
    assert os.geteuid() != 0 and ARCH == "arm64"
    work = ROOT / "build/p6-release-validation" / str(uuid.uuid4())
    work.mkdir(parents=True, mode=0o700)
    print(work, flush=True)
    candidate = candidate.resolve(strict=True)
    baseline = baseline.resolve(strict=True)
    baseline_info = plistlib.loads((baseline / "Contents/Info.plist").read_bytes())
    assert baseline_info["CFBundleVersion"] == "1" and baseline_info["CFBundleIdentifier"] == "dev.freev6.desktop"
    identity = runtime_identity(candidate)
    assert (identity["version"], identity["build"], identity["id"]) == ("0.5.3", "2", "dev.freev6.desktop")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", baseline)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", candidate)

    key, pub, channel = [work / name for name in ("private-test-key", "test-public-key", "channel.json")]
    try:
        run("xcrun", "swiftc", ROOT / "apps/macos/Probes/UpdateKey.swift", "-o", work / "keygen")
        pub.write_text(run(work / "keygen", key))
        run("python3", ROOT / "scripts/macos/github_channel.py", "--public-key-file", pub, "--output", channel)
        release = work / "release"
        sign = ["python3", ROOT / "scripts/macos/package-update.py", "--app", candidate, "--output", release,
                "--channel", channel, "--private-key", key, "--build", "2", "--version", "0.5.3",
                "--minimum-source-build", "1", "--maximum-source-build", "1"]
        run(*sign)
        archive, feed = release / f"Flux6_0.5.3_2_{ARCH}.zip", release / f"appcast-{ARCH}.xml"
        expected_digests = dict(line.split("  ")[::-1] for line in (release / "SHA256SUMS").read_text().splitlines())
        assert expected_digests == {p.name: digest(p) for p in [archive, feed]}
        item = ET.parse(feed).find("./channel/item")
        enclosure = item.find("enclosure")
        requirements = json.loads(base64.b64decode(enclosure.get("{urn:freev6:update:1}requirements"), validate=True))
        assert requirements["minimumSourceBuild"] == requirements["maximumSourceBuild"] == 1
        assert requirements["build"] == 2 and requirements["serviceSHA256"] == identity["service"]
        assert requirements["runtimeCatalogSHA256"] == digest(candidate / "Contents/Resources/runtime-assets.json")
        assert (requirements["serviceProtocol"], requirements["workerProtocol"], requirements["settingsSchema"]) == (6, 1, 1)
        expanded = work / "unpacked"
        run("/usr/bin/ditto", "-x", "-k", archive, expanded)
        packaged = expanded / "Flux6.app"
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", packaged)
        assert runtime_identity(packaged) == identity
        assert json.loads((packaged / "Contents/Resources/update-compatibility.json").read_bytes()) == requirements
        signed_info = plistlib.loads((packaged / "Contents/Info.plist").read_bytes())
        assert signed_info["SUPublicEDKey"] == pub.read_text()
        assert signed_info["SUFeedURL"] == json.loads(channel.read_text())["feeds"][ARCH]
        assert enclosure.get("length") == str(archive.stat().st_size)
        assert enclosure.get("url", "").endswith("/v0.5.3/" + archive.name)
        # Sign_update has already verified the XML and ZIP; prove mismatched keys are refused.
        spec = json.loads(channel.read_text())
        spec["publicKey"] = base64.b64encode(bytes(32)).decode()
        channel.write_text(json.dumps(spec))
        sign[sign.index("--output") + 1] = work / "refused"
        assert subprocess.run(list(map(str, sign)), capture_output=True, timeout=240).returncode != 0
        assert not (work / "refused").exists()
    finally:
        key.unlink(missing_ok=True)

    target_result = runpy.run_path(str(ROOT / "scripts/macos/probe-native-update.py"))["exercise"]("upgrade", flutter_target=packaged)
    sparkle = json.loads(target_result.read_text())
    assert sparkle["passed"] and sparkle["flutter"]["freshProcess"]
    installed = target_result.parent / "installed/Flux6.app"
    assert runtime_identity(installed)["runnerInstructions"] == identity["runnerInstructions"]
    assert runtime_identity(installed)["dartAOTInstructions"] == identity["dartAOTInstructions"]
    with subscription() as source:
        migrated = compatible_data(baseline, installed, installed, work / "sandboxed-data", source)
    probe = run("python3", ROOT / "scripts/macos/probe-installer.py", "--no-build", "--app", packaged)
    receipt = Path(re.search(r"Evidence: (.+/result.json)", probe).group(1))
    assessment = subprocess.run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", candidate],
                                capture_output=True, timeout=45, text=True)
    policy = subprocess.run(["/usr/bin/syspolicy_check", "distribution", "--json", candidate],
                            capture_output=True, timeout=60, text=True)
    issues = sorted({entry["SyspolicyCheckShortError"] for entry in json.loads(policy.stdout)["output"]})
    report = {"passed": True, "candidate": {**identity, "cdHash": cdhash(candidate).hex()},
              "baseline": {"version": baseline_info["CFBundleShortVersionString"], "build": "1", "cdHash": cdhash(baseline).hex()},
              "distribution": {"gatekeeperStatus": run("/usr/sbin/spctl", "--status"), "assessmentExit": assessment.returncode,
                               "assessment": (assessment.stderr + assessment.stdout).replace(str(candidate), candidate.name).strip(),
                               "distributionExit": policy.returncode, "issues": issues, "downloadQuarantineTested": False},
              "update": {"archive": archive.name, "appcast": feed.name, "verifiedChecksums": expected_digests,
                         "testChannelBundleCDHash": cdhash(packaged).hex(),
                         "matchingSignedMetadata": requirements, "wrongKeyRefused": True,
                         "scope": "Disposable Ed25519 key, no published assets or feeds."},
              "sparkle": sparkle, "dataMigrationAndRollback": migrated, "installer": json.loads(receipt.read_text()),
              "raw": {"package": str(release.relative_to(ROOT)), "sparkle": str(target_result.relative_to(ROOT)),
                      "installer": str(receipt.relative_to(ROOT))}}
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report,indent=2,ensure_ascii=False)+"\n")
    print("PASS " + str(destination))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    audit(args.candidate, args.baseline, args.output)
