#!/usr/bin/env python3
"""Verify two differently built, consistently signed clients share a Keychain item.

Uses a disposable Keychain and synthetic value. UI is disabled in every process;
an unrelated ad-hoc signature must be refused even with the same identifier.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = r'''
import Foundation
import Security
let args = Array(CommandLine.arguments.dropFirst())
let root = URL(fileURLWithPath: args[1])
let path = root.appendingPathComponent("fixture.keychain-db").path
let password = try Data(contentsOf: root.appendingPathComponent("password"))
SecKeychainSetUserInteractionAllowed(false)
func checked(_ status: OSStatus) {
    guard status == errSecSuccess else { print("STATUS \(status)"); exit(1) }
}
var keychain: SecKeychain?
var oldSearch: CFArray?
checked(SecKeychainCopySearchList(&oldSearch))
defer { if let oldSearch { SecKeychainSetSearchList(oldSearch) } }
if args[0] == "create" {
    password.withUnsafeBytes { checked(SecKeychainCreate(path, UInt32($0.count), $0.baseAddress, false, nil, &keychain)) }
} else {
    checked(SecKeychainOpen(path, &keychain))
    password.withUnsafeBytes { checked(SecKeychainUnlock(keychain, UInt32($0.count), $0.baseAddress, true)) }
}
guard let keychain else { exit(2) }
if args[0] == "delete" { checked(SecKeychainDelete(keychain)); exit(0) }
var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "dev.freev6.synthetic.upgrade", kSecAttrAccount as String: "fixture",
    kSecUseDataProtectionKeychain as String: false]
if args[0] == "create" {
    query[kSecUseKeychain as String] = keychain
    query[kSecValueData as String] = Data("synthetic-only".utf8)
    checked(SecItemAdd(query as CFDictionary, nil))
} else {
    query[kSecMatchSearchList as String] = [keychain]
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if args[0] == "reject" {
        guard [errSecAuthFailed, errSecInteractionNotAllowed].contains(status) else { print("Unexpected status \(status)"); exit(1) }
    } else {
        checked(status)
        guard item as? Data == Data("synthetic-only".utf8) else { exit(2) }
    }
}
print("BUILD_MARKER")
'''


def run(args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, timeout=60)


def exercise(signing):
    with tempfile.TemporaryDirectory(prefix="keychain-upgrade-", dir=ROOT / "build") as temporary:
        folder = Path(temporary)
        folder.chmod(0o700)
        password = folder / "password"
        password.write_text(secrets.token_hex(32)); password.chmod(0o600)
        executables, requirements = [], []
        for version in ("first", "upgraded", "unrelated"):
            source, binary = folder / (version + ".swift"), folder / version
            source.write_text(SOURCE.replace("BUILD_MARKER", version))
            run(["/usr/bin/xcrun", "swiftc", source, "-o", binary])
            flags = ["--sign", "-" if version == "unrelated" else signing["identity"]]
            if version != "unrelated":
                flags += ["--keychain", signing["keychain"]]
            run(["/usr/bin/codesign", "--force", *flags, "--options", "runtime", "--identifier", "dev.freev6.keychain-upgrade", binary])
            requirements.append(run(["/usr/bin/codesign", "-d", "-r-", binary]).stdout.strip())
            executables.append(binary)
        assert hashlib.sha256(executables[0].read_bytes()).digest() != hashlib.sha256(executables[1].read_bytes()).digest()
        assert requirements[0] == requirements[1] and requirements[1] != requirements[2], requirements
        try:
            run([executables[0], "create", folder])
            run([executables[1], "read", folder])
            run([executables[2], "reject", folder])
            run([executables[1], "read", folder])
        finally:
            if (folder / "fixture.keychain-db").exists():
                run([executables[0], "delete", folder])
        return {"passed": True, "sameRequirementAcrossDifferentBinaries": True, "upgradedClientReadWithoutUI": True,
                "sameIdentifierUnrelatedSignatureRejected": True, "originalAccessPreserved": True,
                "certificateSHA1": signing["identity"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--signing-config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    result = exercise(json.loads(args.signing_config.read_text()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
