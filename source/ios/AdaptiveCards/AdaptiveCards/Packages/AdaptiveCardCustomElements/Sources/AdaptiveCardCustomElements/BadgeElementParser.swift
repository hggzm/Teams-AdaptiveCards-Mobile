//
//  BadgeElementParser.swift
//  AdaptiveCardCustomElements
//
//  Parser for Badge element from JSON dictionary
//

import Foundation

/// Helper class for parsing Badge elements from JSON
@objc public class BadgeElementParser: NSObject {
    
    /// Parse a Badge element from a JSON dictionary
    /// - Parameter json: JSON dictionary containing badge data
    /// - Returns: BadgeDataBridge instance, or nil if parsing fails
    @objc public static func parse(from json: [String: Any]) -> BadgeDataBridge? {
        guard let type = json["type"] as? String, type == "Badge" else {
            return nil
        }
        
        guard let text = json["text"] as? String else {
            return nil
        }
        
        let color = json["color"] as? String
        let textColor = json["textColor"] as? String
        let size = json["size"] as? String
        let icon = json["icon"] as? String
        
        return BadgeDataBridge(
            text: text,
            color: color,
            textColor: textColor,
            size: size,
            icon: icon
        )
    }
}
