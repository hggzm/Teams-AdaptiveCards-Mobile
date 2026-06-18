#!/usr/bin/env bash
# examples/adaptivecards-jenkins-demo/smoke.sh
#
# POSIX runner for the symbol-check demo (macOS / Linux). Builds and runs
# the demo and asserts the PASS marker. No zlib flags needed off-Windows.

set -euo pipefail
cd "$(dirname "$0")"

echo "=== swift build (demo) ==="
swift build -c debug

echo
echo "=== run demo ==="
output="$(swift run -c debug AdaptiveCardsDemo 2>&1)"
echo "$output"

if ! grep -q 'PASS adaptivecards-jenkins-roundtrip' <<<"$output"; then
    echo "FAIL adaptivecards-jenkins-roundtrip: PASS marker not found" >&2
    exit 1
fi

echo "smoke OK"
