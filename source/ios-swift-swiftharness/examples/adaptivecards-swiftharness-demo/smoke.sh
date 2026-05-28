#!/usr/bin/env sh
# Runtime symbol-check smoke for the vendored swiftharness bridge.
# Builds the demo SwiftPM package, runs it, and verifies that the
# canonical PASS line was written to stdout.

set -eu

cd "$(dirname "$0")"

echo "=== adaptivecards-swiftharness-demo smoke ==="

echo "--- swift build -c debug ---"
swift build -c debug

echo "--- swift run AdaptiveCardsDemo ---"
output="$(swift run AdaptiveCardsDemo 2>&1)"
echo "$output"

needle="PASS adaptivecards-swiftharness-roundtrip"
if ! printf '%s' "$output" | grep -qF "$needle"; then
    echo "FAIL: '$needle' not found on stdout" >&2
    exit 2
fi

echo "=== smoke green ==="
