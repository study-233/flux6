#!/bin/bash
# Build the isolated Flutter interface preview for this Mac.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_dir="$project_root/macos/flutter_ui"
toolchain="$project_root/build/flutter-toolchain"
version=3.47.6
case "$(uname -m)" in
    arm64)
        archive="flutter_macos_arm64_${version}-stable.zip"
        digest=a1946d3b6b3de15ce247dc89649df9035ce29e6b4e7ebe91919a25890ea2e79a
        ;;
    x86_64)
        archive="flutter_macos_${version}-stable.zip"
        digest=f1f68c777b2b34153e1631670445efbeb218f42a398be32bba2051476719b0a4
        ;;
    *) echo "Unsupported macOS host architecture" >&2; exit 1 ;;
esac

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PUB_CACHE="${PUB_CACHE:-$toolchain/pub-cache}"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export CI=true
mkdir -p "$toolchain" "$PUB_CACHE"
sdk="${FREEV6_FLUTTER_SDK:-$toolchain/flutter}"
installed_archive=""
if [ ! -x "$sdk/bin/flutter" ]; then
    if [ -n "${FREEV6_FLUTTER_SDK:-}" ]; then
        echo "Missing Flutter SDK in FREEV6_FLUTTER_SDK: $sdk" >&2
        exit 1
    fi
    zip="$toolchain/$archive"
    if [ ! -f "$zip" ]; then
        curl --fail --location --retry 2 --continue-at - \
            "https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/$archive" \
            --output "$zip.part"
        mv "$zip.part" "$zip"
    fi
    printf '%s  %s\n' "$digest" "$zip" | shasum -a 256 -c -
    sdk_stage="$(mktemp -d "$toolchain/sdk-stage.XXXXXX")"
    /usr/bin/unzip -q "$zip" 'flutter/*' -d "$sdk_stage"
    mv "$sdk_stage/flutter" "$sdk"
    rmdir "$sdk_stage"
    installed_archive="$zip"
fi
export PATH="$sdk/bin:$PATH"
flutter --version --machine | python3 -c \
    'import json, sys; current=json.load(sys.stdin)["frameworkVersion"]; expected=sys.argv[1]; sys.exit(0 if current == expected else f"Expected Flutter {expected}, found {current}")' "$version"
if [ -n "$installed_archive" ]; then rm -f "$installed_archive"; fi
case "${1:-}" in
    --prepare) printf '%s\n' "$sdk"; exit 0 ;;
    --host) integration=true ;;
    '') integration=false ;;
    *) echo "usage: $0 [--prepare|--host]" >&2; exit 2 ;;
esac

cd "$app_dir"
if [ -f pubspec.lock ]; then
    flutter pub get --enforce-lockfile
else
    flutter pub get
fi
preview_name="FreeV6 Flutter Preview"
if $integration; then
    product="FreeV6 Flutter Integration"
    target="lib/live_main.dart"
    # Both embedded helpers target this host architecture.
    if [ "$(uname -m)" = arm64 ]; then export FLUTTER_MACOS_ARM64_ONLY=true; fi
else
    product="$preview_name"
    target="lib/main.dart"
fi
flutter build macos --release --no-pub --target "$target"
name="$product.app"
built="$app_dir/build/macos/Build/Products/Release/$preview_name.app"
test -d "$built/Contents/Frameworks/FlutterMacOS.framework"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$built/Contents/Info.plist")" = "dev.freev6.flutter-preview"
for framework in "$built"/Contents/Frameworks/*.framework; do
    /usr/bin/codesign --verify --strict "$framework"
done
output="$project_root/build/macos-ui"
mkdir -p "$output"
source "$project_root/scripts/macos/app-stage.sh"
begin_app_stage "$output/$name" "$output/flutter-stage.XXXXXX"
/usr/bin/ditto "$built" "$bundle"
entitlements="$app_dir/macos/Runner/Release.entitlements"
if $integration; then
    contents="$bundle/Contents"
    plist="$contents/Info.plist"
    /usr/bin/plutil -replace CFBundleIdentifier -string dev.freev6.flutter-host "$plist"
    /usr/bin/plutil -replace CFBundleName -string "$product" "$plist"
    /usr/bin/plutil -replace CFBundleExecutable -string "$product" "$plist"
    mv "$contents/MacOS/$preview_name" "$contents/MacOS/$product"
    entitlements="$app_dir/macos/Runner/Integration.entitlements"
    helpers="$contents/Helpers"
    notices="$contents/Resources/Notices"
    mkdir -p "$helpers" "$notices"
    go_bin="${GO_BIN:-go}"
    if ! command -v "$go_bin" >/dev/null 2>&1; then
        echo "Install Go or set GO_BIN to its absolute executable path." >&2
        exit 1
    fi
    (
        cd "$project_root"
        export GOCACHE="${GOCACHE:-$project_root/build/macos-go-cache}"
        CGO_ENABLED=0 GOOS=darwin "$go_bin" build -trimpath -o "$helpers/freev6-worker" ./cmd/freev6-worker
    )
    bash "$project_root/scripts/macos/build-process-fixture.sh" >/dev/null
    cp "$project_root/build/macos-process/owned-child" "$helpers/freev6-session-fixture"
    for helper in freev6-worker freev6-session-fixture; do
        /usr/bin/codesign --force --sign - --options runtime \
            --identifier "dev.freev6.flutter-host.$helper" --entitlements "$app_dir/macos/Runner/Child.entitlements" "$helpers/$helper"
        /usr/bin/codesign --verify --strict "$helpers/$helper"
    done
    cp "$project_root/internal/mihomo/runtime-assets.json" "$contents/Resources"
    cp "$project_root/docs/agreement.md" "$notices/agreement.md"
    { cat "$project_root/macos/Resources/privacy-macos.md"; printf '\n\n'; cat "$project_root/docs/privacy.md"; } > "$notices/privacy.md"
    cp "$project_root/LICENSE" "$notices/FreeV6-LICENSE.txt"
    cp "$project_root/THIRD-PARTY.txt" "$notices/THIRD-PARTY.txt"
    go_root="$("$go_bin" env GOROOT)"
    cp "$go_root/LICENSE" "$notices/Go-LICENSE.txt"
    cp "$project_root/src-tauri/LICENSES/yaml.v3-LICENSE.txt" "$project_root/src-tauri/LICENSES/Apache-2.0.txt" "$notices/"
fi
# Flutter can refresh the signed App.framework on an incremental build after
# Xcode has sealed the runner. Seal the staged wrapper around the final assets.
/usr/bin/codesign --force --sign - --entitlements "$entitlements" "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
/usr/bin/codesign --display --entitlements - --xml "$bundle" 2>/dev/null | python3 -c '
import plistlib, sys
rights = plistlib.loads(sys.stdin.buffer.read())
expected = {"com.apple.security.app-sandbox": True}
if sys.argv[1] == "true":
    expected.update({"com.apple.security.files.user-selected.read-write": True,
                     "com.apple.security.network.client": True})
if rights != expected:
    sys.exit(f"Unexpected Flutter app entitlements: {rights}")
' "$integration"

publish_staged_app
printf '%s\n' "$output/$name"
