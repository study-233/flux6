#!/usr/bin/env python3
"""Download a pinned Darwin runtime and optionally validate an offline config.

This probe only runs `mihomo -v` / `mihomo -t`. It never starts a TUN session.
The production downloader will consume the same catalog during P1/P3.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
LIMIT = 150 << 20


def copy_limited(source, destination):
    total = 0
    while chunk := source.read(1 << 20):
        total += len(chunk)
        if total > LIMIT:
            raise ValueError("Runtime exceeds the 150 MiB size limit")
        destination.write(chunk)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    native_arch = {"arm64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    parser.add_argument("--arch", choices=["arm64", "amd64"], default=native_arch)
    parser.add_argument("--check-config", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin" or not args.arch:
        parser.error("This probe requires macOS on a supported architecture")
    if args.check_config and args.arch != native_arch:
        parser.error("Configuration checks require a native-architecture runtime")
    catalog = json.loads((ROOT / "internal/mihomo/runtime-assets.json").read_text())
    asset = next(x for x in catalog["assets"] if x["os"] == "darwin" and x["arch"] == args.arch)
    output = ROOT / "build/macos-probes"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / asset["archive"]
    if not archive.exists():
        url = f"https://github.com/MetaCubeX/mihomo/releases/download/{catalog['version']}/{asset['archive']}"
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=output, delete=False) as file:
                temporary = Path(file.name)
                with urllib.request.urlopen(url, timeout=30) as source:
                    copy_limited(source, file)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != asset["sha256"]:
                raise ValueError("Downloaded runtime checksum mismatch")
            os.replace(temporary, archive)
        finally:
            if temporary:
                temporary.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != asset["sha256"]:
        raise ValueError("Cached runtime checksum mismatch; remove the corrupt archive before retrying")
    binary = output / asset["binary"]
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output, delete=False) as file:
            temporary = Path(file.name)
            with gzip.open(archive, "rb") as source:
                copy_limited(source, file)
        temporary.chmod(0o700)
        os.replace(temporary, binary)
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)
    subprocess.run(["/usr/bin/file", str(binary)], check=True)
    if args.arch == native_arch:
        subprocess.run([str(binary), "-v"], check=True, timeout=10)
    if args.check_config:
        config = args.check_config.resolve(strict=True)
        subprocess.run([str(binary), "-t", "-d", str(config.parent), "-f", str(config)], check=True, timeout=30)


if __name__ == "__main__":
    main()
