#!/usr/bin/env python3
"""Materialize the checksum-pinned SDK from its official release archive."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def prepare(directory):
    spec = json.loads((ROOT / "macos/Dependencies/sparkle.json").read_text())
    cache = ROOT / "build/sparkle-probe"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / spec["archive"]
    with tempfile.TemporaryDirectory(prefix="sparkle-stage-", dir=cache) as staging:
        stage = Path(staging)
        if not archive.is_file():
            download = stage / "download"
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                            "--proto", "=https", "--proto-redir", "=https", "--max-time", "180",
                            "--output", download, spec["url"]], check=True)
            if hashlib.sha256(download.read_bytes()).hexdigest() != spec["sha256"]:
                raise RuntimeError("Sparkle release digest mismatch")
            download.replace(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != spec["sha256"]:
            raise RuntimeError("Cached Sparkle release digest mismatch")
        # Re-extract to avoid trusting a modified extracted SDK.
        directory.mkdir(parents=True, exist_ok=False)
        with tarfile.open(archive, "r:xz") as source:
            source.extractall(directory, filter="data")
    return directory


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    print(prepare(parser.parse_args().directory))
