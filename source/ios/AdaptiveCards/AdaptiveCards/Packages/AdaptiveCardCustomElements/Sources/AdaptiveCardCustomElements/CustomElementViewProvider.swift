//
//  CustomElementViewProvider.swift
//  AdaptiveCardCustomElements
//
//  Protocol and factory for creating SwiftUI views for custom Adaptive Card elements.
//

import SwiftUI

/// Protocol that custom element data models must conform to
public protocol CustomElementData {
    /// The type identifier for the custom element (e.g., "Badge", "Rating", etc.)
    var type: String { get }
}

/// Factory for creating SwiftUI views from custom element data
public struct CustomElementViewProvider {
    
    /// Creates a SwiftUI view for the given custom element data
    /// - Parameter data: The custom element data
    /// - Returns: A SwiftUI view, or nil if the element type is not supported
    public static func createView(for data: CustomElementData) -> AnyView? {
        switch data.type {
        case "Badge":
            if let badgeData = data as? BadgeData {
                return AnyView(BadgeView(data: badgeData))
            }
            
        // Add more custom element types here as they're implemented
        // case "Rating":
        //     if let ratingData = data as? RatingData {
        //         return AnyView(RatingView(data: ratingData))
        //     }
            
        default:
            return nil
        }
        
        return nil
    }
    
    /// Check if a custom element type is supported
    /// - Parameter type: The custom element type identifier
    /// - Returns: true if the type is supported, false otherwise
    public static func supportsType(_ type: String) -> Bool {
        switch type {
        case "Badge":
            return true
        default:
            return false
        }
    }
}
