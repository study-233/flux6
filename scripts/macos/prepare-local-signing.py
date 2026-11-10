#!/usr/bin/env python3
"""Reuse a private local signing certificate across candidate builds.

This is not a Developer ID or notarization. Only the public certificate ships.
No system trust changes or all-apps Keychain access are made.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True).stdout


def require_private(path, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError(f"Expected a private, user-owned signing {'directory' if directory else 'file'}: {path}")


def prepare(root):
    os.umask(0o077)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    require_private(root, directory=True)
    build = ROOT / "build/macos-signing"
    build.mkdir(parents=True, exist_ok=True)
    helper = build / "keychain-tool"
    source = ROOT / "scripts/macos/local-signing-keychain.swift"
    if not helper.exists() or helper.stat().st_mtime < source.stat().st_mtime:
        env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
        subprocess.run(["/usr/bin/xcrun", "swiftc", str(source), "-o", str(helper)], env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    password, certificate, keychain = root / "password", root / "certificate.der", root / "signing.keychain-db"
    if not keychain.exists():
        if any(root.iterdir()):
            raise RuntimeError("Incomplete local signing identity; preserve it for inspection instead of rotating the certificate")
        password.write_text(secrets.token_hex(32))
        with tempfile.TemporaryDirectory(prefix="generation-", dir=root) as temporary:
            stage = Path(temporary)
            config = stage / "certificate.cnf"
            config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
                              '[dn]\nCN=FreeV6 Local Builds\n[ext]\nbasicConstraints=critical,CA:FALSE\n'
                              'keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n'
                              'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n')
            run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650",
                 "-config", config, "-keyout", stage / "key.pem", "-out", stage / "cert.pem"])
            run(["/usr/bin/openssl", "x509", "-in", stage / "cert.pem", "-outform", "der", "-out", certificate])
            run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", stage / "key.pem", "-in", stage / "cert.pem",
                 "-out", root / "identity.p12", "-passout", "file:" + str(password)])
            try:
                run([helper, "create", root])
            finally:
                (root / "identity.p12").unlink(missing_ok=True)
    for path in (password, certificate, keychain):
        require_private(path)
    run([helper, "unlock", root])
    fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest()
    return {"identity": fingerprint, "keychain": str(keychain), "certificate": str(certificate)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path,
                        default=Path.home() / "Library/Application Support/dev.freev6.build-signing")
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.directory.resolve())))
    except subprocess.CalledProcessError as error:
        # Do not echo arguments or the contents of secret files.
        raise SystemExit("Local signing preparation failed: " + error.stderr.decode(errors="replace")[-2000:])
