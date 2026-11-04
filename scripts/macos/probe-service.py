#!/usr/bin/env python3
"""Exercise the debug service in an isolated, temporary user launchd job.

No root installation, network changes or persistent login item. Each run binds
the copied probe's signed identity, verifies both peer directions, and boots the
job out in a finally block. A rejection counts only between successful calls.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(args, *, check=True, timeout=30):
    result = subprocess.run([str(arg) for arg in args], text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{Path(str(args[0])).name} failed ({result.returncode}): {result.stderr.strip()}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-build", action="store_true", help="Use the current debug build")
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError("This probe must run as the logged-in user, never as root")
    if not args.no_build:
        run(["bash", ROOT / "scripts/macos/swift.sh", "build"], timeout=180)
    binaries = Path(run(["bash", ROOT / "scripts/macos/swift.sh", "build", "--show-bin-path"]).stdout.strip())
    work = ROOT / "build/service-probes" / str(uuid.uuid4())
    work.mkdir(parents=True, mode=0o700)
    os.chmod(work, 0o700)
    probe = work / "freev6-probe"
    service = work / "freev6-network-service"
    untrusted = work / "untrusted-probe"
    upgraded = work / "upgraded-probe"
    for source, destination, identifier in [
        (binaries / "freev6-probe", probe, "dev.freev6.probe.client"),
        (binaries / "freev6-network-service", service, "dev.freev6.probe.service"),
        (binaries / "freev6-probe", untrusted, "dev.freev6.probe.untrusted"),
    ]:
        shutil.copy2(source, destination)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier", identifier, destination])
        run(["/usr/bin/codesign", "--verify", "--strict", destination])

    # Adding an empty entitlement section changes the CodeDirectory while
    # retaining the same identifier and runtime protection, without extra powers.
    shutil.copy2(probe, upgraded)
    empty_entitlements = work / "empty.entitlements"
    empty_entitlements.write_bytes(plistlib.dumps({}))
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier",
         "dev.freev6.probe.client", "--entitlements", empty_entitlements, upgraded])
    run(["/usr/bin/codesign", "--verify", "--strict", upgraded])

    registration = json.loads(run([probe, "registration", service]).stdout)
    service_hash = registration["service"]["cdHash"]
    record = work / "registration.json"

    def write_record(value):
        record.write_text(json.dumps(value))
        os.chmod(record, 0o600)

    write_record(registration)
    label = "dev.freev6.probe." + str(uuid.uuid4())
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{label}"
    job = work / "service.plist"
    job.write_bytes(plistlib.dumps({
        "Label": label,
        "ProgramArguments": [str(service), "--probe", label, str(record)],
        "MachServices": {label: True},
        "ThrottleInterval": 1,
        "StandardOutPath": str(work / "service.stdout"),
        "StandardErrorPath": str(work / "service.stderr"),
    }))
    cases = []

    def handshake(executable=probe, expected_hash=service_hash, rejected=False):
        result = run([executable, "mach", label, expected_hash], check=False, timeout=15)
        if rejected:
            if result.returncode != 1 or "NSCocoaErrorDomain" not in result.stderr or "timed out" in result.stderr:
                raise RuntimeError(f"Expected explicit XPC rejection, got {result.returncode}: {result.stdout} {result.stderr}")
        elif result.returncode or "privileged=false" not in result.stdout:
            raise RuntimeError(f"Trusted handshake failed: {result.stdout} {result.stderr}")

    def case(name):
        cases.append(name)
        print(f"PASS: {name}", flush=True)

    def process_id():
        output = run(["/bin/launchctl", "print", target]).stdout
        match = re.search(r"\bpid = (\d+)", output)
        if not match:
            raise RuntimeError("Service has no running process")
        return int(match.group(1))

    installed = False
    try:
        run(["/bin/launchctl", "bootstrap", domain, job])
        installed = True
        handshake()
        case("registered client and service mutually authenticate")
        handshake(untrusted, rejected=True)
        handshake()
        case("different client CDHash rejected; trusted client remains usable")
        handshake(expected_hash="0" * 40, rejected=True)
        handshake()
        case("client rejects unexpected service CDHash")
        previous_pid = process_id()
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake()
        if process_id() == previous_pid:
            raise RuntimeError("Service did not restart")
        case("launchd restart preserves registered identity")
        wrong_user = json.loads(json.dumps(registration))
        wrong_user["clients"][0]["uid"] = os.getuid() + 1
        write_record(wrong_user)
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake(rejected=True)
        write_record(registration)
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake()
        case("registered identity is bound to its UID")
        renewed = json.loads(run([upgraded, "registration", service]).stdout)
        old_identity = registration["clients"][0]["identity"]
        new_identity = renewed["clients"][0]["identity"]
        if old_identity["identifier"] != new_identity["identifier"] or old_identity["cdHash"] == new_identity["cdHash"]:
            raise RuntimeError("Expected same identifier with a different CodeDirectory hash")
        handshake(upgraded, rejected=True)
        write_record(renewed)
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake(upgraded)
        handshake(probe, rejected=True)
        handshake(upgraded)
        case("client hash rotation requires re-enrollment and revokes the old hash")
    finally:
        if installed:
            run(["/bin/launchctl", "bootout", target])
            if run(["/bin/launchctl", "print", target], check=False).returncode == 0:
                raise RuntimeError("Probe job remained registered after cleanup")
            case("temporary launchd job removed")

    report = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "user-domain debug Mach service; no root installation or network changes",
        "registration": registration,
        "cases": cases,
    }
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Evidence: {work / 'result.json'}")


if __name__ == "__main__":
    main()
