#!/bin/bash
# Dart checks for the Windows project on the current development host.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
sdk="${FREEV6_FLUTTER_SDK:-$root/build/flutter-toolchain/flutter}"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$root/build/flutter-toolchain/config}"
export PUB_CACHE="${PUB_CACHE:-$root/build/flutter-toolchain/pub-cache}"
"$sdk/bin/flutter" --version --machine | python3 -c 'import json,sys; v=json.load(sys.stdin)["frameworkVersion"]; sys.exit(0 if v=="3.47.6" else f"Expected Flutter 3.47.6, found {v}")'
cd "$root/apps/windows/flutter_ui"
exec "$sdk/bin/flutter" "$@"
