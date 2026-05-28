#!/usr/bin/env bash
# proxy-only — symbol-check smoke for the vendored swiftka kit on POSIX.
# Builds the example, runs it, asserts the canonical PASS line on stdout.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

echo "=== building adaptivecards-swiftka-demo ==="
swift build -c debug 2>&1 | tee build.log

echo
echo "=== running symbol-check ==="
out="$(swift run -c debug adaptivecards-swiftka-demo 2>&1)"
echo "$out"

if ! echo "$out" | grep -q "PASS adaptivecards-swiftka-roundtrip"; then
    echo "FAIL adaptivecards-swiftka-roundtrip (no PASS marker on stdout)" >&2
    exit 1
fi

echo
echo "PASS adaptivecards-swiftka-roundtrip"
