#!/usr/bin/env bash
# Runtime symbol-check smoke for the vendored SwiftSyncCore kit (flavor A —
# store / round-trip). Builds the demo, runs it, and gates on the PASS line.
# Exits non-zero on any failure.
#
# SwiftSyncCore is pure Foundation, so there are no zlib flags here.

set -euo pipefail

PASS='PASS adaptivecards-swiftsync-roundtrip'

cd "$(dirname "$0")"

echo "== build demo =="
swift build -c debug

echo "== run demo =="
output="$(swift run -c debug AdaptiveCardsDemo 2>&1)"
echo "$output"

if echo "$output" | grep -qF "$PASS"; then
    echo "smoke OK: '$PASS' observed"
    exit 0
fi

echo "FAIL: '$PASS' not found in demo output" >&2
exit 1
