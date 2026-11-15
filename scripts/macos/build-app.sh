#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
configuration="${CONFIGURATION:-release}"
if [ "$configuration" != release ] || [ "$(uname -m)" != arm64 ]; then
    echo "Build the Apple Silicon candidate in release mode on an arm64 Mac." >&2; exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export GOCACHE="${GOCACHE:-$project_root/build/macos-go-cache}"
mkdir -p "$project_root/build" "$project_root/dist/macos"
# Local candidates use one private certificate across builds. A supplied
# Developer ID (or explicit '-' for isolated probes) keeps the selected mode.
if [ -z "${FREEV6_CODESIGN_IDENTITY:-}" ]; then
    signing_config="$(python3 "$project_root/scripts/macos/prepare-local-signing.py")"
    FREEV6_CODESIGN_IDENTITY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"])' <<< "$signing_config")"
    FREEV6_CODESIGN_KEYCHAIN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["keychain"])' <<< "$signing_config")"
    export FREEV6_CODESIGN_IDENTITY FREEV6_CODESIGN_KEYCHAIN FREEV6_LOCAL_SIGNING=1
fi
identity="${FREEV6_CODESIGN_IDENTITY}"
codesign_flags=(/usr/bin/codesign)
if [ -n "${FREEV6_CODESIGN_KEYCHAIN:-}" ]; then codesign_flags+=(--keychain "$FREEV6_CODESIGN_KEYCHAIN"); fi
go_bin="${GO_BIN:-go}"
go_arch=arm64
bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --product freev6-network-service
binary_dir="$(bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --show-bin-path)"
app="${FREEV6_APP_OUTPUT:-$project_root/dist/macos/Flux6.app}"
mkdir -p "$(dirname "$app")"
source "$project_root/scripts/macos/app-stage.sh"
begin_app_stage "$app" "$project_root/build/macos-bundle.XXXXXX"
bash "$project_root/scripts/macos/build-flutter-runner.sh" "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Helpers" \
    "$bundle/Contents/Library/LaunchServices" "$project_root/dist/macos"
(
    cd "$project_root"
    GOOS=darwin GOARCH="$go_arch" GOAMD64=v1 CGO_ENABLED=0 "$go_bin" build -trimpath \
        -o "$bundle/Contents/Helpers/freev6-worker" ./cmd/freev6-worker
)
"${codesign_flags[@]}" --force --sign "$identity" --options runtime --identifier dev.freev6.worker "$bundle/Contents/Helpers/freev6-worker"
bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --product freev6-login-launcher
cp "$binary_dir/freev6-login-launcher" "$bundle/Contents/Helpers/freev6-login-launcher"
python3 "$project_root/scripts/macos/release_rpaths.py" "$bundle/Contents/Helpers/freev6-login-launcher"
"${codesign_flags[@]}" --force --sign "$identity" --options runtime --identifier dev.freev6.desktop.login "$bundle/Contents/Helpers/freev6-login-launcher"
service="$bundle/Contents/Library/LaunchServices/dev.freev6.network-service"
cp "$binary_dir/freev6-network-service" "$service"
python3 "$project_root/scripts/macos/release_rpaths.py" "$service"
"${codesign_flags[@]}" --force --sign "$identity" --options runtime --identifier dev.freev6.network-service "$service"
# Take a provisional seal before building the installer, whose signed manifest will pin
# this executable and its exact kernel library constraint independently of mutable resources.
client_seal=""
if [ "$identity" = "-" ] || [ "${FREEV6_LOCAL_SIGNING:-0}" = 1 ]; then
    python3 "$project_root/scripts/macos/sign_flutter_host.py" "$bundle"
    bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --product freev6-probe
    client_seal="$("$binary_dir/freev6-probe" flutter-client-seal "$bundle/Contents/MacOS/Flux6")"
fi
manifest="$(python3 - "$service" "$project_root/build" "$client_seal" <<'PY'
import hashlib, plistlib, sys
from pathlib import Path
digest = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
spec = {'CFBundleIdentifier': 'dev.freev6.service-installer',
    'CFBundleName': 'Flux6 Service Installer', 'CFBundleVersion': '1', 'FreeV6ServiceSHA256': digest}
if sys.argv[3]: spec['FreeV6FlutterClientSeal'] = sys.argv[3]
contents = plistlib.dumps(spec)
path = Path(sys.argv[2]) / ('bootstrap-manifest-' + hashlib.sha256(contents).hexdigest() + '.plist')
path.write_bytes(contents)
print(path)
PY
)"
FREEV6_BOOTSTRAP_MANIFEST="$manifest" bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --product freev6-service-installer
cp "$binary_dir/freev6-service-installer" "$bundle/Contents/Helpers/freev6-service-installer"
python3 "$project_root/scripts/macos/release_rpaths.py" "$bundle/Contents/Helpers/freev6-service-installer"
"${codesign_flags[@]}" --force --sign "$identity" --options runtime --identifier dev.freev6.service-installer "$bundle/Contents/Helpers/freev6-service-installer"
cp "$project_root/internal/mihomo/runtime-assets.json" "$bundle/Contents/Resources/runtime-assets.json"
sparkle="$(python3 "$project_root/scripts/macos/prepare-sparkle.py" --directory "$stage/SparkleSDK")"
FREEV6_UPDATE_PROBE_BUILD=0 FREEV6_SPARKLE_FRAMEWORK_DIR="$sparkle" bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --product freev6-update-agent
updater_args=("$bundle" "$binary_dir/freev6-update-agent" "$sparkle"
    --channel "${FREEV6_UPDATE_CHANNEL_FILE:-$project_root/apps/macos/Resources/update-channel.json}")
python3 "$project_root/scripts/macos/bundle-updater.py" "${updater_args[@]}"
notices="$bundle/Contents/Resources/Notices"
mkdir -p "$notices"
go_root="$("$go_bin" env GOROOT)"
cp "$go_root/LICENSE" "$notices/Go-LICENSE.txt"
cp "$project_root/LICENSE" "$notices/Flux6-LICENSE.txt"
cp "$project_root/THIRD-PARTY.txt" "$notices/THIRD-PARTY.txt"
cp "$project_root/third_party/licenses/yaml.v3-LICENSE.txt" "$project_root/third_party/licenses/Apache-2.0.txt" "$notices/"
cp "$project_root/docs/agreement.md" "$notices/"
{ cat "$project_root/apps/macos/Resources/privacy-macos.md"; printf '\n\n'; cat "$project_root/docs/privacy.md"; } > "$notices/privacy.md"
python3 "$project_root/scripts/macos/flutter-source-release.py" notices --contents "$bundle/Contents"
python3 "$project_root/scripts/macos/sign_flutter_host.py" "$bundle"
if [ "$identity" = "-" ] || [ "${FREEV6_LOCAL_SIGNING:-0}" = 1 ]; then
    actual_seal="$("$binary_dir/freev6-probe" flutter-client-seal "$bundle/Contents/MacOS/Flux6")"
    if [ "$client_seal" != "$actual_seal" ]; then
        echo "The final host does not match the installer-pinned executable and library constraint." >&2; exit 1
    fi
fi
python3 "$project_root/scripts/macos/build-dmg.py" --verify-app "$bundle"
publish_staged_app
printf '%s\n' "$app"
