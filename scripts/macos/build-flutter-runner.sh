#!/bin/bash
# Build the official Runner in its own project tree, using the same locked SDK and dependencies as P1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
destination="${1:?supply an empty destination FreeV6.app}"
work="$root/build/macos-release-runner"
project="$work/macos/flutter_ui"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PUB_CACHE="${PUB_CACHE:-$root/build/flutter-toolchain/pub-cache}"
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true CI=true FLUTTER_MACOS_ARM64_ONLY=true
sdk="$(bash "$root/scripts/macos/build-flutter-preview.sh" --prepare | tail -1)"
mkdir -p "$project"
# The local SwiftPM reference is two directories above the Xcode project.
# SwiftPM builds its own targets separately from the Runner's xcconfig. Specialize only its copy
# of FreeV6Host so fixture transports, scenario channels and QA factory never enter the release.
if [ -L "$work/macos/Package.swift" ]; then unlink "$work/macos/Package.swift"; fi
cp "$root/apps/macos/Package.swift" "$work/macos/Package.swift"
cat >> "$work/macos/Package.swift" <<'MANIFEST'
package.targets.first { $0.name == "FreeV6Host" }?.swiftSettings = [.define("FREEV6_RELEASE_HOST")]
MANIFEST
for member in Sources Tests; do
    if [ -e "$work/macos/$member" ] && [ ! -L "$work/macos/$member" ]; then
        echo "Expected a source symlink: $work/macos/$member" >&2; exit 1
    fi
    ln -sfn "$root/apps/macos/$member" "$work/macos/$member"
done
/usr/bin/rsync -a --delete --exclude '.dart_tool' --exclude 'build' --exclude '.DS_Store' \
    --exclude '/macos/Flutter/ephemeral' --exclude 'xcuserdata' "$root/apps/macos/flutter_ui/" "$project/"
# Use FreeV6's existing app icon for the shipping bundle rather than the Flutter template.
for size in 16 32 64 128 256 512 1024; do
    /usr/bin/sips -z "$size" "$size" "$root/assets/branding/icon.png" --out \
        "$project/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png" >/dev/null
done
cat >> "$project/macos/Runner/Configs/AppInfo.xcconfig" <<'CONFIG'
PRODUCT_NAME = FreeV6
PRODUCT_BUNDLE_IDENTIFIER = dev.freev6.desktop
SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) FREEV6_RELEASE_HOST
CONFIG
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$root/apps/macos/Resources/Info.plist")"
build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$root/apps/macos/Resources/Info.plist")"
cd "$project"
"$sdk/bin/flutter" pub get --enforce-lockfile
"$sdk/bin/flutter" build macos --release --no-pub --target lib/live_main.dart --build-name "$version" --build-number "$build"
built="$project/build/macos/Build/Products/Release/FreeV6.app"
/usr/bin/ditto "$built" "$destination"
python3 - "$destination/Contents/Info.plist" "$root/apps/macos/Resources/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
file = Path(sys.argv[1])
info = plistlib.loads(file.read_bytes())
assert info["CFBundleIdentifier"] == "dev.freev6.desktop" and info["NSMainNibFile"] == "MainMenu"
info.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
file.write_bytes(plistlib.dumps(info))
PY
for framework in "$destination"/Contents/Frameworks/*.framework; do
    signing_flags=(/usr/bin/codesign)
    if [ -n "${FREEV6_CODESIGN_KEYCHAIN:-}" ]; then signing_flags+=(--keychain "$FREEV6_CODESIGN_KEYCHAIN"); fi
    "${signing_flags[@]}" --force --sign "${FREEV6_CODESIGN_IDENTITY:--}" --options runtime "$framework"
done
