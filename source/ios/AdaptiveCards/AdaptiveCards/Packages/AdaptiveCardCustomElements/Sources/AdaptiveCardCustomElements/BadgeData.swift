//
//  BadgeData.swift
//  AdaptiveCardCustomElements
//
//  Data model for Badge custom element
//

import Foundation

/// Data model for Badge custom element
/// Represents a colored badge with text (like a status indicator, tag, or label)
public struct BadgeData: CustomElementData, Codable {
    public let type: String = "Badge"
    
    /// The text to display in the badge
    public let text: String
    
    /// The color of the badge (hex color code, e.g., "#FF5733")
    public let color: String?
    
    /// The text color (hex color code, defaults to white)
    public let textColor: String?
    
    /// The size of the badge ("small", "medium", "large")
    public let size: String?
    
    /// Optional icon name (SF Symbol name)
    public let icon: String?
    
    public init(text: String, color: String? = nil, textColor: String? = nil, size: String? = nil, icon: String? = nil) {
        self.text = text
        self.color = color
        self.textColor = textColor
        self.size = size
        self.icon = icon
    }
}

/// Bridge class to expose BadgeData to Objective-C
@objc public class BadgeDataBridge: NSObject {
    public let text: String
    public let color: String?
    public let textColor: String?
    public let size: String?
    public let icon: String?
    
    @objc public init(text: String, color: String?, textColor: String?, size: String?, icon: String?) {
        self.text = text
        self.color = color
        self.textColor = textColor
        self.size = size
        self.icon = icon
        super.init()
    }
    
    /// Convert to Swift BadgeData
    public func toBadgeData() -> BadgeData {
        return BadgeData(text: text, color: color, textColor: textColor, size: size, icon: icon)
    }
}
