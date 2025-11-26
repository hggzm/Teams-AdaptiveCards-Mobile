#!/bin/bash
# Complete Swift Package sync script
# Can be run locally or in CI

set -e

echo "🚀 Starting Swift Package sync..."
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check we're on spm/main-tracking branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "spm/main-tracking" ]; then
    echo -e "${YELLOW}⚠️  Warning: Not on spm/main-tracking branch (currently on $CURRENT_BRANCH)${NC}"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# 1. Copy source files
echo -e "${BLUE}📦 Syncing Swift source files...${NC}"
rsync -av --delete \
  source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards/SwiftAdaptiveCards/ \
  source/ios/AdaptiveCards/SwiftAdaptiveCardsPackage/Sources/SwiftAdaptiveCards/ \
  --exclude='.DS_Store'
echo -e "${GREEN}✅ Source files synced${NC}"
echo ""

# 2. Copy test files
echo -e "${BLUE}🧪 Syncing Swift test files...${NC}"
rsync -av --delete \
  source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCardsTests/SwiftAdaptiveCardsTests/ \
  source/ios/AdaptiveCards/SwiftAdaptiveCardsPackage/Tests/SwiftAdaptiveCardsTests/ \
  --exclude='.DS_Store'
echo -e "${GREEN}✅ Test files synced${NC}"
echo ""

# 3. Update Xcode project
echo -e "${BLUE}🔧 Updating Xcode project...${NC}"
ruby remove_swift_files.rb || echo "Swift files may already be removed"
ruby remove_swift_test_files.rb || echo "Swift test files may already be removed"
echo -e "${GREEN}✅ Xcode project updated${NC}"
echo ""

# 4. Fix test imports
echo -e "${BLUE}🔄 Fixing test imports...${NC}"
find source/ios/AdaptiveCards/SwiftAdaptiveCardsPackage/Tests -name "*.swift" \
  -exec sed -i '' 's/^import AdaptiveCards$/import SwiftAdaptiveCards/g' {} \;
echo -e "${GREEN}✅ Test imports fixed${NC}"
echo ""

# 5. Build Swift Package
echo -e "${BLUE}🏗️  Building Swift Package...${NC}"
cd source/ios/AdaptiveCards/SwiftAdaptiveCardsPackage
swift build
SWIFT_BUILD_STATUS=$?
cd ../../../..
if [ $SWIFT_BUILD_STATUS -eq 0 ]; then
    echo -e "${GREEN}✅ Swift Package built successfully${NC}"
else
    echo -e "${YELLOW}❌ Swift Package build failed${NC}"
    exit 1
fi
echo ""

# 6. Run Swift Package tests
echo -e "${BLUE}🧪 Running Swift Package tests...${NC}"
cd source/ios/AdaptiveCards/SwiftAdaptiveCardsPackage
swift test 2>&1 | tee /tmp/swift_test_output.log
SWIFT_TEST_STATUS=$?
SWIFT_TEST_COUNT=$(grep "Executed.*tests" /tmp/swift_test_output.log | tail -1 | grep -o "[0-9]* tests" | grep -o "[0-9]*" || echo "0")
cd ../../../..
if [ $SWIFT_TEST_STATUS -eq 0 ]; then
    echo -e "${GREEN}✅ $SWIFT_TEST_COUNT Swift Package tests passed${NC}"
else
    echo -e "${YELLOW}❌ Swift Package tests failed${NC}"
    exit 1
fi
echo ""

# 7. Build SDK
echo -e "${BLUE}🏗️  Building SDK...${NC}"
cd source/ios/AdaptiveCards
xcodebuild -workspace AdaptiveCards.xcworkspace \
           -scheme AdaptiveCards \
           -sdk iphonesimulator \
           -quiet build
SDK_BUILD_STATUS=$?
cd ../../..
if [ $SDK_BUILD_STATUS -eq 0 ]; then
    echo -e "${GREEN}✅ SDK built successfully${NC}"
else
    echo -e "${YELLOW}❌ SDK build failed${NC}"
    exit 1
fi
echo ""

# 8. Run SDK tests
echo -e "${BLUE}🧪 Running SDK tests...${NC}"
cd source/ios/AdaptiveCards
xcodebuild test \
  -workspace AdaptiveCards.xcworkspace \
  -scheme AdaptiveCards \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tee /tmp/sdk_test_output.log
SDK_TEST_STATUS=$?
SDK_TEST_COUNT=$(grep "Executed.*tests" /tmp/sdk_test_output.log | tail -1 | grep -o "[0-9]* tests" | grep -o "[0-9]*" || echo "0")
cd ../../..
if [ $SDK_TEST_STATUS -eq 0 ]; then
    echo -e "${GREEN}✅ $SDK_TEST_COUNT SDK tests passed${NC}"
else
    echo -e "${YELLOW}❌ SDK tests failed${NC}"
    exit 1
fi
echo ""

# Summary
TOTAL_TESTS=$((SWIFT_TEST_COUNT + SDK_TEST_COUNT))
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Swift Package sync complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""
echo "📊 Test Results:"
echo "   - Swift Package: $SWIFT_TEST_COUNT tests passing"
echo "   - SDK: $SDK_TEST_COUNT tests passing"
echo "   - Total: $TOTAL_TESTS tests passing"
echo ""
echo "📝 Next steps:"
echo "   1. Review the changes: git status"
echo "   2. Commit the changes: git add . && git commit -m 'Sync Swift Package'"
echo "   3. Push to remote: git push origin spm/main-tracking"
echo ""
