#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
configuration="${CONFIGURATION:-release}"
go_bin="${GO_BIN:-go}"
case "$(uname -m)" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *) printf '%s\n' "unsupported host architecture" >&2; exit 1 ;;
esac
bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --product freev6-network-service
binary_dir="$(bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --show-bin-path)"
app="$project_root/dist/macos/FreeV6.app"
stage="$(mktemp -d "$project_root/build/macos-bundle.XXXXXX")"
bundle="$stage/FreeV6.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Helpers" \
    "$bundle/Contents/Library/LaunchServices" "$project_root/dist/macos"
(
    cd "$project_root"
    GOOS=darwin GOARCH="$go_arch" GOAMD64=v1 CGO_ENABLED=0 "$go_bin" build -trimpath \
        -o "$bundle/Contents/Helpers/freev6-worker" ./cmd/freev6-worker
)
/usr/bin/codesign --force --sign - --options runtime --identifier dev.freev6.worker "$bundle/Contents/Helpers/freev6-worker"
service="$bundle/Contents/Library/LaunchServices/dev.freev6.network-service"
cp "$binary_dir/freev6-network-service" "$service"
/usr/bin/codesign --force --sign - --options runtime --identifier dev.freev6.network-service "$service"
manifest="$(python3 - "$service" "$project_root/build" <<'PY'
import hashlib, plistlib, sys
from pathlib import Path
digest = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
path = Path(sys.argv[2]) / ('bootstrap-manifest-' + digest + '.plist')
path.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.freev6.service-installer',
    'CFBundleName': 'FreeV6 Service Installer', 'CFBundleVersion': '1', 'FreeV6ServiceSHA256': digest}))
print(path)
PY
)"
FREEV6_BOOTSTRAP_MANIFEST="$manifest" bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --product freev6-service-installer
cp "$binary_dir/freev6-service-installer" "$bundle/Contents/Helpers/freev6-service-installer"
/usr/bin/codesign --force --sign - --options runtime --identifier dev.freev6.service-installer "$bundle/Contents/Helpers/freev6-service-installer"
bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --product FreeV6
cp "$binary_dir/FreeV6" "$bundle/Contents/MacOS/FreeV6"
cp "$project_root/macos/Resources/Info.plist" "$bundle/Contents/Info.plist"
notices="$bundle/Contents/Resources/Notices"
mkdir -p "$notices"
go_root="$("$go_bin" env GOROOT)"
cp "$go_root/LICENSE" "$notices/Go-LICENSE.txt"
cp "$project_root/LICENSE" "$notices/FreeV6-LICENSE.txt"
cp "$project_root/src-tauri/LICENSES/yaml.v3-LICENSE.txt" "$project_root/src-tauri/LICENSES/Apache-2.0.txt" "$notices/"
cp "$project_root/docs/agreement.md" "$project_root/docs/privacy.md" "$notices/"
/usr/bin/codesign --force --sign - --options runtime --identifier dev.freev6.desktop "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
"$bundle/Contents/Helpers/freev6-service-installer" manifest
if [ -e "$app" ]; then mv "$app" "$stage/Previous.app"; fi
mv "$bundle" "$app"
printf '%s\n' "$app"
