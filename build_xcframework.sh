#!/bin/bash

################################################################################
# AdaptiveCards iOS XCFramework Build Script
# 
# This script builds a universal XCFramework for AdaptiveCards iOS SDK
# supporting both iOS devices (arm64) and simulators (arm64, x86_64)
#
# Version: 2.11.3
# Author: Hugo Gonzalez
# Date: December 15, 2024
################################################################################

set -e  # Exit on error
set -u  # Exit on undefined variable

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
XCODE_WORKSPACE="${PROJECT_ROOT}/source/ios/AdaptiveCards/AdaptiveCards.xcworkspace"
XCODE_PROJECT="${PROJECT_ROOT}/source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards.xcodeproj"
SCHEME_NAME="AdaptiveCards"
BUILD_DIR="${PROJECT_ROOT}/build/xcframework"
ARCHIVE_DIR="${BUILD_DIR}/archives"
XCFRAMEWORK_NAME="AdaptiveCards.xcframework"
VERSION="2.11.3"
USE_WORKSPACE=true  # Set to false to build from project only

# Derived data directory (use temp to avoid conflicts)
DERIVED_DATA="${BUILD_DIR}/DerivedData"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}   AdaptiveCards iOS XCFramework Builder${NC}"
echo -e "${BLUE}   Version: ${VERSION}${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Function to print status messages
print_status() {
    echo -e "${GREEN}▶${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Validate prerequisites
validate_environment() {
    print_status "Validating environment..."
    
    # Check Xcode installation
    if ! command -v xcodebuild &> /dev/null; then
        print_error "xcodebuild not found. Please install Xcode."
        exit 1
    fi
    
    # Check if workspace/project exists
    if [ "$USE_WORKSPACE" = true ] && [ ! -d "$XCODE_WORKSPACE" ]; then
        print_error "Xcode workspace not found at: $XCODE_WORKSPACE"
        exit 1
    elif [ "$USE_WORKSPACE" = false ] && [ ! -d "$XCODE_PROJECT" ]; then
        print_error "Xcode project not found at: $XCODE_PROJECT"
        print_warning "Expected project structure:"
        print_warning "  source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards.xcodeproj"
        exit 1
    fi
    
    # Print Xcode version
    XCODE_VERSION=$(xcodebuild -version | head -n 1)
    print_success "Using: $XCODE_VERSION"
    
    # Check available schemes
    print_status "Available schemes:"
    if [ "$USE_WORKSPACE" = true ]; then
        xcodebuild -workspace "$XCODE_WORKSPACE" -list 2>/dev/null | grep -A 100 "Schemes:" | grep -v "Schemes:" | grep -v "^$" | head -5 || true
    else
        xcodebuild -project "$XCODE_PROJECT" -list 2>/dev/null | grep -A 100 "Schemes:" | grep -v "Schemes:" | grep -v "^$" | head -5 || true
    fi
    echo ""
}

# Clean previous builds
clean_build_artifacts() {
    print_status "Cleaning previous build artifacts..."
    
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        print_success "Removed old build directory"
    fi
    
    # Create fresh directories
    mkdir -p "$ARCHIVE_DIR"
    mkdir -p "$DERIVED_DATA"
    
    print_success "Build directories ready"
}

# Build framework for specific platform
build_archive() {
    local SDK=$1
    local DESTINATION=$2
    local ARCHIVE_PATH=$3
    local PLATFORM_NAME=$4
    
    print_status "Building for $PLATFORM_NAME ($SDK)..."
    
    local BUILD_CMD_BASE="-scheme $SCHEME_NAME -sdk $SDK -destination $DESTINATION -archivePath $ARCHIVE_PATH -derivedDataPath $DERIVED_DATA"
    local BUILD_SETTINGS="SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"
    
    if [ "$USE_WORKSPACE" = true ]; then
        xcodebuild archive \
            -workspace "$XCODE_WORKSPACE" \
            $BUILD_CMD_BASE \
            $BUILD_SETTINGS
    else
        xcodebuild archive \
            -project "$XCODE_PROJECT" \
            $BUILD_CMD_BASE \
            $BUILD_SETTINGS
    fi
    
    if [ $? -eq 0 ]; then
        print_success "Successfully built for $PLATFORM_NAME"
    else
        print_error "Failed to build for $PLATFORM_NAME"
        exit 1
    fi
}

# Create XCFramework
create_xcframework() {
    print_status "Creating XCFramework..."
    
    local IOS_ARCHIVE="${ARCHIVE_DIR}/AdaptiveCards-iOS.xcarchive"
    local SIM_ARCHIVE="${ARCHIVE_DIR}/AdaptiveCards-Simulator.xcarchive"
    local XCFRAMEWORK_PATH="${BUILD_DIR}/${XCFRAMEWORK_NAME}"
    
    # Find the framework paths in archives
    local IOS_FRAMEWORK="${IOS_ARCHIVE}/Products/Library/Frameworks/AdaptiveCards.framework"
    local SIM_FRAMEWORK="${SIM_ARCHIVE}/Products/Library/Frameworks/AdaptiveCards.framework"
    
    # Verify frameworks exist
    if [ ! -d "$IOS_FRAMEWORK" ]; then
        print_error "iOS framework not found at: $IOS_FRAMEWORK"
        print_warning "Searching for framework in archive..."
        find "$IOS_ARCHIVE" -name "*.framework" -type d | head -3
        exit 1
    fi
    
    if [ ! -d "$SIM_FRAMEWORK" ]; then
        print_error "Simulator framework not found at: $SIM_FRAMEWORK"
        print_warning "Searching for framework in archive..."
        find "$SIM_ARCHIVE" -name "*.framework" -type d | head -3
        exit 1
    fi
    
    # Create XCFramework
    xcodebuild -create-xcframework \
        -framework "$IOS_FRAMEWORK" \
        -framework "$SIM_FRAMEWORK" \
        -output "$XCFRAMEWORK_PATH"
    
    if [ $? -eq 0 ]; then
        print_success "XCFramework created successfully"
        print_success "Location: $XCFRAMEWORK_PATH"
    else
        print_error "Failed to create XCFramework"
        exit 1
    fi
}

# Package for distribution
package_xcframework() {
    print_status "Packaging XCFramework for distribution..."
    
    local XCFRAMEWORK_PATH="${BUILD_DIR}/${XCFRAMEWORK_NAME}"
    local DIST_DIR="${BUILD_DIR}/distribution"
    local ZIP_NAME="AdaptiveCards-${VERSION}.xcframework.zip"
    
    mkdir -p "$DIST_DIR"
    
    # Copy XCFramework
    cp -R "$XCFRAMEWORK_PATH" "$DIST_DIR/"
    
    # Create README
    cat > "$DIST_DIR/README.md" << EOF
# AdaptiveCards iOS SDK v${VERSION}

## XCFramework Distribution

This package contains the AdaptiveCards iOS SDK as an XCFramework.

### Contents
- \`${XCFRAMEWORK_NAME}\` - Universal framework for iOS devices and simulators

### System Requirements
- iOS 14.0 or later
- Xcode 12.0 or later
- Swift 5.0 or later

### Installation

#### Manual Integration

1. Drag \`${XCFRAMEWORK_NAME}\` into your Xcode project
2. In your target's "Frameworks, Libraries, and Embedded Content":
   - Add \`${XCFRAMEWORK_NAME}\`
   - Set to "Embed & Sign"

#### Dependencies

This XCFramework requires the following dependencies:

**Required:**
- SVGKit (>= 3.0.0) - For SVG image support
- CocoaLumberjack (~> 3.7.0) - Required by SVGKit

**Optional:**
- MicrosoftFluentUI/Tooltip_ios (~> 0.3.6) - For enhanced tooltips

You can install these via CocoaPods, SPM, or as XCFrameworks.

### Usage

\`\`\`swift
import AdaptiveCards

// Parse and render an Adaptive Card
let cardJSON = """
{
    "type": "AdaptiveCard",
    "version": "1.5",
    "body": [
        {
            "type": "TextBlock",
            "text": "Hello, Adaptive Cards!"
        }
    ]
}
"""

// Use the SDK to parse and render the card
// (See full documentation for detailed usage)
\`\`\`

### Documentation
- [Adaptive Cards Documentation](https://adaptivecards.io)
- [iOS SDK Documentation](https://docs.microsoft.com/en-us/adaptive-cards/sdk/rendering-cards/ios)
- [GitHub Repository](https://github.com/microsoft/AdaptiveCards-Mobile)

### License
See EULA-Non-Windows.txt in the source repository

### Version
${VERSION} - Built on $(date +"%Y-%m-%d")
EOF
    
    # Create ZIP
    cd "$DIST_DIR"
    zip -r "../$ZIP_NAME" . -x "*.DS_Store"
    cd "$PROJECT_ROOT"
    
    print_success "Distribution package created: ${BUILD_DIR}/${ZIP_NAME}"
}

# Print build summary
print_summary() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Build Complete!${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "📦 ${YELLOW}XCFramework Location:${NC}"
    echo -e "   ${BUILD_DIR}/${XCFRAMEWORK_NAME}"
    echo ""
    echo -e "📦 ${YELLOW}Distribution Package:${NC}"
    echo -e "   ${BUILD_DIR}/AdaptiveCards-${VERSION}.xcframework.zip"
    echo ""
    echo -e "📄 ${YELLOW}Size:${NC}"
    du -sh "${BUILD_DIR}/${XCFRAMEWORK_NAME}" 2>/dev/null || echo "   (size unavailable)"
    echo ""
    echo -e "🎯 ${YELLOW}Supported Platforms:${NC}"
    echo -e "   • iOS Device (arm64)"
    echo -e "   • iOS Simulator (arm64, x86_64)"
    echo ""
    echo -e "📋 ${YELLOW}Next Steps:${NC}"
    echo -e "   1. Test integration in demo app"
    echo -e "   2. Verify on physical device and simulator"
    echo -e "   3. Share distribution package with team"
    echo ""
}

# Main execution
main() {
    validate_environment
    clean_build_artifacts
    
    # Build for iOS Device
    build_archive \
        "iphoneos" \
        "generic/platform=iOS" \
        "${ARCHIVE_DIR}/AdaptiveCards-iOS.xcarchive" \
        "iOS Device"
    
    # Build for iOS Simulator
    build_archive \
        "iphonesimulator" \
        "generic/platform=iOS Simulator" \
        "${ARCHIVE_DIR}/AdaptiveCards-Simulator.xcarchive" \
        "iOS Simulator"
    
    create_xcframework
    package_xcframework
    print_summary
}

# Run main function
main "$@"
