"""Seal an AOT Mac runner. Ad-hoc builds pin the two embedded libraries in a kernel load constraint."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

FRAMEWORKS = ("App", "FlutterMacOS")
LOCAL_RIGHTS = {"com.apple.security.cs.disable-library-validation": True}


def host_libraries(app):
    directory = app / "Contents/Frameworks"
    if {file.name for file in directory.iterdir()} != {name + ".framework" for name in FRAMEWORKS}:
        raise ValueError("Unexpected embedded framework in the Flutter release")
    return [directory / (name + ".framework") for name in FRAMEWORKS]


def cdhash(path):
    info = subprocess.run(["/usr/bin/codesign", "-dvvv", path], check=True, capture_output=True, text=True).stderr
    return bytes.fromhex(re.search(r"^CDHash=([0-9a-f]{40})$", info, re.M)[1])


def sign_host(app, identity="-"):
    flags = ["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime"]
    if keychain := os.environ.get("FREEV6_CODESIGN_KEYCHAIN"):
        flags += ["--keychain", keychain]
    with tempfile.TemporaryDirectory() as temporary:
        if identity == "-" or os.environ.get("FREEV6_LOCAL_SIGNING") == "1":
            # System libraries are exempt by macOS. No third-party Team, path or wildcard is trusted.
            root = Path(temporary)
            rights = root / "rights.plist"
            rights.write_bytes(plistlib.dumps(LOCAL_RIGHTS))
            constraint = root / "libraries.plist"
            constraint.write_bytes(plistlib.dumps({"cdhash": {"$in": [cdhash(lib) for lib in host_libraries(app)]}}))
            flags += ["--entitlements", rights, "--library-constraint", constraint]
        subprocess.run([*flags, app], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", app], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    sign_host(parser.parse_args().app, os.environ.get("FREEV6_CODESIGN_IDENTITY", "-"))
