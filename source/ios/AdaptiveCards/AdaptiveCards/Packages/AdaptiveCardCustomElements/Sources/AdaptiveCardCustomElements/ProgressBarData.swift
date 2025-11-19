//
//  ProgressBarData.swift
//  AdaptiveCardCustomElements
//
//  Data model for ProgressBar custom element
//

import Foundation

/// Data model for ProgressBar custom element
/// Represents a horizontal progress bar showing completion percentage
public struct ProgressBarData: CustomElementData, Codable {
    public let type: String = "ProgressBar"
    
    /// Progress value from 0.0 to 1.0
    public let progress: Double
    
    /// Optional label text
    public let label: String?
    
    public init(progress: Double, label: String? = nil) {
        self.progress = progress
        self.label = label
    }
}

/// Bridge class to expose ProgressBarData to Objective-C
@objc public class ProgressBarDataBridge: NSObject {
    public let progress: Double
    public let label: String?
    
    @objc public init(progress: Double, label: String?) {
        self.progress = progress
        self.label = label
        super.init()
    }
}

extension ProgressBarData: Equatable {
    public static func == (lhs: ProgressBarData, rhs: ProgressBarData) -> Bool {
        return lhs.progress == rhs.progress &&
               lhs.label == rhs.label
    }
}

extension ProgressBarData: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(progress)
        hasher.combine(label)
    }
}
