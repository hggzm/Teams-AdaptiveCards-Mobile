# AdaptiveCardCustomElements

A Swift package providing reusable SwiftUI custom element views for Adaptive Cards iOS SDK.

## Overview

This package provides a collection of pre-built SwiftUI components that can be used as custom elements in Adaptive Cards. Each component follows a consistent pattern:

- **Data Model**: A Swift struct conforming to `CustomElementData` and `Codable`
- **SwiftUI View**: A SwiftUI view for rendering the component
- **UIKit Bridge**: A `UIHostingView` wrapper for integration with UIKit
- **Objective-C Bridge**: Bridge classes for Objective-C interop

## Components

### Badge

A colored badge component for displaying status indicators, tags, or labels.

**JSON Example:**
```json
{
    "type": "Badge",
    "text": "New",
    "color": "#FF5733",
    "textColor": "#FFFFFF",
    "size": "medium",
    "icon": "star.fill"
}
```

**Properties:**
- `text` (required): The text to display
- `color` (optional): Hex color code for background (defaults to blue)
- `textColor` (optional): Hex color code for text (defaults to white)
- `size` (optional): "small", "medium", or "large" (defaults to medium)
- `icon` (optional): SF Symbol name to display before text

## Usage

### In Swift

```swift
import AdaptiveCardCustomElements

// Create a badge
let badgeData = BadgeData(text: "Premium", color: "#9B59B6", size: "large", icon: "star.fill")
let badgeView = BadgeView(data: badgeData)

// Or use the factory for UIKit integration
let uiView = BadgeHostingView(data: badgeData)
```

### With Adaptive Cards SDK

The package integrates with the Adaptive Cards SDK through the `CustomElementViewProvider`:

```swift
import AdaptiveCardCustomElements

// Check if a custom element type is supported
if CustomElementViewProvider.supportsType("Badge") {
    // Create a view for the custom element
    if let view = CustomElementViewProvider.createView(for: badgeData) {
        // Use the view...
    }
}
```

### From Objective-C

```objc
@import AdaptiveCardCustomElements;

// Create badge data
BadgeDataBridge *badgeData = [[BadgeDataBridge alloc] initWithText:@"New"
                                                              color:@"#FF5733"
                                                          textColor:@"#FFFFFF"
                                                               size:@"medium"
                                                               icon:@"star.fill"];

// Create the view
UIView *badgeView = [BadgeViewFactory createViewWith:badgeData];
```

## Adding New Custom Elements

To add a new custom element:

1. Create a data model struct conforming to `CustomElementData` and `Codable`
2. Create a SwiftUI view for rendering
3. Create a `UIHostingView` wrapper
4. Add Objective-C bridge classes if needed
5. Register the type in `CustomElementViewProvider`

Example:

```swift
// 1. Data Model
public struct RatingData: CustomElementData, Codable {
    public let type: String = "Rating"
    public let value: Double
    public let maxValue: Double
}

// 2. SwiftUI View
public struct RatingView: View {
    let data: RatingData
    
    public var body: some View {
        // Your view implementation
    }
}

// 3. Register in CustomElementViewProvider
public static func createView(for data: CustomElementData) -> AnyView? {
    switch data.type {
    case "Rating":
        if let ratingData = data as? RatingData {
            return AnyView(RatingView(data: ratingData))
        }
    // ... other cases
    }
}
```

## Requirements

- iOS 15.0+
- Swift 5.9+

## Integration with Adaptive Cards SDK

This package is designed to work with the Adaptive Cards iOS SDK. The SDK's `SwiftAdaptiveCardObjcBridge` can import this package and use the `CustomElementViewProvider` to create views for custom elements.

## License

See the main Adaptive Cards repository for license information.
