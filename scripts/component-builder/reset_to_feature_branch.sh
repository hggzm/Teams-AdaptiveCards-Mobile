#!/bin/bash

# Reset to Feature Branch - Cleanup Helper Script
# Purpose: Clean up test artifacts and return to clean feature/dynamic_swiftui_builder state
# Usage: ./reset_to_feature_branch.sh

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FEATURE_BRANCH="feature/dynamic_swiftui_builder"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   🧹 Cleanup: Resetting to Feature Branch"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$REPO_ROOT"

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Error: Not in a git repository"
    exit 1
fi

# Get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "📍 Current branch: $CURRENT_BRANCH"

# Check if feature branch exists
if ! git rev-parse --verify "$FEATURE_BRANCH" > /dev/null 2>&1; then
    echo "❌ Error: Feature branch '$FEATURE_BRANCH' does not exist"
    exit 1
fi

echo ""
echo "🔍 Checking workspace status..."
git status --short

echo ""
echo "🧹 Cleaning up workspace..."

# 1. Restore all modified files (test JSON that was injected)
echo "  → Restoring modified files..."
git restore samples/v1.3/Tests/MagicFileInjectionTest.json 2>/dev/null || true

# 2. Remove specific test artifacts (not all untracked files!)
echo "  → Removing test artifacts..."
rm -rf screenshots/ 2>/dev/null || true
rm -f samples/rating-test.json 2>/dev/null || true
rm -f samples/*-test.json 2>/dev/null || true
rm -rf docs/agentic-workflows/ 2>/dev/null || true
rm -f AGENTIC_WORKFLOWS_PRESENTATION.md 2>/dev/null || true
rm -f source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards/SwiftAdaptiveCards/SwiftViews/Citation/README.md 2>/dev/null || true

# 3. Switch to feature branch if on different branch
if [ "$CURRENT_BRANCH" != "$FEATURE_BRANCH" ]; then
    echo "  → Switching to $FEATURE_BRANCH..."
    git checkout "$FEATURE_BRANCH"
else
    echo "  → Already on $FEATURE_BRANCH"
fi

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "📊 Final workspace status:"
git status --short

# Verify clean state
if [ -z "$(git status --porcelain)" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   ✨ Workspace is clean - ready for component builds"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo ""
    echo "⚠️  Warning: Workspace still has uncommitted changes"
    echo "   This may indicate files that are tracked but modified."
    echo "   Please review manually."
fi
