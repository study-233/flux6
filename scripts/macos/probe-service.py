#!/usr/bin/env python3
"""Exercise the debug service in an isolated, temporary user launchd job.

No root installation, network changes or persistent login item. Each run binds
the copied probe's signed identity, verifies both peer directions, and boots the
job out in a finally block. A rejection counts only between successful calls.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
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
    parser.add_argument("--runtime-fixtures", type=Path, help="Exercise resource FD transfer with pinned official files")
    parser.add_argument("--geodata-fixtures", type=Path)
    args = parser.parse_args()
    if bool(args.runtime_fixtures) != bool(args.geodata_fixtures):
        parser.error("Supply both runtime and geodata fixtures")
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

    def resources():
        return json.loads(run([probe, "resources", label, service_hash], timeout=40).stdout)

    def resource_cases():
        runtime = json.loads((ROOT / "internal/mihomo/runtime-assets.json").read_text())
        geo = json.loads((ROOT / "internal/mihomo/geodata-assets.json").read_text())
        arch = {"arm64": "arm64", "x86_64": "amd64"}[platform.machine()]
        core = next(a for a in runtime["assets"] if a["os"] == "darwin" and a["arch"] == arch)
        core_id = f"mihomo-darwin-{arch}-{runtime['version']}"
        assets = [(core_id, args.runtime_fixtures / core["archive"], core_id, core["binarySha256"])]
        for a in geo["assets"]:
            group = "geodata-" + geo["revision"]
            assets.append((group + "/" + a["name"], args.geodata_fixtures / a["name"], group + "-" + a["name"], a["sha256"]))
        if any(a["available"] for a in resources()):
            raise RuntimeError("Fresh service unexpectedly has resources")
        for resource_id, source, destination, digest in assets:
            incoming = work / "incoming"
            shutil.copyfile(source, incoming)
            incoming.chmod(0o600)
            output = run([probe, "install-resource", label, service_hash, resource_id, incoming], timeout=40)
            if not next(a["available"] for a in json.loads(output.stdout) if a["id"] == resource_id):
                raise RuntimeError("Installed resource not available")
            stored = work / "resources" / destination
            if hashlib.sha256(stored.read_bytes()).hexdigest() != digest:
                raise RuntimeError("Private resource digest mismatch")
            if stored.stat().st_mode & 0o777 != (0o500 if resource_id == core_id else 0o400):
                raise RuntimeError("Private resource permissions mismatch")
            incoming.write_bytes(b"corrupt replacement")
            rejected = run([probe, "install-resource", label, service_hash, resource_id, incoming], check=False, timeout=40)
            if rejected.returncode != 1 or "固定摘要" not in rejected.stderr:
                raise RuntimeError("Corrupt resource was not explicitly rejected")
            if hashlib.sha256(stored.read_bytes()).hexdigest() != digest:
                raise RuntimeError("Rejected replacement changed existing resource")
        if not all(a["available"] for a in resources()):
            raise RuntimeError("Complete resource set unavailable")
        source = work / "incoming"
        unknown = run([probe, "install-resource", label, service_hash, "../../unapproved", source], check=False)
        if unknown.returncode != 1 or "可信清单" not in unknown.stderr:
            raise RuntimeError("Unknown resource/path was not rejected")
        denied = run([untrusted, "install-resource", label, service_hash, core_id, source], check=False)
        if denied.returncode != 1 or "NSCocoaErrorDomain" not in denied.stderr:
            raise RuntimeError("Unregistered resource client was not rejected")
        if any(p.name.startswith(".staging-") for p in (work / "resources").iterdir()):
            raise RuntimeError("Resource staging files remained")
        source.unlink()
        case("real XPC file descriptors install pinned core/geodata; corrupt, unknown and unregistered requests rejected")

    installed = False
    try:
        run(["/bin/launchctl", "bootstrap", domain, job])
        installed = True
        handshake()
        case("registered client and service mutually authenticate")
        if args.runtime_fixtures:
            resource_cases()
        handshake(untrusted, rejected=True)
        handshake()
        case("different client CDHash rejected; trusted client remains usable")
        handshake(expected_hash="0" * 40, rejected=True)
        handshake()
        case("client rejects unexpected service CDHash")
        previous_pid = process_id()
        stale = None
        if args.runtime_fixtures:
            stale = work / "resources" / (".staging-" + str(uuid.uuid4()))
            stale.write_bytes(b"interrupted transfer fixture")
            stale.chmod(0o600)
        run(["/bin/launchctl", "kickstart", "-k", target])
        handshake()
        if process_id() == previous_pid:
            raise RuntimeError("Service did not restart")
        case("launchd restart preserves registered identity")
        if args.runtime_fixtures:
            if not all(a["available"] for a in resources()):
                raise RuntimeError("Resources failed verification after service restart")
            if stale.exists():
                raise RuntimeError("Interrupted private staging was not cleaned")
            case("private resources independently verified and interrupted staging cleaned after launchd restart")
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
