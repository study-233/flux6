#!/usr/bin/env python3
"""Run the fixed core under user launchd with isolated DNS and a simulated utun."""
import argparse
import json
import os
from pathlib import Path
import shutil
import uuid

from session_probe import boot, isolated_network, run, state, until

ROOT = Path(__file__).resolve().parents[2]
CHECKPOINTS = [
    "normal", "reject-egress", "run-capturingDNS", "run-registering", "run-job-registered", "run-starting",
    "run-job-started", "run-applyingDNS", "run-dns-applied", "run-active", "run-restoringDNS", "run-dns-restored",
    "run-stopping", "run-job-stopped", "run-exited", "run-job-removed", "run-removed",
    "rollback-busy", "core-crash", "missing-job", "known-rule", "unknown-rule", "foreign-socket",
]


def exercise(probe, request, resources, folder, scenario):
    data = ROOT / "build" / ("n-" + uuid.uuid4().hex[:8])
    data.mkdir(mode=0o755)
    cache = data / "resources"
    cache.mkdir(mode=0o700)
    for asset in resources:
        shutil.copy2(asset, cache / asset.name)
    dns = isolated_network(data)
    jobs = []
    domain = f"gui/{os.getuid()}"
    core = None
    journal = data / "network-session.json"
    folder.mkdir(mode=0o700)

    def launch(args, name):
        return boot(probe, args, domain=domain, folder=folder, name=name, jobs=jobs)

    def completion(label, name, success=True):
        def terminal():
            job = state(label)
            logs = [folder / (name + ext) for ext in [".stdout", ".stderr"]]
            return job if job and job["pid"] is None and any(f.exists() and f.stat().st_size for f in logs) else None
        result = until(terminal)
        if (result["exit"] == 0) != success or (success and "PASS:" not in (folder / (name + ".stdout")).read_text()):
            raise RuntimeError(f"{scenario}/{name} unexpected exit {result}: " + (folder / (name + ".stderr")).read_text())

    def recover(name, success=True):
        completion(launch(["probe-network-recover", data], name), name, success)

    def signal(label):
        run(["/bin/launchctl", "kill", "SIGKILL", domain + "/" + label])
        until(lambda: (s := state(label)) and s["pid"] is None and s["exit"] == -9)

    try:
        if scenario == "reject-egress":
            (data / "reject-egress").touch()
        boundary = scenario if scenario.startswith("run-") else "run-active"
        if scenario in ("normal", "reject-egress"):
            completion(launch(["probe-network-run", data, request, "-"], "host"), "host", scenario == "normal")
            if scenario == "reject-egress":
                assert "HTTPS" in (folder / "host.stderr").read_text()
        else:
            host = launch(["probe-network-run", data, request, boundary], "host")
            def ready():
                out, err = folder / "host.stdout", folder / "host.stderr"
                if err.exists() and err.stat().st_size and (s := state(host)) and s["pid"] is None:
                    raise RuntimeError(err.read_text())
                if out.exists() and (text := out.read_text()).endswith("\n"):
                    return json.loads(text)
            record = until(ready)
            assert record["schema"] == 3 and record["phase"] == "network"
            core = "dev.freev6.core." + record["sessionID"].lower()
            session = data / "sessions" / record["sessionID"]
            if boundary in ("run-active", "run-dns-applied"):
                assert state(core)["pid"] and dns() == {"ServerAddresses": ["127.0.0.1"], "ServerPort": 1053}
            if boundary in ("run-dns-restored", "run-stopping"):
                assert state(core)["pid"] and dns() is None
            before = journal.read_bytes()
            assert run([probe, "probe-network-recover", data], check=False).returncode != 0
            assert journal.read_bytes() == before
            signal(host)
            (folder / "interrupted.json").write_bytes(before)
            if scenario == "rollback-busy":
                blocker = data / "block-dns-recovery"
                blocker.touch()
                recover("blocked", False)
                assert state(core)["pid"] and dns()["ServerPort"] == 1053
                assert json.loads(journal.read_bytes())["run"]["stage"] == "restoringDNS"
                blocker.unlink()
            if scenario in ("core-crash", "missing-job"):
                signal(core)
            if scenario == "missing-job":
                run(["/bin/launchctl", "bootout", domain + "/" + core])
                recover("ambiguous", False)
                assert json.loads(journal.read_bytes())["run"]["stage"] == "restoringDNS"
                assert dns() is None and (session / "config.json").exists()
                return
            if scenario == "known-rule":
                rules = session / "ruleset"
                rules.mkdir(mode=0o700, exist_ok=True)
                (rules / "rule01.list").write_text("DOMAIN,example.test")
            if scenario in ("unknown-rule", "foreign-socket"):
                if scenario == "unknown-rule":
                    rules = session / "ruleset"
                    rules.mkdir(mode=0o700)
                    foreign = rules / "unauthorized.list"
                    foreign.touch()
                else:
                    signal(core)
                    foreign = session / "c.sock"
                    foreign.unlink(missing_ok=True)
                    foreign.symlink_to(data / "probe-options.json")
                recover("unexpected-file", False)
                assert json.loads(journal.read_text())["run"]["stage"] == "removed"
                assert (session / "config.json").exists() and dns() is None and state(core) is None
                foreign.unlink()
            recover("restarted")
        assert not journal.exists() and not list((data / "sessions").iterdir()) and dns() is None
        if core:
            assert state(core) is None
        recover("again")
    finally:
        for label in jobs:
            run(["/bin/launchctl", "bootout", domain + "/" + label], check=False)
        if core is None and journal.exists():
            core = "dev.freev6.core." + json.loads(journal.read_bytes())["sessionID"].lower()
        if core and (s := state(core)):
            if s["pid"]:
                signal(core)
            run(["/bin/launchctl", "bootout", domain + "/" + core])
        shutil.rmtree(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--case", choices=CHECKPOINTS)
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Run as an ordinary user")
    run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--product", "freev6-probe"], timeout=180)
    products = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path"]).stdout.strip())
    folder = ROOT / "build/network-run-probes" / str(uuid.uuid4())
    folder.mkdir(mode=0o700, parents=True)
    probe = folder / "probe"
    shutil.copy2(products / "freev6-probe", probe)
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier", "dev.freev6.probe.run", probe])
    resources = [p for p in args.resources.iterdir() if p.name != "resources.lock"]
    request = folder / "request.json"
    request.write_text(json.dumps({"protocolVersion": 5, "requestID": str(uuid.uuid4()),
        "runtimeID": next(p.name for p in resources if p.name.startswith("mihomo-")),
        "geodataID": "geodata-" + json.loads((ROOT / "internal/mihomo/geodata-assets.json").read_text())["revision"],
        "settingsRevision": 1, "credentialRevision": str(uuid.uuid4()),
        "configuration": json.loads((ROOT / "shared/fixtures/warp-business-configuration.json").read_text())}))
    cases = [args.case] if args.case else CHECKPOINTS
    for name in cases:
        exercise(probe, request, resources, folder / name, name)
        print("PASS:", name, flush=True)
    (folder / "result.json").write_text(json.dumps({"cases": cases, "scope": "user launchd, pinned core, isolated DNS, synthetic utun and egress"}, indent=2))
    print("Evidence:", folder / "result.json")


if __name__ == "__main__":
    main()
