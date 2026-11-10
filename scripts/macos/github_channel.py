"""Generate the FreeV6 public update channel from a publisher's Ed25519 public key."""
import argparse
import base64
import json
from pathlib import Path

REPOSITORY = "study-233/free-v6"
FEED_BRANCH = "macos-updates"


def feed_url(arch):
    return f"https://raw.githubusercontent.com/{REPOSITORY}/{FEED_BRANCH}/appcast-{arch}.xml"


def download_base(version, build):
    return f"https://github.com/{REPOSITORY}/releases/download/macos-v{version}-b{build}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-key-file", required=True, type=Path, help="File containing just the base64 public key")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    public = args.public_key_file.read_text().strip()
    if len(public) != 44 or len(base64.b64decode(public, validate=True)) != 32:
        parser.error("Expected a 32-byte base64 Ed25519 public key")
    config = {"format": 1, "publicKey": public, "feeds": {arch: feed_url(arch) for arch in ("arm64", "x86_64")}}
    with args.output.open("x") as file:
        json.dump(config, file, indent=2)
        file.write("\n")


if __name__ == "__main__":
    main()
