#!/usr/bin/env bash
# smoke.sh — POSIX runtime symbol-check.
#
# Builds the adaptivecards-swiftpi-demo executable against the vendored
# swiftpi kit, runs it, and asserts the success line. Exit non-zero on
# any failure.

set -euo pipefail
cd "$(dirname "$0")"

echo "=== swift build -c debug ==="
swift build -c debug

echo
echo "=== swift run AdaptiveCardsDemo ==="
output="$(swift run -c debug AdaptiveCardsDemo 2>&1)"
echo "$output"

if ! grep -q 'PASS adaptivecards-swiftpi-agentloop' <<<"$output"; then
    echo "FAIL adaptivecards-swiftpi-assertion (PASS line not found)" >&2
    exit 1
fi

echo "smoke OK"
