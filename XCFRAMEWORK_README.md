# AdaptiveCards iOS XCFramework Distribution

**Status**: ✅ Ready to Build  
**Version**: 2.11.3  
**Created**: December 15, 2024

## Overview

This directory contains everything needed to build and integrate the AdaptiveCards iOS SDK as an XCFramework, eliminating CocoaPods dependency resolution issues.

## 📚 Documentation

1. **[QUICK_START_INTEGRATION.md](QUICK_START_INTEGRATION.md)** - Start here!
   - Simple step-by-step integration guide
   - Complete Podfile examples
   - Troubleshooting common issues
   - Code examples

2. **[ADAPTIVECARDS_XCFRAMEWORK_GUIDE.md](ADAPTIVECARDS_XCFRAMEWORK_GUIDE.md)** - Technical details
   - Implementation notes
   - Build strategy
   - SDK architecture
   - Advanced configuration

## 🚀 Quick Build

```bash
# Ensure CocoaPods dependencies are installed first
cd source/ios/AdaptiveCards
pod install
cd ../../..

# Build the XCFramework
./build_xcframework.sh

# Find output at:
# build/xcframework/AdaptiveCards.xcframework
# build/AdaptiveCards-2.11.3.xcframework.zip
```

**Build time**: ~5-10 minutes

## 📦 What Gets Built

- **iOS Device** (arm64) - For physical iPhones/iPads
- **iOS Simulator** (arm64, x86_64) - For Xcode simulators on Intel and Apple Silicon Macs
- **Universal XCFramework** - Single bundle supporting all platforms

## 🎯 For Riddhi

This solves the issues you encountered:

❌ **Old Problems**:
- FluentUI module map errors ← **Biggest issue**
- CocoaLumberjack not found
- Complex CocoaPods subspecs
- Dependency resolution failures

✅ **New Solution**:
- Single XCFramework file
- **FluentUI compiled in** - no module issues! 🎉
- Minimal dependencies (just SVGKit + CocoaLumberjack)
- Enhanced tooltips work automatically
- Clear integration steps
- Works with any dependency manager

## 📋 Prerequisites

- macOS with Xcode 12.0 or later
- iOS deployment target: 14.0+
- CocoaPods installed (for building)
- ~10 minutes for initial build

## 🔧 Build Script Features

The `build_xcframework.sh` script:
- ✅ Validates environment
- ✅ Cleans previous builds
- ✅ Builds for device and simulator
- ✅ Creates universal XCFramework
- ✅ Packages for distribution
- ✅ Includes documentation
- ✅ Color-coded status output

## 📞 Support

**Primary Contact**: Hugo Gonzalez  
**For**: Integration questions, build issues, SDK usage

## 🎯 Next Steps

1. **To build**: Run `./build_xcframework.sh`
2. **To integrate**: Follow [QUICK_START_INTEGRATION.md](QUICK_START_INTEGRATION.md)
3. **For details**: See [ADAPTIVECARDS_XCFRAMEWORK_GUIDE.md](ADAPTIVECARDS_XCFRAMEWORK_GUIDE.md)

## ⚡ Quick Integration (After Building)

```ruby
# Podfile
platform :ios, '14.0'
use_frameworks!

target 'YourApp' do
  pod 'SVGKit', '>= 3.0.0'
  pod 'CocoaLumberjack', '~> 3.7.0'
end
```

Then:
1. Drag `AdaptiveCards.xcframework` into Xcode
2. Set to "Embed & Sign"
3. `import AdaptiveCards`
4. Build and run! 🎉

---

**Version**: 2.11.3 | **Last Updated**: December 15, 2024
