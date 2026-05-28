#!/usr/bin/env bash
# adaptivecards-swiftag-demo runtime symbol-check (POSIX).
# Builds and runs the demo, asserts both required PASS lines are
# present, exits non-zero on any failure.
set -euo pipefail

cd "$(dirname "$0")"

echo "=== swift build -c debug ==="
swift build -c debug

echo "=== swift run adaptivecards-swiftag-demo ==="
out=$(swift run adaptivecards-swiftag-demo 2>&1)
echo "$out"

for line in \
    "PASS adaptivecards-swiftag-roundtrip" \
    "PASS adaptivecards-swiftag-tool"; do
    if ! grep -qF "$line" <<<"$out"; then
        echo "missing required line: '$line'" >&2
        exit 1
    fi
done

echo "=== adaptivecards-swiftag-demo: SMOKE PASS ==="
