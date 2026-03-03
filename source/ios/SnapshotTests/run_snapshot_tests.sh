#!/bin/bash
#
# iOS Snapshot Test Runner
# Usage:
#   ./run_snapshot_tests.sh record   — Record new baselines
#   ./run_snapshot_tests.sh verify   — Verify against baselines (default)
#   ./run_snapshot_tests.sh clean    — Delete failure/diff artifacts
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

MODE="${1:-verify}"

case "$MODE" in
  record)
    echo "📸 Recording iOS snapshot baselines..."
    export RECORD_SNAPSHOTS=1
    ;;
  verify)
    echo "🔍 Verifying iOS snapshots against baselines..."
    unset RECORD_SNAPSHOTS
    ;;
  clean)
    echo "🧹 Cleaning snapshot artifacts..."
    rm -rf "$SCRIPT_DIR/Snapshots/Failures"
    rm -rf "$SCRIPT_DIR/Snapshots/Diffs"
    mkdir -p "$SCRIPT_DIR/Snapshots/Failures"
    mkdir -p "$SCRIPT_DIR/Snapshots/Diffs"
    echo "Done."
    exit 0
    ;;
  *)
    echo "Usage: $0 {record|verify|clean}"
    exit 1
    ;;
esac

# Find a simulator
SIMULATOR=$(xcrun simctl list devices available --json 2>/dev/null | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
for runtime, devs in devices.items():
    if 'iOS' in runtime:
        for d in devs:
            if 'iPhone' in d['name'] and d['state'] == 'Booted':
                print(d['udid']); sys.exit(0)
for runtime, devs in devices.items():
    if 'iOS' in runtime:
        for d in devs:
            if 'iPhone 15' in d['name']:
                print(d['udid']); sys.exit(0)
for runtime, devs in devices.items():
    if 'iOS' in runtime:
        for d in devs:
            if 'iPhone' in d['name']:
                print(d['udid']); sys.exit(0)
" 2>/dev/null)

if [ -z "$SIMULATOR" ]; then
  echo "❌ No iOS simulator found. Create one with: xcrun simctl create 'iPhone 15 Pro' ..."
  exit 1
fi

echo "Using simulator: $SIMULATOR"
xcrun simctl boot "$SIMULATOR" 2>/dev/null || true

cd "$REPO_ROOT"

xcodebuild test \
  -scheme "AdaptiveCards-Package" \
  -destination "platform=iOS Simulator,id=$SIMULATOR" \
  -only-testing:VisualSnapshotTests \
  2>&1 | grep -E "Test Case|passed|failed|Test Suite|SNAPSHOT" || true

echo ""
echo "Results:"
BASELINES=$(find "$SCRIPT_DIR/Snapshots/Baselines" -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
FAILURES=$(find "$SCRIPT_DIR/Snapshots/Failures" -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
DIFFS=$(find "$SCRIPT_DIR/Snapshots/Diffs" -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
echo "  Baselines: $BASELINES"
echo "  Failures:  $FAILURES"
echo "  Diffs:     $DIFFS"
