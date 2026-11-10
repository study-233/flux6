#!/bin/bash
# Test the built integration runner and helpers through real Flutter channels.
# Run build-flutter-host.sh first. Only the QA clone receives the probe Dart entrypoint.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
project="$root/apps/macos/flutter_ui"
sdk="${FREEV6_FLUTTER_SDK:-$root/build/flutter-toolchain/flutter}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PUB_CACHE="${PUB_CACHE:-$root/build/flutter-toolchain/pub-cache}"
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true CI=true
if [ "$(uname -m)" = arm64 ]; then export FLUTTER_MACOS_ARM64_ONLY=true; fi

bash "$root/scripts/macos/build-flutter-preview.sh" --prepare >/dev/null
qa="$(bash "$root/scripts/macos/build-flutter-host.sh" --qa-clone)"
qa_stage="$(dirname "$qa")"
case "$qa" in
    "$root"/build/macos-ui/host-qa.*/"Flux6 Flutter QA.app") ;;
    *) echo "Unexpected QA bundle location: $qa" >&2; exit 1 ;;
esac

cd "$project"
mkdir -p .dart_tool/freev6-probes
cp "$root/apps/macos/Probes/FlutterHostSmoke.dart" .dart_tool/freev6-probes/host_smoke.dart
"$sdk/bin/flutter" pub get --enforce-lockfile
"$sdk/bin/flutter" build macos --release --no-pub --target .dart_tool/freev6-probes/host_smoke.dart

built="$project/build/macos/Build/Products/Release/Flux6 Flutter Preview.app"
driver="$built/Contents/Frameworks/App.framework"
codesign --verify --strict "$driver"
# Exercise the delivered Swift binary and helper bytes. Only replace Flutter's AOT
# payload, then reseal the QA wrapper that owns this independent sandbox.
mv "$qa/Contents/Frameworks/App.framework" "$qa_stage/consumer-framework"
ditto "$driver" "$qa/Contents/Frameworks/App.framework"
plutil -insert LSUIElement -bool true "$qa/Contents/Info.plist"
codesign --force --sign - --entitlements "$project/macos/Runner/Integration.entitlements" "$qa"
codesign --verify --deep --strict "$qa"
log="$root/build/flutter-toolchain/native-qa-smoke.log"

python3 - "$qa" "$log" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

qa = Path(sys.argv[1])
log = Path(sys.argv[2])
exe = qa / "Contents/MacOS/Flux6 Flutter Integration"
with log.open("wb") as output:
    for round_name, marker in [("first", "HOST-SMOKE PASS"), ("reopen", "HOST-SMOKE REOPEN PASS")]:
        start = time.monotonic()
        process = subprocess.Popen(
            [str(exe)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True,
            env={**os.environ, "FREEV6_HOST_SMOKE_ROUND": round_name},
        )
        try:
            transcript, _ = process.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            transcript, _ = process.communicate()
            output.write(transcript)
            raise SystemExit(f"{round_name} failed to exit normally. See {log}")
        outcome = f"{round_name}: exit={process.returncode} elapsed={time.monotonic() - start:.1f}s\n"
        output.write(transcript + outcome.encode())
        output.flush()
        print(transcript.decode(errors="replace"), end="")
        print(outcome, end="")
        if process.returncode or marker.encode() not in transcript:
            raise SystemExit(f"{round_name} failed. See {log}")
PY
# This directory was created specifically for the probe. Keep a failed QA run for diagnosis.
rm -rf "$qa_stage"
printf '%s\n' "$log"
