#!/usr/bin/env python3
"""Crash a user-domain check coordinator at durable side-effect boundaries.

Uses pinned resources and public synthetic credentials, only core -t. No root
installation, live VPN, DNS or route mutation. Recovery uses production code.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import uuid

from session_probe import boot, run, state, until

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Never run as root")
    run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--product", "freev6-probe"], timeout=180)
    binaries = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path"]).stdout.strip())
    evidence = ROOT / "build/check-recovery-probes" / str(uuid.uuid4())
    evidence.mkdir(parents=True, mode=0o700)
    probe = evidence / "probe"
    shutil.copy2(binaries / "freev6-probe", probe)
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier", "dev.freev6.probe.check-recovery", probe])
    resources = sorted(p for p in args.resources.iterdir() if p.name != "resources.lock")
    runtime = next(p.name for p in resources if p.name.startswith("mihomo-"))
    geodata = "geodata-" + json.loads((ROOT / "internal/mihomo/geodata-assets.json").read_text())["revision"]
    request = evidence / "request.json"
    request.write_text(json.dumps({"protocolVersion": 6, "requestID": str(uuid.uuid4()), "runtimeID": runtime,
        "geodataID": geodata, "settingsRevision": 1, "credentialRevision": str(uuid.uuid4()),
        "configuration": json.loads((ROOT / "shared/fixtures/warp-business-configuration.json").read_text())}))
    domain = f"gui/{os.getuid()}"
    cases = []
    for checkpoint in ["registering", "job-registered", "registered", "starting", "job-started", "started", "exited", "job-removed", "removed", "missing-job", "unknown-file", "rejected", "timeout"]:
        case = evidence / checkpoint
        case.mkdir(mode=0o700)
        data = ROOT / "build" / ("n-" + uuid.uuid4().hex[:8])
        data.mkdir(mode=0o755)
        cache = data / "resources"
        cache.mkdir(mode=0o700)
        for source in resources:
            shutil.copy2(source, cache / source.name)
        jobs = []
        core_label = None

        def launch(arguments, name):
            return boot(probe, arguments, domain=domain, folder=case, name=name, jobs=jobs)

        def recover(name, expected_success=True):
            label = launch(["recover-check", str(data)], name)
            def ended():
                current = state(label)
                out, err = case / (name + ".stdout"), case / (name + ".stderr")
                if current and current["pid"] is None and (out.exists() and out.stat().st_size or err.exists() and err.stat().st_size):
                    return current
            outcome = until(ended)
            if expected_success:
                assert outcome["exit"] == 0 and "PASS:" in (case / (name + ".stdout")).read_text()
            else:
                assert outcome["exit"] != 0

        try:
            if checkpoint in ["rejected", "timeout"]:
                host = launch(["failed-check", str(data), str(request), checkpoint], "failure")
                def failure_ended():
                    current = state(host)
                    out, err = case / "failure.stdout", case / "failure.stderr"
                    if current and current["pid"] is None and (out.exists() and out.stat().st_size or err.exists() and err.stat().st_size):
                        return current
                result = until(failure_ended, timeout=45)
                assert result["exit"] == 0 and "PASS:" in (case / "failure.stdout").read_text()
                cases.append({"failure": checkpoint, "failureReported": True, "jobRemoved": True, "privateFilesRemoved": True})
                print("PASS:", checkpoint, flush=True)
                continue
            boundary = "job-started" if checkpoint == "missing-job" else "exited" if checkpoint == "unknown-file" else checkpoint
            host = launch(["hold-check", str(data), str(request), boundary], "host")
            def ready():
                output = case / "host.stdout"
                if output.exists():
                    text = output.read_text()
                    if text.endswith("\n"):
                        return json.loads(text)
            record = until(ready)
            core_label = "dev.freev6.core." + record["sessionID"].lower()
            session = data / "sessions" / record["sessionID"]
            journal = data / "network-session.json"
            before = journal.read_bytes()
            assert record["schema"] == 2 and record["phase"] == "checking"
            assert "private-key" not in before.decode()
            assert run([probe, "recover-check", data], check=False).returncode != 0
            assert journal.read_bytes() == before
            run(["/bin/launchctl", "kill", "SIGKILL", domain + "/" + host])
            until(lambda: (s := state(host)) and s["pid"] is None and s["exit"] == -9)
            assert journal.read_bytes() == before
            (case / "interrupted-journal.json").write_bytes(before)
            if checkpoint == "missing-job":
                run(["/bin/launchctl", "kill", "SIGKILL", domain + "/" + core_label], check=False)
                until(lambda: (s := state(core_label)) and s["pid"] is None)
                run(["/bin/launchctl", "bootout", domain + "/" + core_label])
                recover("recovery", expected_success=False)
                assert journal.read_bytes() == before and (session / "config.json").exists()
                cases.append({"checkpoint": checkpoint, "unexpectedAbsenceRejected": True, "recordAndSecretsRetained": True})
            else:
                if checkpoint == "unknown-file":
                    foreign = session / "foreign"
                    foreign.write_text("unrecognized test file")
                    recover("rejected-recovery", expected_success=False)
                    assert json.loads(journal.read_text())["check"]["stage"] == "removed"
                    assert (session / "config.json").exists() and foreign.exists()
                    foreign.unlink()
                recover("recovery")
                assert not journal.exists() and list((data / "sessions").iterdir()) == []
                assert state(core_label) is None
                recover("repeat-recovery")
                cases.append({"checkpoint": checkpoint, "liveLeaseRejected": True, "hostSIGKILL": True,
                    "recoveredByFreshProcess": True, "jobRemoved": True, "privateFilesRemoved": True, "idempotent": True})
            print("PASS:", checkpoint, flush=True)
        finally:
            if core_label is None and (data / "network-session.json").exists():
                pending = json.loads((data / "network-session.json").read_text())
                core_label = "dev.freev6.core." + pending["sessionID"].lower()
            if core_label and (s := state(core_label)):
                if s["pid"] is not None:
                    run(["/bin/launchctl", "kill", "SIGKILL", domain + "/" + core_label])
                    until(lambda: (s := state(core_label)) and s["pid"] is None)
                run(["/bin/launchctl", "bootout", domain + "/" + core_label])
            for label in jobs:
                run(["/bin/launchctl", "bootout", domain + "/" + label], check=False)
            shutil.rmtree(data)
    (evidence / "result.json").write_text(json.dumps({"scope": "ordinary-user service jobs and pinned core -t; no root/TUN/DNS", "cases": cases}, indent=2) + "\n")
    print("Evidence:", evidence / "result.json")


if __name__ == "__main__":
    main()
