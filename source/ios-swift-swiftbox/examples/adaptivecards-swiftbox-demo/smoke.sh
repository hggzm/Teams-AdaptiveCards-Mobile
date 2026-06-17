#!/usr/bin/env bash
# examples/adaptivecards-swiftbox-demo/smoke.sh
#
# Build and run the symbol-check demo on POSIX, then assert the PASS marker.
# swiftbox is pure Foundation — no vcpkg / zlib needed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
marker='PASS adaptivecards-swiftbox-roundtrip'

echo "=== swift build (demo) ==="
swift build -c debug

echo "=== run demo ==="
out="$(swift run -c debug AdaptiveCardsDemo 2>&1)"
echo "$out"

if ! grep -q "$marker" <<<"$out"; then
    echo "FAIL adaptivecards-swiftbox-roundtrip: PASS marker not found in output" >&2
    exit 4
fi

echo ""
echo "$marker"
