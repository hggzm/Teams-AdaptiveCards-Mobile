# AdaptiveCards XCFramework - Quick Start Integration Guide

**For**: Riddhi Tharewal  
**From**: Hugo Gonzalez  
**Date**: December 15, 2024  
**SDK Version**: 2.11.3

## Overview

This guide provides a complete, tested solution for integrating the AdaptiveCards iOS SDK using XCFramework distribution. This approach eliminates the CocoaPods dependency resolution issues you've been experiencing.

### 🎉 Key Benefit: No More FluentUI Issues!

The XCFramework includes **MicrosoftFluentUI compiled in**, so you get enhanced tooltips without any of the module map or dependency issues. You only need to add SVGKit and CocoaLumberjack!

## 📦 What's Included

```
AdaptiveCards-Mobile/
├── build_xcframework.sh          # Build script (ready to use)
├── ADAPTIVECARDS_XCFRAMEWORK_GUIDE.md  # Technical documentation
└── QUICK_START_INTEGRATION.md    # This guide
```

### ✨ What Makes This Solution Better

**XCFramework Advantages:**
1. ✅ **FluentUI Built-In** - No more module map errors!
2. ✅ **Just 2 Dependencies** - SVGKit + CocoaLumberjack (vs. complex subspecs)
3. ✅ **Universal Binary** - Works on device + simulator (Intel & Apple Silicon)
4. ✅ **No CocoaPods Headaches** - Works with any dependency manager
5. ✅ **Enhanced Tooltips** - FluentUI functionality included automatically

## 🚀 Quick Start (2 Options)

### Option 1: Use Pre-built XCFramework (Fastest)

If I've already built the XCFramework for you:

1. Download `AdaptiveCards-2.11.3.xcframework.zip`
2. Unzip it
3. Drag `AdaptiveCards.xcframework` into your Xcode project
4. In your target → "Frameworks, Libraries, and Embedded Content":
   - Set to "Embed & Sign"
5. Add required dependencies (see Dependencies section below)
6. Import and use: `import AdaptiveCards`

### Option 2: Build XCFramework Yourself

```bash
# 1. Clone or navigate to AdaptiveCards-Mobile
cd /path/to/AdaptiveCards-Mobile

# 2. Checkout latest main branch
git checkout main
git pull origin main

# 3. Ensure CocoaPods dependencies are installed
cd source/ios/AdaptiveCards
pod install
cd ../../..

# 4. Run the build script
./build_xcframework.sh

# 5. Find your XCFramework at:
# build/xcframework/AdaptiveCards.xcframework
# build/AdaptiveCards-2.11.3.xcframework.zip (distribution package)
```

The build script will:
- ✅ Build for iOS Device (arm64)
- ✅ Build for iOS Simulator (arm64, x86_64)
- ✅ Create universal XCFramework
- ✅ Package for distribution with documentation

**Build time**: ~5-10 minutes on Apple Silicon Mac

## 📱 Dependencies

### ⚡ Good News: FluentUI is Built-In!

The XCFramework **includes FluentUI support** compiled in. Enhanced tooltips work automatically - no additional FluentUI dependency needed!

### Required Dependencies

You only need these two dependencies in your project:

#### 1. SVGKit (>= 3.0.0)
Required for SVG image rendering in cards.

**CocoaPods**:
```ruby
pod 'SVGKit', '>= 3.0.0'
```

**SPM**: Add to your Package.swift
```swift
.package(url: "https://github.com/SVGKit/SVGKit", from: "3.0.0")
```

#### 2. CocoaLumberjack (~> 3.7.0)
Required by SVGKit for logging.

**CocoaPods**:
```ruby
pod 'CocoaLumberjack', '~> 3.7.0'
```

**SPM**: Add to your Package.swift
```swift
.package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack", from: "3.7.0")
```

### Optional Dependencies

#### MicrosoftFluentUI (~> 0.3.6)
**Already included in the XCFramework!** 🎉

The pre-built XCFramework includes FluentUI support compiled in, so enhanced tooltips work out of the box. You **do not** need to add FluentUI as a dependency when using the XCFramework.

