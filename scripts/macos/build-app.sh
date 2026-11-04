#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
configuration="${CONFIGURATION:-debug}"
bash "$project_root/scripts/macos/swift.sh" build -c "$configuration"
binary_dir="$(bash "$project_root/scripts/macos/swift.sh" build -c "$configuration" --show-bin-path)"
app="$project_root/dist/macos/FreeV6.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/FreeV6" "$app/Contents/MacOS/FreeV6"
cp "$project_root/macos/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier dev.freev6.desktop "$app"
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"
