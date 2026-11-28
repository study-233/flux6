#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/scripts/android/env.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export FLUTTER_MACOS_ARM64_ONLY=true FLUTTER_SWIFT_PACKAGE_MANAGER=true
[[ "$(uname -m)" == arm64 ]]
app="${FREEV6_APP_OUTPUT:-$root/dist/macos/Flux6.app}"
mkdir -p "$(dirname "$app")" "$root/build"
source "$root/scripts/macos/app-stage.sh"
begin_app_stage "$app" "$root/build/macos-bundle.XXXXXX"
cd "$root/apps/android"
flutter pub get --offline --enforce-lockfile || flutter pub get --enforce-lockfile
flutter build macos --release --no-pub --dart-define=APP_ENV=stable
ditto build/macos/Build/Products/Release/Flux6.app "$bundle"
if [[ -z "${FREEV6_CODESIGN_IDENTITY:-}" ]]; then
  settings="$(python3 "$root/scripts/macos/prepare-local-signing.py")"
  FREEV6_CODESIGN_IDENTITY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"])' <<< "$settings")"
  FREEV6_CODESIGN_KEYCHAIN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["keychain"])' <<< "$settings")"
  export FREEV6_CODESIGN_IDENTITY FREEV6_CODESIGN_KEYCHAIN FREEV6_LOCAL_SIGNING=1
fi
sign=(/usr/bin/codesign --force --options runtime --sign "$FREEV6_CODESIGN_IDENTITY")
if [[ -n "${FREEV6_CODESIGN_KEYCHAIN:-}" ]]; then sign+=(--keychain "$FREEV6_CODESIGN_KEYCHAIN"); fi
plutil -insert Flux6UnifiedClient -bool true "$bundle/Contents/Info.plist"
notices="$bundle/Contents/Resources/Notices"
mkdir -p "$notices"
cp "$root/apps/android/LICENSE" "$notices/FlClash-LICENSE.txt"
cp "$root/apps/android/plugins/prism_ui/NOTICE" "$notices/PrismUI-NOTICE.txt"
cp "$root/apps/android/plugins/prism_ui/LICENSE" "$notices/PrismUI-LICENSE.txt"
cp "$root/apps/android/core/Clash.Meta/LICENSE" "$notices/mihomo-LICENSE.txt"
cp "$root"/{LICENSE,THIRD-PARTY.txt} "$root"/docs/{agreement,privacy}.md "$notices/"
for fw in "$bundle"/Contents/Frameworks/*.framework; do "${sign[@]}" "$fw"; done
"${sign[@]}" "$bundle/Contents/MacOS/FlClashCore"
python3 "$root/scripts/macos/sign_flutter_host.py" "$bundle"
python3 "$root/scripts/macos/build-dmg.py" --verify-app "$bundle"
publish_staged_app
printf '%s\n' "$app"
