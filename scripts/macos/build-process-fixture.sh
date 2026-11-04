#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$project_root/build/macos-process"
/usr/bin/xcrun --sdk macosx clang -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$project_root/scripts/macos/fixtures/owned-child.c" -o "$project_root/build/macos-process/owned-child"
printf '%s\n' "$project_root/build/macos-process/owned-child"
