#!/usr/bin/env python3
"""Assess a browser-downloaded preview DMG without launching or approving its app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import runpy
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
readonly_volume = runpy.run_path(str(ROOT / "scripts/macos/build-dmg.py"))["readonly_volume"]


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True, timeout=180,
                          env={**os.environ, "LC_ALL": "C"})


def quarantine(path):
    return run("/usr/bin/xattr", "-p", "com.apple.quarantine", path).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="copy downloaded by a browser")
    parser.add_argument("--reference", type=Path, required=True, help="expected local build of the same DMG")
    args = parser.parse_args()
    if os.geteuid() == 0 or platform.system() != "Darwin":
        raise SystemExit("Use an ordinary user on macOS")
    image = args.image.resolve(strict=True)
    if image.samefile(args.reference):
        raise SystemExit("Select the separate downloaded copy")
    expected = hashlib.sha256(args.reference.read_bytes()).hexdigest()
    if hashlib.sha256(image.read_bytes()).hexdigest() != expected:
        raise SystemExit("Downloaded image differs from the expected build")
    work = ROOT / "build/distribution-probes" / str(uuid.uuid4())
    work.mkdir(parents=True, mode=0o700)
    report = {"sha256": expected, "system": platform.mac_ver()[0], "arch": platform.machine(),
              "imageQuarantine": quarantine(image)}
    if not report["imageQuarantine"]:
        raise RuntimeError("Image is missing download quarantine")
    report["assessmentStatus"] = run("/usr/sbin/spctl", "--status").stdout.strip()
    if report["assessmentStatus"] != "assessments enabled":
        raise RuntimeError("Gatekeeper must already be enabled to test default distribution policy")
    run("/usr/bin/hdiutil", "verify", "-quiet", image)
    with tempfile.TemporaryDirectory(prefix="freev6-downloaded-") as tmp:
        copied = Path(tmp) / "Applications/Flux6.app"
        with readonly_volume(image) as mount:
            source = mount / "Flux6.app"
            run("/usr/bin/ditto", "--qtn", source, copied)
        report["copyQuarantine"] = quarantine(copied)
        if not report["copyQuarantine"]:
            raise RuntimeError("The copied application lost its download quarantine")
        image_fields = report["imageQuarantine"].split(";")
        if len(image_fields) > 3 and image_fields[3] and report["copyQuarantine"].split(";")[3:4] != image_fields[3:4]:
            raise RuntimeError("The copied application lost the download's quarantine event identifier")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", copied)
        report["signatureVerified"] = True
        # Use Apple's distribution check on 14+, retaining diagnostics verbatim.
        # macOS 13 only has spctl; record the actual evaluation on both paths.
        policy = Path("/usr/bin/syspolicy_check")
        if policy.exists():
            result = run(policy, "distribution", "--json", copied, check=False)
            (work / "distribution.json").write_text(result.stdout)
            issues = {item["SyspolicyCheckShortError"] for item in json.loads(result.stdout)["output"]}
            if not result.returncode or "Notary Ticket Missing" not in issues or issues - {"Adhoc Signed App", "Notary Ticket Missing"}:
                raise RuntimeError(f"Unexpected preview distribution result: {issues}")
            report["distributionIssues"] = sorted(issues)
        result = run("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", copied, check=False)
        report["gatekeeper"] = (result.stderr + result.stdout).strip()
        report["assessmentExit"] = result.returncode
        (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        if not result.returncode or "rejected" not in report["gatekeeper"].lower():
            raise RuntimeError(f"Expected a Gatekeeper rejection of this preview; see {work}/result.json")
    print("Verified downloaded preview and observed Gatekeeper rejection:", work / "result.json")


if __name__ == "__main__":
    main()
