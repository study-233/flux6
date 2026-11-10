#!/usr/bin/env python3
"""Exercise macOS library-load enforcement and the privileged installer's pinned client without installing it."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

import sign_flutter_host

ROOT = Path(__file__).resolve().parents[2]


def run(*args, success=True, env=None):
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if success != (result.returncode == 0):
        raise RuntimeError(f"{args}: {result.stdout} {result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    helpers = app / "Contents/Helpers"
    manifest = json.loads(run(helpers / "freev6-service-installer", "manifest").stdout)
    if "flutterClientSeal" not in manifest:
        raise ValueError("This probe targets the constrained local ad-hoc release")
    probe_dir = run("bash", ROOT / "scripts/macos/swift.sh", "build", "-c", "release", "--show-bin-path").stdout.strip()
    probe = Path(probe_dir) / "freev6-probe"
    cases = []
    with tempfile.TemporaryDirectory(prefix="p6-signing-", dir=ROOT / "build") as temporary:
        stage = Path(temporary)
        libs = sign_flutter_host.host_libraries(app)
        library = [lib / lib.stem for lib in libs]
        hashes = [sign_flutter_host.cdhash(lib) for lib in libs]
        rights = stage / "rights.plist"
        rights.write_bytes(plistlib.dumps(sign_flutter_host.LOCAL_RIGHTS))
        constraint = stage / "constraint.plist"
        constraint.write_bytes(plistlib.dumps({"cdhash": {"$in": hashes}}))
        source = stage / "loader.c"
        source.write_text('#include <dlfcn.h>\n#include <stdio.h>\nint main(int argc, char **args) {\n'
                          '  if (argc != 2) return 2;\n'
                          '  if (!dlopen(args[1], RTLD_NOW)) { puts(dlerror()); return 1; }\n'
                          '  puts("LOADED"); return 0;\n}\n')
        loader = stage / "loader"
        run("/usr/bin/xcrun", "clang", source, "-o", loader)
        def sign(path, *, pinned=True):
            flags = ["--entitlements", rights, "--library-constraint", constraint] if pinned else []
            run("/usr/bin/codesign", "-f", "-s", "-", "--options", "runtime", *flags, path)
        sign(loader, pinned=False)
        if "Team ID" not in run(loader, library[1], success=False).stdout:
            raise RuntimeError("Unconstrained baseline should reject the ad-hoc embedded Flutter engine")
        cases.append("stock hardened ad-hoc policy rejects Flutter with no Team ID")
        sign(loader)
        for item in library:
            run(loader, item)
        cases.append("kernel permits the exact two AOT/engine CDHashes")
        evil = stage / "extra.dylib"
        marker = stage / "injected"
        source.write_text('#include <stdio.h>\n#include <stdlib.h>\n__attribute__((constructor)) static void entry(void){\n'
                          ' const char *p = getenv("FREEV6_PROBE_MARKER"); if (p) { FILE *f = fopen(p,"w"); if (f) fclose(f); }}\n')
        run("/usr/bin/xcrun", "clang", "-dynamiclib", source, "-o", evil)
        run("/usr/bin/codesign", "-f", "-s", "-", evil)
        denial = run(loader, evil, success=False).stdout.lower()
        if "library load" not in denial:
            raise RuntimeError(f"Expected a library-constraint rejection: {denial}")
        run(loader, library[0], env={**os.environ, "DYLD_INSERT_LIBRARIES": str(evil), "FREEV6_PROBE_MARKER": str(marker)})
        if marker.exists():
            raise RuntimeError("Unexpected code injection into hardened constrained process")
        cases.append("extra dylib and DYLD_INSERT_LIBRARIES injection rejected")
        run(probe, "payload", app, stage / "good", manifest["serviceSHA256"])
        cases.append("actual candidate accepted by unprivileged copy of the real installer staging path")
        altered = stage / "Flux6.app"
        shutil.copytree(app, altered, symlinks=True)
        target = altered / "Contents/Frameworks/App.framework/Versions/A/App"
        shutil.copy2(evil, target)
        run("/usr/bin/codesign", "--verify", "--strict", "--deep", altered, success=False)
        run(loader, target, success=False)
        cases.append("unexpected library replacing App.framework is denied after signing")
        # Even a self-consistent, re-signed outer package allowing the replacement cannot enroll
        # with the original installer. Its immutable signed manifest pins the original runner+constraint.
        run("/usr/bin/codesign", "-f", "-s", "-", "--options", "runtime", target.parents[2])
        sign_flutter_host.sign_host(altered)
        run(probe, "payload", altered, stage / "forged", manifest["serviceSHA256"], success=False)
        cases.append("forged outer and replacement kernel allowlist fail trusted installer fingerprint")
        run("/usr/bin/codesign", "-f", "-s", "-", "--options", "runtime", "--entitlements", rights, altered)
        run(probe, "payload", altered, stage / "no-constraint", manifest["serviceSHA256"], success=False)
        cases.append("plain disable-library-validation without kernel constraint cannot enroll")
        sign(altered, pinned=False)
        run(probe, "payload", altered, stage / "forged-strict", manifest["serviceSHA256"], success=False)
        cases.append("removing the exception cannot bypass the genuine installer's pinned client")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"app": str(app), "clientSeal": manifest["flutterClientSeal"],
                                       "cases": cases}, indent=2) + "\n")
    print("PASS", args.output)


if __name__ == "__main__":
    main()
