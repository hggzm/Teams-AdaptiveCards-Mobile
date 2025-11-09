#!/bin/bash

# Run ADCIOSVisualizer app with optional card injection
# Usage: ./run_visualizer_app.sh [path_to_card.json]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
WORKSPACE="${REPO_ROOT}/source/ios/AdaptiveCards/AdaptiveCards.xcworkspace"
VISUALIZER_PROJECT="${REPO_ROOT}/source/ios/AdaptiveCards/ADCIOSVisualizer/ADCIOSVisualizer.xcodeproj"
SCHEME="ADCIOSVisualizer"
DEVICE="iPhone 16"
IOS_VERSION="latest"
MAGIC_FILE="${REPO_ROOT}/samples/InjectedCard.json"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${CYAN}  📱 ADCIOSVisualizer App Runner${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Function to get simulator ID
get_simulator_id() {
    local sim_id=$(xcrun simctl list devices available | \
        grep "iPhone 16 (" | \
        grep -v "Pro" | \
        grep -v "Plus" | \
        head -1 | \
        grep -oE '\([A-F0-9\-]+\)' | \
        tr -d '()')
    echo "$sim_id"
}

# Function to boot simulator
boot_simulator() {
    local sim_id=$1
    echo -e "${BLUE}🚀 Booting simulator: ${sim_id}${NC}"
    
    # Boot if not already booted
    if ! xcrun simctl list devices | grep "$sim_id" | grep -q "Booted"; then
        xcrun simctl boot "$sim_id" 2>/dev/null || true
        echo -e "${MAGENTA}⏳ Waiting for simulator to boot...${NC}"
        xcrun simctl bootstatus "$sim_id" -b
    else
        echo -e "${GREEN}✓${NC} Simulator already booted"
    fi
}

# Function to handle card injection
handle_card_injection() {
    local card_path=$1
    
    if [ -n "$card_path" ]; then
        if [ ! -f "$card_path" ]; then
            echo -e "${RED}❌ Card file not found: ${card_path}${NC}"
            exit 1
        fi
        
        echo -e "${CYAN}🔮 Injecting card: $(basename $card_path)${NC}"
        cp "$card_path" "$MAGIC_FILE"
        echo -e "${GREEN}✓${NC} Card injected into magic file"
        return 0
    else
        # Clear magic file
        echo "{}" > "$MAGIC_FILE"
        echo -e "${YELLOW}ℹ${NC}  Magic file cleared - app will show normal card list"
        return 1
    fi
}

# Function to install pods if needed
install_pods_if_needed() {
    local pods_dir="${REPO_ROOT}/source/ios/AdaptiveCards/Pods"
    
    if [ ! -d "$pods_dir" ]; then
        echo -e "${BLUE}📦 Installing CocoaPods dependencies...${NC}"
        cd "${REPO_ROOT}/source/ios/AdaptiveCards"
        pod install
        cd "$REPO_ROOT"
        echo -e "${GREEN}✓${NC} Pods installed"
    else
        echo -e "${GREEN}✓${NC} CocoaPods already installed"
    fi
}

# Main execution
echo -e "${BLUE}Configuration:${NC}"
echo "  Device:     $DEVICE"
echo "  Scheme:     $SCHEME"
echo "  Workspace:  $(basename $WORKSPACE)"
echo ""

# Handle card injection
INJECTED=false
if [ -n "$1" ]; then
    if handle_card_injection "$1"; then
        INJECTED=true
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  🎯 Running in INJECTION MODE${NC}"
        echo -e "${GREEN}  Card: $(basename $1)${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi
else
    handle_card_injection ""
fi

# Get simulator
SIM_ID=$(get_simulator_id)
if [ -z "$SIM_ID" ]; then
    echo -e "${RED}❌ Could not find iPhone 16 simulator${NC}"
    exit 1
fi

echo -e "${CYAN}Simulator ID: ${SIM_ID}${NC}"
echo ""

# Boot simulator
boot_simulator "$SIM_ID"
echo ""

# Install pods if needed
install_pods_if_needed
echo ""

# Set destination
DESTINATION="platform=iOS Simulator,id=${SIM_ID}"

echo -e "${BLUE}🔨 Building and installing app...${NC}"
echo ""

# Build and install
xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -configuration Debug \
    -derivedDataPath "${REPO_ROOT}/build" \
    | grep -E "(Build|Compiling|Linking|Installing|succeeded|failed|error:|warning:)" || true

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}❌ Build failed${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓${NC} Build succeeded"
echo ""

# Find the app bundle
APP_BUNDLE=$(find "${REPO_ROOT}/build/Build/Products/Debug-iphonesimulator" -name "ADCIOSVisualizer.app" -type d | head -1)

if [ -z "$APP_BUNDLE" ]; then
    echo -e "${RED}❌ Could not find app bundle${NC}"
    exit 1
fi

echo -e "${BLUE}📦 Installing app on simulator...${NC}"
xcrun simctl install "$SIM_ID" "$APP_BUNDLE"
echo -e "${GREEN}✓${NC} App installed"
echo ""

# Get bundle identifier
BUNDLE_ID=$(defaults read "${APP_BUNDLE}/Info.plist" CFBundleIdentifier)

echo -e "${BLUE}🚀 Launching app...${NC}"
xcrun simctl launch --console "$SIM_ID" "$BUNDLE_ID"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ App launched successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "$INJECTED" = true ]; then
    echo ""
    echo -e "${MAGENTA}💡 The app should display your injected card immediately${NC}"
else
    echo ""
    echo -e "${MAGENTA}💡 The app should display the normal card browser${NC}"
fi

echo ""
echo -e "${CYAN}Simulator: ${SIM_ID}${NC}"
echo -e "${CYAN}Bundle ID:  ${BUNDLE_ID}${NC}"
echo ""

# Keep magic file state
if [ "$INJECTED" = true ]; then
    echo -e "${YELLOW}Note: Magic file is still populated. Run './scripts/test-utils/inject_adaptive_card.sh --clear' to reset.${NC}"
fi
