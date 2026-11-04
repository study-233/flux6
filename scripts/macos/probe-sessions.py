#!/usr/bin/env python3
"""Kill a user-owned preparation host, then recover its real durable journal.

Only public synthetic WARP credentials are used. No core, root job or network
settings are started or changed. Uses already installed, pinned resource files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import signal
import stat
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(args, *, check=True):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=120)
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True, help="Verified service resource directory")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Never run this probe as root")
    run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--product", "freev6-probe"])
    binary_dir = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path"]).stdout.strip())
    probe = binary_dir / "freev6-probe"
    arch = {"arm64": "arm64", "x86_64": "amd64"}[platform.machine()]
    runtime_catalog = json.loads((ROOT / "internal/mihomo/runtime-assets.json").read_text())
    runtime = next(a for a in runtime_catalog["assets"]
                   if a["os"] == "darwin" and a["arch"] == arch)
    geodata = json.loads((ROOT / "internal/mihomo/geodata-assets.json").read_text())
    runtime_id = "mihomo-darwin-" + arch + "-" + runtime_catalog["version"]
    geodata_id = "geodata-" + geodata["revision"]
    assets = [(runtime_id, runtime["binarySha256"], 0o500)] + [
        (geodata_id + "-" + a["name"], a["sha256"], 0o400) for a in geodata["assets"]]
    evidence = ROOT / "build/session-probes" / str(uuid.uuid4())
    evidence.mkdir(parents=True, mode=0o700)
    request = evidence / "request.json"
    request.write_text(json.dumps({"protocolVersion": 3, "requestID": str(uuid.uuid4()), "runtimeID": runtime_id,
        "geodataID": geodata_id, "settingsRevision": 29, "credentialRevision": str(uuid.uuid4()),
        "configuration": json.loads((ROOT / "shared/fixtures/warp-business-configuration.json").read_text())}))
    request.chmod(0o600)
    cases = []
    for partial in [True, False]:
        root = ROOT / "build" / ("n-" + uuid.uuid4().hex[:8])
        root.mkdir(mode=0o755)
        child = None
        try:
            if not partial:
                resources = root / "resources"
                resources.mkdir(mode=0o700)
                for name, digest, mode in assets:
                    source = args.resources / name
                    content = source.read_bytes()
                    if hashlib.sha256(content).hexdigest() != digest:
                        raise RuntimeError("Source resource is not pinned")
                    destination = resources / name
                    destination.write_bytes(content)
                    destination.chmod(mode)
            child = subprocess.Popen([str(probe), "hold-partial-session" if partial else "hold-session", str(root), str(request)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                if not selector.select(timeout=30):
                    raise RuntimeError("Preparation host did not become ready")
            line = child.stdout.readline()
            if not line:
                child.wait(timeout=5)
                raise RuntimeError("Preparation host failed: " + child.stderr.read())
            summary = json.loads(line)
            phase = "preparing" if partial else "prepared"
            if summary["phase"] != phase:
                raise RuntimeError("Wrong preparation phase")
            journal = root / "network-session.json"
            before = journal.read_bytes()
            directory = root / "sessions" / summary["sessionID"]
            if stat.S_IMODE(directory.stat().st_mode) != 0o700 or stat.S_IMODE(journal.stat().st_mode) != 0o600:
                raise RuntimeError("Private preparation permissions mismatch")
            if run([probe, "recover-session", root], check=False).returncode == 0:
                raise RuntimeError("Another process obtained a live session lease")
            child.kill()
            if child.wait(timeout=5) != -signal.SIGKILL:
                raise RuntimeError("Expected a real abrupt process exit")
            if journal.read_bytes() != before:
                raise RuntimeError("Crash unexpectedly removed recovery data")
            run([probe, "recover-session", root])
            run([probe, "recover-session", root])
            if journal.exists() or list((root / "sessions").iterdir()):
                raise RuntimeError("Recovery did not remove prepared secrets and journal")
            cases.append({"phase": phase, "concurrentLeaseRejected": True, "SIGKILL": True,
                          "journalRetained": True, "recoveredByNewProcess": True, "idempotent": True})
            print("PASS:", phase, "crash, lease release and fresh-process recovery", flush=True)
        finally:
            if child is not None:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
                for stream in (child.stdin, child.stdout, child.stderr):
                    stream.close()
            shutil.rmtree(root)
    (evidence / "result.json").write_text(json.dumps({"scope": "ordinary-user preparation only; no core/root/DNS", "cases": cases}, indent=2) + "\n")
    print("Evidence:", evidence / "result.json")


if __name__ == "__main__":
    main()
