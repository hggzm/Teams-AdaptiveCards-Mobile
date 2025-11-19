//
//  CustomElementRegistry.swift
//  AdaptiveCardCustomElements
//
//  Central registry for all custom elements in the package
//

import Foundation
import UIKit

/// Registry that manages all custom element types in the package
@objc public class CustomElementRegistry: NSObject {
    
    /// Shared singleton instance
    @objc public static let shared = CustomElementRegistry()
    
    private var parsers: [String: (([String: Any]) -> Any?)] = [:]
    private var factories: [String: ((Any) -> UIView?)] = [:]
    
    private override init() {
        super.init()
        registerBuiltInElements()
    }
    
    /// Register all built-in custom elements
    private func registerBuiltInElements() {
        // Register Badge
        registerElement(
            type: "Badge",
            parser: { json in
                return BadgeElementParser.parse(from: json)
            },
            factory: { data in
                guard let badgeData = data as? BadgeDataBridge else { return nil }
                return BadgeViewFactory.createView(with: badgeData)
            }
        )
        
        // Register StatusIndicator
        registerElement(
            type: "StatusIndicator",
            parser: { json in
                return StatusIndicatorElementParser.parse(from: json)
            },
            factory: { data in
                guard let statusData = data as? StatusIndicatorDataBridge else { return nil }
                return StatusIndicatorViewFactory.createView(with: statusData)
            }
        )
        
        // Register ProgressBar
        registerElement(
            type: "ProgressBar",
            parser: { json in
                return ProgressBarElementParser.parse(from: json)
            },
            factory: { data in
                guard let progressData = data as? ProgressBarDataBridge else { return nil }
                return ProgressBarViewFactory.createView(with: progressData)
            }
        )
        
        // Add more elements here as they're implemented
        // registerElement(
        //     type: "Rating",
        //     parser: { json in RatingElementParser.parse(from: json) },
        //     factory: { data in
        //         guard let ratingData = data as? RatingDataBridge else { return nil }
        //         return RatingViewFactory.createView(with: ratingData)
        //     }
        // )
    }
    
    /// Register a custom element type
    /// - Parameters:
    ///   - type: The element type identifier (e.g., "Badge")
    ///   - parser: Closure that parses JSON to element data
    ///   - factory: Closure that creates a UIView from element data
    private func registerElement(
        type: String,
        parser: @escaping ([String: Any]) -> Any?,
        factory: @escaping (Any) -> UIView?
    ) {
        parsers[type] = parser
        factories[type] = factory
    }
    
    /// Check if an element type is supported
    /// - Parameter type: The element type identifier
    /// - Returns: true if the type is registered
    @objc public func supportsType(_ type: String) -> Bool {
        return parsers[type] != nil
    }
    
    /// Get all supported element types
    /// - Returns: Array of supported type identifiers
    @objc public func supportedTypes() -> [String] {
        return Array(parsers.keys)
    }
    
    /// Parse and create a view for a custom element
    /// - Parameter json: JSON dictionary containing element data
    /// - Returns: UIView instance, or nil if parsing/creation fails
    @objc public func createView(from json: [String: Any]) -> UIView? {
        guard let type = json["type"] as? String else {
            return nil
        }
        
        guard let parser = parsers[type],
              let factory = factories[type] else {
            return nil
        }
        
        guard let data = parser(json) else {
            return nil
        }
        
        return factory(data)
    }
}
