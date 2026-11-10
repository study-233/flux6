#!/usr/bin/env python3
"""Exercise FreeV6's login item in a disposable home and one temporary Aqua job."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(*arguments, check=True):
    return subprocess.run(arguments, text=True, capture_output=True, check=check, timeout=180)


def main():
    if os.geteuid() == 0:
        raise RuntimeError("The login probe requires an ordinary GUI user")
    domain = f"gui/{os.getuid()}"
    run("/bin/launchctl", "print", domain)
    run("bash", ROOT / "scripts/macos/swift.sh", "build", "--product", "freev6-probe")
    run("bash", ROOT / "scripts/macos/swift.sh", "build", "--product", "freev6-login-launcher")
    binaries = Path(run("bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path").stdout.strip())
    probe = binaries / "freev6-probe"
    work = ROOT / "build/login-probes" / str(uuid.uuid4())
    home = work / "home"
    (home / "Library").mkdir(parents=True)
    app = home / "Applications/FreeV6.app"
    label = "dev.freev6.probe.login." + uuid.uuid4().hex
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    events = work / "events.jsonl"
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": label + ".observer", "CFBundleExecutable": "FreeV6", "CFBundlePackageType": "APPL",
        "CFBundleName": "FreeV6 Login Fixture", "LSUIElement": True, "ProbeEvents": str(events),
    }))
    run("/usr/bin/xcrun", "swiftc", "-parse-as-library", ROOT / "apps/macos/Probes/LoginObserver.swift", "-o", macos / "FreeV6")
    helpers = app / "Contents/Helpers"
    helpers.mkdir()
    launcher = helpers / "freev6-login-launcher"
    shutil.copy2(binaries / launcher.name, launcher)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", launcher)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", app)
    run(probe, "probe-login-item", home, "install")
    installed = home / "Library/LaunchAgents/dev.freev6.desktop.login.plist"
    job = plistlib.loads(installed.read_bytes())
    assert job["ProgramArguments"] == [str(launcher)]
    assert job["RunAtLoad"] and "KeepAlive" not in job and job["LimitLoadToSessionType"] == "Aqua"
    # Isolate the job and its attribution. The executable/arguments generated
    # by the product are exercised untouched.
    job["Label"] = label
    job["AssociatedBundleIdentifiers"] = [label + ".observer"]
    plist = work / "probe.plist"
    plist.write_bytes(plistlib.dumps(job))
    target = domain + "/" + label

    def history():
        if not events.exists():
            return []
        return [json.loads(line) for line in events.read_text().splitlines() if line.endswith("}")]

    def observe(event):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if any(row["event"] == event for row in history()):
                return
            time.sleep(0.05)
        raise RuntimeError("Missing fixture event: " + event)

    def wait_for_run(count):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            fields = run("/bin/launchctl", "print", target).stdout
            if re.search(rf"^\s*runs = {count}$", fields, re.M) and re.search(r"^\s*last exit code = 0$", fields, re.M) and "state = not running" in fields:
                return
            time.sleep(0.1)
        raise RuntimeError("Login launcher did not finish successfully")

    run("/bin/launchctl", "bootstrap", domain, plist)
    try:
        observe("launched")
        wait_for_run(1)
        run("/bin/launchctl", "kickstart", target)
        wait_for_run(2)
        rows = history()
        assert len({row["pid"] for row in rows}) == 1
        assert sum(row["event"] == "launched" for row in rows) == 1
        assert not any(row["event"] == "reopened" for row in rows)
        assert "--freev6-login" in rows[0]["arguments"]
    finally:
        run("/bin/launchctl", "bootout", target)
        run(probe, "probe-login-item", home, "remove")
    assert not installed.exists() and run("/bin/launchctl", "print", target, check=False).returncode != 0
    # Wait for the observer's own bounded lifetime. No signal is sent to an
    # arbitrary PID and no running instance of the actual product is involved.
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and run("/usr/bin/pgrep", "-f", str(macos / "FreeV6"), check=False).returncode == 0:
        time.sleep(0.25)
    if run("/usr/bin/pgrep", "-f", str(macos / "FreeV6"), check=False).returncode == 0:
        raise RuntimeError("Fixture remained running")
    rows = history()
    assert [row["event"] for row in rows] == ["launched", "terminated"]
    assert len({row["pid"] for row in rows}) == 1
    report = {"scope": "temporary ordinary-user Aqua job, disposable app and Library; no real user login registration",
              "events": rows, "launcherRuns": 2, "jobRemoved": True, "agentRemoved": True, "observerExited": True}
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS", work / "result.json")


if __name__ == "__main__":
    main()
