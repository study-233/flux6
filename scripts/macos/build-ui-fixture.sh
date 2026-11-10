#!/bin/bash
# Build the native UI against an isolated worker and in-memory session replies.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT
SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
bash "$root/scripts/macos/swift.sh" build -c debug --product FreeV6
products="$(bash "$root/scripts/macos/swift.sh" build -c debug --show-bin-path)"
case "${1:-}" in
    "") fixture_name="FreeV6 UI Fixture"; fixture_id=dev.freev6.interface-fixture ;;
    --preview) fixture_name="FreeV6 UI Preview"; fixture_id=dev.freev6.interface-preview ;;
    *) echo "usage: $0 [--preview]" >&2; exit 2 ;;
esac
app="$root/build/macos-ui/$fixture_name.app"
mkdir -p "$root/build/macos-ui"
source "$root/scripts/macos/app-stage.sh"
begin_app_stage "$app" "$root/build/macos-ui/stage.XXXXXX"
contents="$bundle/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources/Notices" "$contents/Helpers"
cp "$root/dist/macos/FreeV6.app/Contents/Helpers/freev6-worker" "$contents/Helpers/"
cp "$root/dist/macos/FreeV6.app/Contents/Resources/"runtime-assets.json "$contents/Resources/"
printf '%s\n' 'Local UI test fixture' | tee "$contents/Resources/Notices/agreement.md" > "$contents/Resources/Notices/privacy.md"
cp "$root/macos/Resources/Info.plist" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$fixture_id" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$fixture_name" "$contents/Info.plist"
sources=()
for source in "$root"/macos/Sources/FreeV6App/*.swift; do
    if [[ "$source" != */InstallationApp.swift ]]; then sources+=("$source"); fi
done
/usr/bin/xcrun swiftc -D FREEV6_UI_FIXTURE -parse-as-library -target "$(uname -m)-apple-macos14.0" -sdk "$SDKROOT" \
    -I "$products" -module-cache-path "$root/build/macos-module-cache" \
    "${sources[@]}" "$root/macos/Probes/InterfaceStates.swift" "$products"/FreeV6{Business,Configuration,Desktop,System,UpdateSupport}.o \
    -o "$contents/MacOS/FreeV6"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
publish_staged_app
printf '%s\n' "$app"
