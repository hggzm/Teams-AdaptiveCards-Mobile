#!/bin/bash

# Commit and Push Script
# Purpose: Commit changes and push to remote repository
# Usage: ./commit_and_push.sh "commit message"

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

# Check if commit message provided
if [ -z "$1" ]; then
    echo "❌ Error: Commit message required"
    echo "Usage: $0 \"commit message\""
    exit 1
fi

COMMIT_MESSAGE="$1"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   📝 Committing and Pushing Changes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "📍 Current branch: $CURRENT_BRANCH"
echo ""

# Show status
echo "📊 Changes to commit:"
git status --short
echo ""

# Stage all changes
echo "➕ Staging all changes..."
git add -A

# Commit
echo "💾 Committing with message: \"$COMMIT_MESSAGE\""
git commit -m "$COMMIT_MESSAGE"

# Push
echo "🚀 Pushing to remote..."
git push origin "$CURRENT_BRANCH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   ✅ Successfully pushed to origin/$CURRENT_BRANCH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
