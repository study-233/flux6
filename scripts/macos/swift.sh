#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$project_root/scripts/macos/generate-resource-catalog.py" --check
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CLANG_MODULE_CACHE_PATH="$project_root/build/macos-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$project_root/build/swift-cache" \
    "$project_root/build/swift-config" "$project_root/build/swift-security"

action="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
exec /usr/bin/swift "$action" \
    --package-path "$project_root/macos" \
    --scratch-path "$project_root/build/macos" \
    --cache-path "$project_root/build/swift-cache" \
    --config-path "$project_root/build/swift-config" \
    --security-path "$project_root/build/swift-security" \
    --disable-sandbox "$@"
