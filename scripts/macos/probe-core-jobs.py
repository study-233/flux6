#!/usr/bin/env python3
"""Exercise the production job manager in ordinary-user launchd jobs.

No root installation, TUN, or DNS changes. Only the -t configuration-check
entry point runs the pinned core; process fixtures test crashes and signals.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(args, check=True, timeout=40):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result


def until(test, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if value := test():
            return value
        time.sleep(0.03)
    raise RuntimeError("Job probe timed out")


def absent(pid):
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True


def main():
    if os.geteuid() == 0:
        raise RuntimeError("Never run this probe as root")
    run(["bash", ROOT / "scripts/macos/build-process-fixture.sh"])
    run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--product", "freev6-probe"], timeout=180)
    binaries = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path"]).stdout.strip())
    evidence = ROOT / "build/core-job-probes" / str(uuid.uuid4())
    evidence.mkdir(parents=True, mode=0o700)
    probe = evidence / "probe"
    shutil.copy2(binaries / "freev6-probe", probe)
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier", "dev.freev6.probe.core-job", probe])
    fixture = ROOT / "build/macos-process/owned-child"
    sentinel = subprocess.Popen([str(fixture), "wait"], start_new_session=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cases = []

    def exercise(mode, real_core=False):
        session = str(uuid.uuid4()).upper()
        work = evidence / session
        work.mkdir(mode=0o700)
        controller = None
        target = f"gui/{os.getuid()}/dev.freev6.core.{session.lower()}"

        def invoke(action, check=True):
            result = run([probe, "core-job", action, session, work], check=check)
            return json.loads(result.stdout) if check else result

        try:
            if real_core:
                catalog = json.loads((ROOT / "internal/mihomo/runtime-assets.json").read_text())
                geodata = json.loads((ROOT / "internal/mihomo/geodata-assets.json").read_text())
                arch = {"arm64": "arm64", "x86_64": "amd64"}[platform.machine()]
                core = next(a for a in catalog["assets"] if a["os"] == "darwin" and a["arch"] == arch)
                source = ROOT / "build/macos-probes" / core["binary"]
                assert hashlib.sha256(source.read_bytes()).hexdigest() == core["binarySha256"]
                shutil.copy2(source, work / "mihomo")
                for asset in geodata["assets"]:
                    source = ROOT / "build/macos-geodata" / asset["name"]
                    assert hashlib.sha256(source.read_bytes()).hexdigest() == asset["sha256"]
                    shutil.copy2(source, work / asset["name"])
                    os.chmod(work / asset["name"], 0o400)
                request = {"protocolVersion": 6, "requestID": str(uuid.uuid4()),
                    "runtimeID": f"mihomo-darwin-{arch}-{catalog['version']}", "geodataID": "geodata-" + geodata["revision"],
                    "settingsRevision": 1, "credentialRevision": str(uuid.uuid4()),
                    "configuration": json.loads((ROOT / "shared/fixtures/warp-business-configuration.json").read_text())}
                request_path = work / "public-request.json"
                request_path.write_text(json.dumps(request))
                run([probe, "assemble-configuration", request_path, work / "config.json"])
            else:
                shutil.copy2(fixture, work / "mihomo")
                (work / "config.json").write_text(mode)
            os.chmod(work / "mihomo", 0o500)
            os.chmod(work / "config.json", 0o600)
            initial = invoke("register")
            assert initial["loaded"] and initial.get("pid") is None
            assert not (work / "child-ready").exists()
            # Separate controller is killed after launch; a fresh process
            # reconciles and stops the label, without inheriting a child handle.
            controller = subprocess.Popen([str(probe), "core-job", "start-hold", session, str(work)],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if not select.select([controller.stdout], [], [], 10)[0]:
                raise RuntimeError("Controller did not report started job")
            started = json.loads(controller.stdout.readline())
            pid = started["startedPID"]
            if mode in ("wait", "ignore-term"):
                until(lambda: (work / "child-ready").exists())
                state = run(["/bin/ps", "-p", pid, "-o", "ppid=,pgid="]).stdout.split()
                assert state == ["1", str(pid)]
                # Removing a running job would discard the only durable
                # authority for recovery; our API must refuse it.
                assert invoke("remove", check=False).returncode != 0
            controller.kill(); controller.wait(timeout=5)
            controller.stdout.close(); controller.stderr.close(); controller = None
            if mode in ("wait", "ignore-term"):
                assert invoke("status")["pid"] == pid
                stopped = invoke("stop")
                expected = -9 if mode == "ignore-term" else -15
            else:
                stopped = invoke("wait")
                expected = 0 if real_core else 37
            assert stopped["exit"] == expected and stopped.get("pid") is None
            until(lambda: absent(pid))
            assert sentinel.poll() is None
            # Repeat reconciliation before removal: an already stopped job
            # retains its result, so a crash cannot invent success.
            assert invoke("stop")["exit"] == expected
            assert invoke("remove")["loaded"] is False
            assert invoke("status")["loaded"] is False
            cases.append({"case": mode, "sessionID": session, "pid": pid, "exit": expected,
                "registeredWithoutStarting": True, "controllerKilled": True,
                "freshControllerReconciled": True, "coreReaped": True, "jobRemoved": True,
                "unrelatedSentinelSurvived": True})
            print(f"PASS: {mode}", flush=True)
        finally:
            if controller is not None:
                controller.kill(); controller.wait(timeout=5)
                controller.stdout.close(); controller.stderr.close()
            # Test-only cleanup by exact job identity; no historical PID kill.
            run(["/bin/launchctl", "kill", "SIGKILL", target], check=False)
            run(["/bin/launchctl", "bootout", target], check=False)

    try:
        for mode in ["wait", "ignore-term", "exit37"]:
            exercise(mode)
        exercise("pinned-core-configuration-check", real_core=True)
    finally:
        sentinel.terminate()
        sentinel.wait(timeout=5)
    result = {"scope": "ordinary-user managed jobs; pinned core -t only; no TUN/DNS/root installation",
              "productionSessionJournalIntegrated": False, "cases": cases}
    (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Evidence:", evidence / "result.json")


if __name__ == "__main__":
    main()