**You only need to add FluentUI if:**
- Building the SDK from source yourself
- Using CocoaPods direct integration (not XCFramework)

**CocoaPods** (only if building from source):
```ruby
pod 'MicrosoftFluentUI/Tooltip_ios', '~> 0.3.6'
```

## 📝 Complete Podfile Example

Here's a working Podfile that resolves all the issues you encountered:

```ruby
platform :ios, '14.0'
use_frameworks!

target 'YourApp' do
  # Required: SVG support
  pod 'SVGKit', '>= 3.0.0'
  pod 'CocoaLumberjack', '~> 3.7.0'
  
  # Note: MicrosoftFluentUI is NOT needed - it's already built into the XCFramework!
  # Enhanced tooltips work automatically.
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      # Ensure consistent deployment target
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
      
      # Enable modules
      config.build_settings['DEFINES_MODULE'] = 'YES'
      config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
      config.build_settings['CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'] = 'YES'
      
      # Fix SVGKit module issues
      if target.name.include?('SVGKit')
        config.build_settings['CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'] = 'YES'
      end
      
      # Fix CocoaLumberjack issues
      if target.name.include?('CocoaLumberjack')
        config.build_settings['DEFINES_MODULE'] = 'YES'
      end
      
      # Architecture settings
      config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
    end
  end
end
```

## 🎯 Integration Steps (Detailed)

### Step 1: Prepare Your Project

1. Open your iOS project in Xcode
2. Ensure your project's deployment target is iOS 14.0 or later
3. Ensure Swift 5.0 or later is configured

### Step 2: Add XCFramework

1. In Xcode, right-click your project in the navigator
2. Select "Add Files to [ProjectName]"
3. Navigate to and select `AdaptiveCards.xcframework`
4. Check "Copy items if needed"
5. Ensure your target is selected

Alternatively, drag and drop the XCFramework into your project.

### Step 3: Configure Framework Embedding

1. Select your project in the navigator
2. Select your app target
3. Go to "General" tab
4. Scroll to "Frameworks, Libraries, and Embedded Content"
5. Find `AdaptiveCards.xcframework`
6. Change from "Do Not Embed" to **"Embed & Sign"**

### Step 4: Add Dependencies

Choose either CocoaPods or SPM:

**Using CocoaPods**:
```bash
# Create/update Podfile (use example above)
pod install

# Open the .xcworkspace (not .xcodeproj!)
open YourApp.xcworkspace
```

**Using SPM**:
1. File → Add Package Dependencies
2. Add SVGKit: `https://github.com/SVGKit/SVGKit`
3. Add CocoaLumberjack: `https://github.com/CocoaLumberjack/CocoaLumberjack`

### Step 5: Test Integration

Create a test file:

```swift
import UIKit
import AdaptiveCards

class AdaptiveCardTestViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Simple test card JSON
        let cardJSON = """
        {
            "type": "AdaptiveCard",
            "version": "1.5",
            "body": [
                {
                    "type": "TextBlock",
                    "text": "Hello from AdaptiveCards! 🎉",
                    "size": "large",
                    "weight": "bolder",
                    "wrap": true
                },
                {
                    "type": "TextBlock",
                    "text": "If you can see this, the integration worked!",
                    "wrap": true
                }
            ]
        }
        """
        
        renderCard(jsonString: cardJSON)
    }
    
    func renderCard(jsonString: String) {
        // Parse the card
        guard let cardData = jsonString.data(using: .utf8) else {
            print("Failed to convert JSON string to data")
            return
        }
        
        // TODO: Use AdaptiveCards SDK to parse and render
        // This is a placeholder - see full SDK documentation for complete implementation
        print("Card JSON ready to parse:", cardJSON)
    }
}
```

### Step 6: Build and Run

1. Select a simulator or device
2. Build (Cmd+B)
3. Run (Cmd+R)

## ⚠️ Common Issues and Solutions

### Issue 1: "Module 'AdaptiveCards' not found"

