"""Isolated keychain operations inside versions of the native Sparkle test host."""
import json
import os
import plistlib
import re
import shutil
import subprocess


def compiler_arguments(root, work, compiler, env, run):
    # Link the same business sources as Flux6 without exposing a public
    # product API for selecting alternate keychains.
    sources = root / "apps/macos/Sources"
    config = work / "FreeV6Configuration.swiftmodule"
    library = work / "libFreeV6Configuration.a"
    run([*compiler, "-module-name", "FreeV6Configuration", "-emit-module", "-emit-module-path", config,
         "-emit-library", "-static", *sorted((sources / "FreeV6Configuration").glob("*.swift")), "-o", library], env=env)
    return ["-D", "FREEV6_KEYCHAIN_PROBE", "-I", work, library,
            *sorted((sources / "FreeV6Business").glob("*.swift")), root / "apps/macos/Probes/KeychainUpgrade.swift"]


def cdhash(app):
    result = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", app], capture_output=True, text=True, check=True)
    return re.search(r"^CDHash=([a-f0-9]+)$", result.stderr, re.M)[1]


def search_list():
    return subprocess.check_output(["/usr/bin/security", "list-keychains", "-d", "user"])


class KeychainUpgrade:
    def __init__(self, work):
        self.directory = work / "private-keychain-fixture"
        self.directory.mkdir(mode=0o700)
        self.previous = work / "previous/Flux6.app"
        self.password = os.urandom(32)
        self.original_list = search_list()

    def invoke(self, app, command):
        result = subprocess.run([app / "Contents/MacOS/Flux6", "--keychain-upgrade", command, self.directory],
                                input=self.password, capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))
        return json.loads(result.stdout) if command != "remove" else None

    def seed(self, root, app):
        shutil.copyfile(root / "shared/fixtures/warp-credential.json", self.directory / "warp-credential.json")
        subprocess.run(["/usr/bin/ditto", app, self.previous], check=True)
        self.source_hash = cdhash(app)
        self.original = self.invoke(app, "create")
        if set(self.original) != {"warp", "cloud", "chain"} or "requires-authorization" in self.original.values():
            raise RuntimeError("The signed creator could not read its own synthetic records")
        if self.invoke(app, "inspect") != self.original:
            raise RuntimeError("The same build did not recover its records in a new process")
        unrelated = self.directory.parent / "Unrelated.app"
        subprocess.run(["/usr/bin/ditto", app, unrelated], check=True)
        plist = unrelated / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleIdentifier"] += ".unrelated"
        plist.write_bytes(plistlib.dumps(info))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", unrelated], check=True)
        denied = self.invoke(unrelated, "inspect")
        if denied != dict.fromkeys(self.original, "requires-authorization"):
            raise RuntimeError("The unrelated ad-hoc identity must not read any record without approval")

    def inspect_upgrade_and_rollback(self, app):
        upgraded_hash = cdhash(app)
        if self.source_hash == upgraded_hash:
            raise RuntimeError("The upgraded host must have a distinct signature")
        upgraded = self.invoke(app, "inspect")
        registration = self.invoke(app, "registration-check")
        if registration not in ("requires-authorization", "rejected-existing-record"):
            raise RuntimeError("The upgraded host accepted an implicit replacement")
        access = {}
        for kind, first in self.original.items():
            observed = upgraded[kind]
            if observed == "requires-authorization":
                access[kind] = observed
            elif observed == first:
                access[kind] = "read-original"
            else:
                raise RuntimeError(f"The update lost or changed the {kind} record")
        # Retain the successfully installed N+1 for inspection and restore
        # the original signed N at exactly the same installed path.
        restored = self.directory.parent / "rollback/Flux6.app"
        subprocess.run(["/usr/bin/ditto", self.previous, restored], check=True)
        updated = self.directory.parent / "updated.app"
        app.rename(updated)
        try:
            restored.rename(app)
        except BaseException:
            updated.rename(app)
            raise
        if cdhash(app) != self.source_hash or self.invoke(app, "inspect") != self.original:
            raise RuntimeError("Rollback failed to recover all original revisions and data")
        return {"sourceCDHash": self.source_hash, "installedCDHash": upgraded_hash, "noninteractiveUpgrade": access,
                "unrelatedIdentityDenied": sorted(self.original), "registrationPreflight": registration,
                "rollbackReadAllOriginalRecords": True, "networkRegistration": False}

    def clean(self):
        path = self.directory / "credentials.keychain-db"
        if path.exists():
            self.invoke(self.previous, "remove")
        if path.exists() or search_list() != self.original_list:
            raise RuntimeError("Temporary keychain cleanup or user search-list comparison failed")
