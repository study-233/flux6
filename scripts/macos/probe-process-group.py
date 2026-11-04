#!/usr/bin/env python3
"""Record whether inherited-group cleanup handles a TERM-ignoring child.

This is a diagnostic of a rejected core-lifecycle design, not an acceptance
test for ManagedCoreJob. The owned test fixture has a 30-second watchdog.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(args, *, check=True):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=120)
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result


def until(test, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = test()
        if value:
            return value
        time.sleep(0.03)
    raise RuntimeError("Process group probe timed out")


def absent(pid, group=False):
    try:
        os.kill(-pid if group else pid, 0)
        return False
    except ProcessLookupError:
        return True


def main():
    if os.geteuid() == 0:
        raise RuntimeError("Never run this probe as root")
    run(["bash", ROOT / "scripts/macos/build-process-fixture.sh"])
    run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--product", "freev6-probe"])
    binary = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path"]).stdout.strip()) / "freev6-probe"
    work = ROOT / "build/group-probes" / str(uuid.uuid4())
    work.mkdir(parents=True, mode=0o700)
    host = work / "host"
    shutil.copy2(binary, host)
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier", "dev.freev6.probe.group", host])
    fixture = ROOT / "build/macos-process/owned-child"
    label = "dev.freev6.probe.group." + uuid.uuid4().hex
    domain = "gui/" + str(os.getuid())
    target = domain + "/" + label
    job = work / "job.plist"
    job.write_bytes(plistlib.dumps({"Label": label, "ProgramArguments": [str(host), "hold-group", str(fixture), str(work)],
        "RunAtLoad": True, "KeepAlive": False, "AbandonProcessGroup": False,
        "StandardOutPath": str(work / "host.stdout"), "StandardErrorPath": str(work / "host.stderr")}))
    sentinel = subprocess.Popen([str(fixture), "wait"], start_new_session=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    installed = False
    state = None
    try:
        run(["/bin/launchctl", "bootstrap", domain, job])
        installed = True
        def ready():
            output = work / "host.stdout"
            if not output.exists() or not (work / "child-ready").exists():
                return None
            text = output.read_text().strip()
            return json.loads(text) if text else None
        state = until(ready)
        if state["hostPID"] != state["groupID"] or os.getpgid(state["childPID"]) != state["groupID"]:
            raise RuntimeError("Child did not inherit the job process group")
        if os.getpgid(sentinel.pid) == state["groupID"]:
            raise RuntimeError("Sentinel unexpectedly joined the job")
        run(["/bin/launchctl", "kill", "SIGKILL", target])
        until(lambda: absent(state["hostPID"]))
        time.sleep(0.3)
        survived = not absent(state["childPID"])
        if sentinel.poll() is not None:
            raise RuntimeError("Unrelated sentinel was affected")
        result = {"scope": "ordinary-user launchd job and test fixture; no core/TUN/DNS", **state,
                  "hostKilledViaLaunchd": True, "termIgnoringChildSurvived": survived,
                  "unrelatedSentinelSurvived": True,
                  "productionDecision": "Use a separate directly managed core job; never rely on group cleanup alone"}
    finally:
        try:
            if installed:
                run(["/bin/launchctl", "bootout", target])
            # This harness created this live, ordinary-user fixture moments ago.
            # It is intentionally outside the product's historical-PID recovery.
            if state and not absent(state["childPID"]):
                expected = f"{fixture} ignore-term {work / 'child-ready'}"
                command = run(["/bin/ps", "-p", state["childPID"], "-o", "command="]).stdout.strip()
                if command != expected or os.getpgid(state["childPID"]) != state["groupID"]:
                    raise RuntimeError("Test child identity differs; watchdog will end fixture")
                os.kill(state["childPID"], 9)
                until(lambda: absent(state["childPID"]))
        finally:
            sentinel.terminate()
            try:
                sentinel.wait(timeout=3)
            except subprocess.TimeoutExpired:
                sentinel.kill(); sentinel.wait(timeout=3)
    if run(["/bin/launchctl", "print", target], check=False).returncode == 0:
        raise RuntimeError("Temporary launchd job remained")
    result["jobRemoved"] = True
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Observed TERM-ignoring child survival:", result["termIgnoringChildSurvived"])
    print("PASS: fixture and temporary job removed; unrelated sentinel survived")
    print("Evidence:", work / "result.json")


if __name__ == "__main__":
    main()
