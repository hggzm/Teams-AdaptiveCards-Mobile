#!/bin/bash
# build_component.sh - Build and validate AdaptiveCardCustomElements package

COMPONENT_NAME="$1"

if [[ -z "$COMPONENT_NAME" ]]; then
    echo "❌ Usage: $0 <ComponentName>"
    exit 1
fi

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/source/ios/AdaptiveCards/AdaptiveCards/Packages/AdaptiveCardCustomElements"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Building Component: $COMPONENT_NAME${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

cd "$PACKAGE_DIR"

START_TIME=$(date +%s)

echo -e "${YELLOW}🔨 Building AdaptiveCardCustomElements package...${NC}"
echo ""

# Build the package
BUILD_OUTPUT=$(xcodebuild -scheme AdaptiveCardCustomElements \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build 2>&1)

BUILD_EXIT_CODE=$?
END_TIME=$(date +%s)
BUILD_DURATION=$((END_TIME - START_TIME))

echo ""

if [[ $BUILD_EXIT_CODE -eq 0 ]]; then
    echo -e "${GREEN}✅ Build succeeded!${NC}"
    echo -e "${GREEN}⏱️  Build time: ${BUILD_DURATION}s${NC}"
    echo ""
    
    # Check for warnings
    WARNING_COUNT=$(echo "$BUILD_OUTPUT" | grep -c "warning:" || true)
    if [[ $WARNING_COUNT -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  Build warnings: $WARNING_COUNT${NC}"
        echo "$BUILD_OUTPUT" | grep "warning:" | head -5
    fi
    
    exit 0
else
    echo -e "${RED}❌ Build failed!${NC}"
    echo -e "${RED}⏱️  Build time: ${BUILD_DURATION}s${NC}"
    echo ""
    
    # Extract and display errors
    echo -e "${RED}🔍 Compilation errors:${NC}"
    echo "$BUILD_OUTPUT" | grep "error:" | head -10
    echo ""
    
    # Save full output to temp file for debugging
    ERROR_LOG="/tmp/build_error_${COMPONENT_NAME}.log"
    echo "$BUILD_OUTPUT" > "$ERROR_LOG"
    echo -e "${YELLOW}📄 Full build output saved to: $ERROR_LOG${NC}"
    
    exit 1
fi