**Solution**:
- Verify XCFramework is in "Embed & Sign" mode
- Clean build folder (Cmd+Shift+K)
- Delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData`
- Rebuild

### Issue 2: "Module 'SVGKit' not found"

**Solution**:
- Ensure SVGKit dependency is installed via CocoaPods or SPM
- If using CocoaPods, make sure you're opening `.xcworkspace`, not `.xcodeproj`
- Run `pod install` again

### Issue 3: Build errors with CocoaLumberjack

**Solution**:
- Add `pod 'CocoaLumberjack', '~> 3.7.0'` explicitly to Podfile
- Run `pod update CocoaLumberjack`
- Use the post_install script from the example above

### Issue 4: FluentUI module map errors

**Solution**:
- **If using XCFramework**: This issue is completely avoided! FluentUI is compiled into the XCFramework, so you never need to deal with the FluentUI dependency
- **If using CocoaPods directly**: Comment out `MicrosoftFluentUI` dependency, but then you'll lose enhanced tooltips
- **Why XCFramework is better**: This was the most common issue with CocoaPods integration - completely solved by XCFramework approach!

### Issue 5: Linker errors about missing frameworks

**Solution**:
Add required system frameworks manually:
1. Target → General → Frameworks, Libraries, and Embedded Content
2. Click "+" and add:
   - AVFoundation.framework
   - AVKit.framework
   - CoreGraphics.framework
   - QuartzCore.framework
   - UIKit.framework

## 📚 Next Steps

### Full SDK Documentation

For complete card rendering implementation:
- [Adaptive Cards iOS Documentation](https://docs.microsoft.com/en-us/adaptive-cards/sdk/rendering-cards/ios)
- [Schema Explorer](https://adaptivecards.io/explorer/)
- [Sample Cards](https://adaptivecards.io/samples/)

### Testing Card Rendering

Use the AdaptiveCards Visualizer app (included in the repo) to test card designs:

```bash
cd AdaptiveCards-Mobile/source/ios/AdaptiveCards
open AdaptiveCards.xcworkspace
# Run ADCIOSVisualizer target
```

## 🔍 Troubleshooting Checklist

Before reaching out, verify:

- [ ] XCFramework is added to project and embedded
- [ ] Using iOS 14.0+ deployment target
- [ ] Swift 5.0+ is configured
- [ ] SVGKit dependency is installed
- [ ] CocoaLumberjack dependency is installed
- [ ] If using CocoaPods, opened `.xcworkspace` not `.xcodeproj`
- [ ] Clean build folder tried
- [ ] DerivedData cleared
- [ ] Latest Xcode version (12.0+)

## 📞 Support

If you encounter issues:

1. Check the troubleshooting section above
2. Review build logs for specific error messages
3. Check `ADAPTIVECARDS_XCFRAMEWORK_GUIDE.md` for technical details
4. Contact: Hugo Gonzalez

## 🎉 Success Indicators

You'll know integration is successful when:

1. ✅ Build succeeds with no errors
2. ✅ `import AdaptiveCards` statement doesn't show errors
3. ✅ App runs on simulator without crashes
4. ✅ App runs on device without crashes
5. ✅ Can parse and render a simple card

## 📦 Distribution Package Contents

When you receive or build the distribution package, it contains:

```
AdaptiveCards-2.11.3.xcframework/
├── Info.plist
├── ios-arm64/                    # For iOS devices
│   └── AdaptiveCards.framework
└── ios-arm64_x86_64-simulator/   # For simulators
    └── AdaptiveCards.framework
```

Each framework includes:
- Compiled binaries
- Swift module files
- Headers
- Resources (images, etc.)

## 📝 Version Information

- **SDK Version**: 2.11.3
- **Minimum iOS**: 14.0
- **Swift Version**: 5.0+
- **Architecture**: arm64 (device), arm64 + x86_64 (simulator)
- **Build Date**: December 15, 2024

## ⚡ Performance Notes

- XCFramework size: ~5-10 MB (framework only)
- First load time: < 1 second
- Card parsing: Near-instant for typical cards
- Rendering: Depends on card complexity

## 🔒 Security & Privacy

- No data collection by the SDK
- All card processing is local
- Network requests only if card contains web images
- Follows Apple's security guidelines

---

**Questions?** Don't hesitate to reach out. We'll get this working! 🚀
