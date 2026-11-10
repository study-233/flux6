#!/bin/bash
# Compile QA instrumentation into an independent temporary mirror of the product.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
target="$root/build/flutter-perf"
work="$target/macos"
project="$work/flutter_ui"
sdk="${FREEV6_FLUTTER_SDK:-$root/build/flutter-toolchain/flutter}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PUB_CACHE="${PUB_CACHE:-$root/build/flutter-toolchain/pub-cache}"
export XDG_CONFIG_HOME="$root/build/flutter-toolchain/config"
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true CI=true
if [ "$(uname -m)" = arm64 ]; then export FLUTTER_MACOS_ARM64_ONLY=true; fi
if [ "${1:-}" = build ]; then
    mkdir -p "$project"
    rsync -a "$root/macos/Package.swift" "$root/macos/Sources" "$root/macos/Tests" "$work/"
    rsync -a --exclude '.dart_tool' --exclude 'build' --exclude 'ephemeral' --exclude 'Pods' \
        --exclude 'xcuserdata' "$root/macos/flutter_ui/" "$project/"
    python3 - "$root" "$work" <<'PY'
import pathlib, sys
root, mirror = map(pathlib.Path, sys.argv[1:])
def replace(path, before, after):
    source = path.read_text()
    if source.count(before) != 1: raise SystemExit(f'Unexpected source shape in {path}')
    path.write_text(source.replace(before, after))
# Both offline configuration and real isolated session use the identical catalog.
replace(mirror/'Sources/FreeV6Host/IsolatedHostSession.swift', 'static let nodes = ["东区", "西区", "北区"]',
        'static let nodes = ProcessInfo.processInfo.environment["FREEV6_PERF_NODES"] == "28" ? DesktopNodeGroup.warpNames : ["东区", "西区", "北区"]')
channel = mirror/'flutter_ui/macos/Runner/HostWindowChannel.swift'
replace(channel, '            case "windowRole":', '            case "perfInfo", "perfPause", "perfResume", "perfStart", "perfEnd", "perfMove", "perfManualStart", "perfManualEnd", "perfPointerStart", "perfPointerReport":\n                guard HostApplication.isQA else { reply(FlutterMethodNotImplemented); return }\n                reply(PerfDisplay.shared.handle(call.method, args, window))\n            case "windowRole":')
channel.write_text(channel.read_text() + (root/'macos/Probes/FlutterPerfHost.swift').read_text())
replace(mirror/'flutter_ui/macos/Runner/MainFlutterWindow.swift', '            window.performDrag(with: event)',
        '            PerfDisplay.shared.noteDrag()\n            window.performDrag(with: event)')
PY
    cd "$project"
    mkdir -p .dart_tool/freev6-probes
    cp "$root/macos/Probes/FlutterPerf.dart" .dart_tool/freev6-probes/perf.dart
    "$sdk/bin/flutter" pub get --offline --enforce-lockfile
    "$sdk/bin/flutter" build macos --release --no-pub --target .dart_tool/freev6-probes/perf.dart
    qa="$(bash "$root/scripts/macos/build-flutter-host.sh" --qa-clone)"
    built="$project/build/macos/Build/Products/Release/FreeV6 Flutter Preview.app"
    mv "$qa/Contents/Frameworks/App.framework" "$(dirname "$qa")/consumer-framework"
    ditto "$built/Contents/Frameworks/App.framework" "$qa/Contents/Frameworks/App.framework"
    cp "$built/Contents/MacOS/FreeV6 Flutter Preview" "$qa/Contents/MacOS/FreeV6 Flutter Integration"
    codesign --force --sign - --entitlements "$project/macos/Runner/Integration.entitlements" "$qa"
    codesign --verify --deep --strict "$qa"
    printf '%s\n' "$qa" > "$target/bundle.txt"
    printf 'Benchmark bundle: %s\n' "$qa"
else
    exec python3 "$root/scripts/macos/probe-flutter-perf.py" "$@"
fi
