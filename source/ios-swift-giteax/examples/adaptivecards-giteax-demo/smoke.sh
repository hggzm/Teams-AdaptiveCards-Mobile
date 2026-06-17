#!/usr/bin/env bash
# examples/adaptivecards-giteax-demo/smoke.sh
#
# POSIX equivalent of smoke.ps1 for macOS / Linux. zlib is on the
# default search path on both, so no -X flags needed.

set -euo pipefail

cd "$(dirname "$0")"

echo "=== swift build (demo) ==="
swift build -c debug

EXE=""
for candidate in \
    ".build/debug/AdaptiveCardsDemo" \
    ".build/x86_64-apple-macosx/debug/AdaptiveCardsDemo" \
    ".build/arm64-apple-macosx/debug/AdaptiveCardsDemo" \
    ".build/x86_64-unknown-linux-gnu/debug/AdaptiveCardsDemo" \
    ".build/aarch64-unknown-linux-gnu/debug/AdaptiveCardsDemo"; do
    if [ -x "$candidate" ]; then EXE="$candidate"; break; fi
done
if [ -z "$EXE" ]; then
    echo "FAIL adaptivecards-giteax-roundtrip: built exe not found under .build" >&2
    exit 3
fi

echo "=== run demo ==="
OUT="$("$EXE" 2>&1)"
RC=$?
echo "$OUT"
if [ $RC -ne 0 ]; then
    echo "FAIL adaptivecards-giteax-roundtrip: demo exit=$RC" >&2
    exit $RC
fi
if ! grep -q "PASS adaptivecards-giteax-roundtrip" <<<"$OUT"; then
    echo "FAIL adaptivecards-giteax-roundtrip: PASS marker not found in output" >&2
    exit 4
fi

echo
echo "PASS adaptivecards-giteax-roundtrip"
