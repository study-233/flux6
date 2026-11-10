#!/bin/bash
# Isolated Flutter integration build with the real worker and a private session child.
set -euo pipefail
if [ "$#" -eq 0 ]; then
    exec bash "$(dirname "$0")/build-flutter-preview.sh" --host
fi
if [ "$#" -ne 1 ] || [ "$1" != "--qa-clone" ]; then
    echo "usage: $0 [--qa-clone]" >&2; exit 2
fi
# Every QA run receives a unique sandbox and NSUserDefaults domain. Only the QA
# bundle contains the consent fixture; the delivered integration app never does.
root="$(cd "$(dirname "$0")/../.." && pwd)"
source="$root/build/macos-ui/FreeV6 Flutter Integration.app"
codesign --verify --deep --strict "$source"
stage="$(mktemp -d "$root/build/macos-ui/host-qa.XXXXXX")"
bundle="$stage/FreeV6 Flutter QA.app"
ditto "$source" "$bundle"
identifier="dev.freev6.flutter-host.qa.$(uuidgen | tr '[:upper:]' '[:lower:]')"
plist="$bundle/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$identifier" "$plist"
plutil -replace CFBundleName -string "FreeV6 Flutter QA" "$plist"
seed="$(python3 - "$bundle/Contents/Resources/Notices" <<'PY'
from pathlib import Path
import base64, hashlib, sys
folder = Path(sys.argv[1])
print(base64.b64encode(b''.join(hashlib.sha256((folder / f).read_bytes()).digest()
                               for f in ['agreement.md', 'privacy.md'])).decode())
PY
)"
plutil -insert FreeV6QAStartupNotices -string "$seed" "$plist"
codesign --force --sign - --entitlements "$root/apps/macos/flutter_ui/macos/Runner/Integration.entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"
printf '%s\n' "$bundle"
