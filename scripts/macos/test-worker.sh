#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
go_bin="${GO_BIN:-go}"
cd "$project_root"
mkdir -p build/macos-worker
"$go_bin" test -race ./internal/app ./internal/paths ./internal/worker
"$go_bin" test -race ./internal/mihomo -run 'Test(PinnedRuntime|PinnedGeodata|GeodataPackage|RealPinned|DownloadRuntime|RuntimePackage|RuntimeRejects|RuntimeZIP)'
"$go_bin" build -trimpath -o build/macos-worker/freev6-worker ./cmd/freev6-worker
FREEV6_WORKER_TEST_BINARY="$project_root/build/macos-worker/freev6-worker" \
    bash scripts/macos/swift.sh test
python3 scripts/macos/probe-worker.py --binary build/macos-worker/freev6-worker
