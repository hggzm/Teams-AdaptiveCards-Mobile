//
//  ProgressBarElementParser.swift
//  AdaptiveCardCustomElements
//
//  Parser for ProgressBar element from JSON dictionary
//

import Foundation

/// Helper class for parsing ProgressBar elements from JSON
@objc public class ProgressBarElementParser: NSObject {
    
    /// Parse a ProgressBar element from a JSON dictionary
    /// - Parameter json: JSON dictionary containing progress bar data
    /// - Returns: ProgressBarDataBridge instance, or nil if parsing fails
    @objc public static func parse(from json: [String: Any]) -> ProgressBarDataBridge? {
        guard let type = json["type"] as? String, type == "ProgressBar" else {
            return nil
        }
        
        // Parse progress - required field
        guard let progress = json["progress"] as? Double else {
            return nil
        }
        
        // Parse label - optional field
        let label = json["label"] as? String
        
        return ProgressBarDataBridge(
            progress: progress,
            label: label
        )
    }
}
