#!/usr/bin/env python3
"""Real Sparkle N -> N+1 update of an isolated fixture, never the user's app.

Uses a random bundle ID, a loopback-only feed, ephemeral Ed25519 keys and local
build artifacts. No release key, production appcast or root service is touched.
"""
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
import shutil
import subprocess
import tarfile
import threading
import time
import uuid
from xml.sax.saxutils import quoteattr

ROOT = Path(__file__).resolve().parents[2]
SDK = json.loads((ROOT / "apps/macos/Dependencies/sparkle.json").read_text())
VERSION = SDK["version"]
ARCHIVE_SHA256 = SDK["sha256"]
ARCHIVE_URL = SDK["url"]


def run(args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(str(args[0])).name}: {result.stderr[-4000:]}")
    return result.stdout.strip()


class FeedHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=["adhoc", "hardened", "hardened-relaxed"], default="hardened")
    parser.add_argument("--load-only", action="store_true")
    parser.add_argument("--invalid-signature", action="store_true")
    parser.add_argument("--isolated-agent", action="store_true", help="Keep the host hardened; load Sparkle only in a separate helper")
    args = parser.parse_args()
    if args.isolated_agent and (args.profile != "hardened" or args.load_only):
        parser.error("--isolated-agent requires --profile hardened and a full update test")
    if os.geteuid() == 0:
        raise RuntimeError("Run as the current user, never as root")
    token = uuid.uuid4().hex
    work = ROOT / "build/update-probes" / token
    work.mkdir(parents=True, mode=0o700)
    os.chmod(work, 0o700)
    print(f"Probe artifacts: {work}", flush=True)

    archive = ROOT / f"build/sparkle-probe/Sparkle-{VERSION}.tar.xz"
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        temporary = work / "sparkle-download.tar.xz"
        run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
             "--retry-all-errors", "--max-time", "120", "--output", temporary, ARCHIVE_URL], timeout=500)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != ARCHIVE_SHA256:
            raise RuntimeError("Downloaded Sparkle archive digest mismatch")
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise RuntimeError("Cached Sparkle archive digest mismatch")
    distribution = work / "distribution"
    with tarfile.open(archive, "r:xz") as bundle:
        bundle.extractall(distribution, filter="data")

    env = os.environ.copy()
    env["DEVELOPER_DIR"] = env.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    env["CLANG_MODULE_CACHE_PATH"] = str(ROOT / "build/macos-module-cache")
    target = f"{platform.machine()}-apple-macos14.0"
    executable = work / "UpdateProbe"
    run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Werror", "-target", target,
         "-F", distribution, "-framework", "AppKit", "-framework", "Sparkle",
         "-Wl,-rpath,@executable_path/../Frameworks", ROOT / "apps/macos/Probes/SparkleUpdateProbe.m",
         "-o", executable], env=env, timeout=120)
    host_executable = work / "UpdateHostProbe"
    if args.isolated_agent:
        run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Werror", "-target", target,
             "-framework", "AppKit", ROOT / "apps/macos/Probes/UpdateHostProbe.m", "-o", host_executable], env=env, timeout=120)
    keygen = work / "update-key"
    run(["/usr/bin/xcrun", "swiftc", "-target", target, ROOT / "apps/macos/Probes/UpdateKey.swift", "-o", keygen], env=env, timeout=120)
    private_key = work / "ephemeral-key"
    public_key = run([keygen, private_key], timeout=10)
    feed = work / "feed"
    feed.mkdir()
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(FeedHandler, directory=str(feed)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    feed_url = f"http://127.0.0.1:{server.server_port}"
    events = work / "events.jsonl"
    identifier = "dev.freev6.update-probe." + token
    entitlements = work / "probe.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.disable-library-validation": True}))
    child = None

    def sign(path, app=False, relax=False):
        command = ["/usr/bin/codesign", "--force", "--sign", "-"]
        if args.profile != "adhoc":
            command += ["--options", "runtime"]
        if app and (args.profile == "hardened-relaxed" or relax):
            command += ["--entitlements", entitlements]
        run(command + [path], timeout=30)

    def signing_profile(app):
        metadata = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], text=True, capture_output=True, check=True)
        entitlements_xml = run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app])
        entitlements_value = plistlib.loads(entitlements_xml.encode()) if entitlements_xml else {}
        return {"hardenedRuntime": "runtime)" in metadata.stderr or ",runtime," in metadata.stderr,
                "entitlements": entitlements_value}

    def make_app(parent, version):
        app = parent / "FreeV6UpdateProbe.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        shutil.copy2(host_executable if args.isolated_agent else executable, contents / "MacOS/UpdateProbe")
        info = {
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "UpdateProbe", "CFBundlePackageType": "APPL",
            "CFBundleName": "Flux6 Update Probe", "CFBundleVersion": version, "CFBundleShortVersionString": version,
            "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
            "SUFeedURL": feed_url + "/appcast.xml", "SUPublicEDKey": public_key,
            "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            "ProbeResultPath": str(events), "ProbeLoadOnly": args.load_only,
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        framework_contents = contents
        agent = None
        if args.isolated_agent:
            agent = contents / "Helpers/Flux6UpdateAgent.app"
            framework_contents = agent / "Contents"
            (framework_contents / "MacOS").mkdir(parents=True)
            shutil.copy2(executable, framework_contents / "MacOS/UpdateProbe")
            agent_info = dict(info, CFBundleIdentifier=identifier + ".update-agent", ProbeExternalHost=True)
            (framework_contents / "Info.plist").write_bytes(plistlib.dumps(agent_info))
        (framework_contents / "Frameworks").mkdir()
        framework = framework_contents / "Frameworks/Sparkle.framework"
        shutil.copytree(distribution / "Sparkle.framework", framework, symlinks=True)
        for component in ["XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "Autoupdate", "Updater.app"]:
            sign(framework / "Versions/B" / component)
        sign(framework)
        if agent is not None:
            sign(agent, app=True, relax=True)
        sign(app, app=True)
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
        return app

    try:
        app = make_app(work / "installed", "1")
        if not args.load_only:
            update = make_app(work / "next", "2")
            package = feed / "update.zip"
            run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", update, package], timeout=60)
            signature = run([distribution / "bin/sign_update", "--ed-key-file", private_key, "-p", package], timeout=30)
            if args.invalid_signature:
                signature = base64.b64encode(bytes(64)).decode()
            enclosure = (f'<enclosure url={quoteattr(feed_url + "/update.zip")} sparkle:version="2" '
                         f'sparkle:shortVersionString="2" sparkle:edSignature={quoteattr(signature)} '
                         f'length="{package.stat().st_size}" type="application/octet-stream"/>')
            (feed / "appcast.xml").write_text(
                '<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                '<channel><title>Isolated Flux6 update test</title><item><title>Version 2</title>'
                '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>' + enclosure + '</item></channel></rss>')
        print(f"Running {args.profile}: {'load' if args.load_only else 'signature rejection' if args.invalid_signature else 'N -> N+1'}", flush=True)
        with (work / "process.log").open("w") as log:
            child = subprocess.Popen([str(app / "Contents/MacOS/UpdateProbe")], stdout=log, stderr=log)
            deadline = time.monotonic() + 90
            history = []
            passed = False
            while time.monotonic() < deadline:
                if events.exists():
                    text = events.read_text()
                    lines = text.splitlines()
                    if not text.endswith("\n"):
                        lines = lines[:-1]
                    history = [json.loads(line) for line in lines if line.strip()]
                if args.load_only:
                    passed = any(event["event"] == "launched" for event in history) and child.poll() == 0
                elif args.invalid_signature:
                    passed = any(event["event"] == "error" and any(
                        cause["domain"] == "SUSparkleErrorDomain" and cause["code"] in (3001, 3002)
                        for cause in event.get("causes", [])) for event in history)
                else:
                    passed = any(event["event"] == "launched" and event["version"] == "2" for event in history)
                if passed or any(event["event"] == "error" for event in history):
                    break
                if child.poll() is not None and (args.load_only or child.returncode != 0):
                    break
                time.sleep(0.2)
        installed_version = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
        expected_version = "1" if args.load_only or args.invalid_signature else "2"
        passed = passed and installed_version == expected_version
        if passed and not args.load_only and not args.invalid_signature:
            old_pids = {event["pid"] for event in history if event["event"] == "launched" and event["version"] == "1"}
            new_pids = {event["pid"] for event in history if event["event"] == "launched" and event["version"] == "2"}
            passed = bool(old_pids and new_pids and old_pids.isdisjoint(new_pids))
        signing = {"host": signing_profile(app)}
        if args.isolated_agent:
            signing["agent"] = signing_profile(app / "Contents/Helpers/Flux6UpdateAgent.app")
            host_dependencies = run(["/usr/bin/otool", "-L", app / "Contents/MacOS/UpdateProbe"])
            passed = passed and signing["host"]["hardenedRuntime"] and not signing["host"]["entitlements"]
            passed = passed and "Sparkle.framework" not in host_dependencies
            passed = passed and signing["agent"]["entitlements"].get("com.apple.security.cs.disable-library-validation") is True
        report = {
            "passed": passed, "profile": args.profile, "loadOnly": args.load_only, "isolatedAgent": args.isolated_agent,
            "invalidSignature": args.invalid_signature, "installedVersion": installed_version,
            "sparkleVersion": VERSION, "sparkleArchiveSHA256": ARCHIVE_SHA256,
            "events": history, "signing": signing,
            "scope": "local fixture; no quarantine, minimum-OS or production-service update validation",
        }
        (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        if not passed:
            raise RuntimeError(f"Update probe did not pass; inspect {work / 'result.json'} and process.log")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
        print(f"PASS: installed version {installed_version}; evidence {work / 'result.json'}", flush=True)
    finally:
        if child is not None and child.poll() is None:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.terminate()
                child.wait(timeout=5)
        private_key.unlink(missing_ok=True)
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        # Only this randomly generated probe domain is removed.
        for probe_identifier in (identifier, identifier + ".update-agent"):
            subprocess.run(["/usr/bin/defaults", "delete", probe_identifier], capture_output=True, timeout=10)
            cache = Path.home() / "Library/Caches" / probe_identifier
            if cache.is_dir() and not cache.is_symlink():
                shutil.rmtree(cache)


if __name__ == "__main__":
    main()
