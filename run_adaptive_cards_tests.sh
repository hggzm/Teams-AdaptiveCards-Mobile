#!/bin/bash

# AdaptiveCards Test Runner
# Usage: ./run_adaptive_cards_tests.sh [mode] [specific_test]
#   mode: sdk (unit tests), visualizer (UI tests), all (both)
#   specific_test: optional test name to run

set -e

MODE="${1:-sdk}"
SPECIFIC_TEST="${2:-}"

# Configuration
WORKSPACE="source/ios/AdaptiveCards/AdaptiveCards.xcworkspace"
SDK_SCHEME="AdaptiveCards"
VISUALIZER_SCHEME="ADCIOSVisualizer"
SIMULATOR="iPhone 16"
OS_VERSION="18.6"

echo "========================================"
echo "AdaptiveCards Test Runner"
echo "========================================"
echo "Mode: $MODE"
if [ -n "$SPECIFIC_TEST" ]; then
    echo "Specific Test: $SPECIFIC_TEST"
fi
echo "Simulator: $SIMULATOR"
echo "========================================"
echo ""

# Function to run SDK tests
run_sdk_tests() {
    echo "🧪 Running AdaptiveCards SDK Tests..."
    echo ""
    
    if [ -n "$SPECIFIC_TEST" ]; then
        xcodebuild test \
            -workspace "$WORKSPACE" \
            -scheme "$SDK_SCHEME" \
            -destination "platform=iOS Simulator,name=$SIMULATOR,OS=$OS_VERSION" \
            -only-testing:"AdaptiveCardsTests/$SPECIFIC_TEST" \
            2>&1
    else
        xcodebuild test \
            -workspace "$WORKSPACE" \
            -scheme "$SDK_SCHEME" \
            -destination "platform=iOS Simulator,name=$SIMULATOR,OS=$OS_VERSION" \
            -only-testing:AdaptiveCardsTests \
            2>&1
    fi
}

# Function to run Visualizer tests
run_visualizer_tests() {
    echo "🎨 Running AdaptiveCards Visualizer Tests..."
    echo ""
    
    if [ -n "$SPECIFIC_TEST" ]; then
        xcodebuild test \
            -workspace "$WORKSPACE" \
            -scheme "$VISUALIZER_SCHEME" \
            -destination "platform=iOS Simulator,name=$SIMULATOR,OS=$OS_VERSION" \
            -only-testing:"ADCIOSVisualizerUITests/$SPECIFIC_TEST" \
            2>&1
    else
        xcodebuild test \
            -workspace "$WORKSPACE" \
            -scheme "$VISUALIZER_SCHEME" \
            -destination "platform=iOS Simulator,name=$SIMULATOR,OS=$OS_VERSION" \
            2>&1
    fi
}

# Run tests based on mode
case "$MODE" in
    sdk)
        run_sdk_tests
        ;;
    visualizer)
        run_visualizer_tests
        ;;
    all)
        run_sdk_tests
        echo ""
        echo "========================================"
        echo ""
        run_visualizer_tests
        ;;
    *)
        echo "❌ Invalid mode: $MODE"
        echo "Valid modes: sdk, visualizer, all"
        exit 1
        ;;
esac

echo ""
echo "========================================"
echo "✅ Tests completed"
echo "========================================"
