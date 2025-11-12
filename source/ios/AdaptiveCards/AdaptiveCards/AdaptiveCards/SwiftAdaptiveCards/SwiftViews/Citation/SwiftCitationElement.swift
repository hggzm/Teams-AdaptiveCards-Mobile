//
//  SwiftCitationElement.swift
//  AdaptiveCards
//
//  Created on 11/09/25.
//  Copyright © 2025 Microsoft. All rights reserved.
//

import Foundation

// MARK: - Citation Data Models

/// Information about a citation/reference source
@available(iOS 15.0, *)
public struct CitationInfo: Codable {
    let title: String
    let url: URL?
    let snippet: String?
    let authors: [String]?
    let year: Int?
    let publisher: String?
    
    enum CodingKeys: String, CodingKey {
        case title, url, snippet, authors, year, publisher
    }
    
    init(title: String, url: URL? = nil, snippet: String? = nil, authors: [String]? = nil, year: Int? = nil, publisher: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.authors = authors
        self.year = year
        self.publisher = publisher
    }
}

/// Complete citation data for rendering
@available(iOS 15.0, *)
public struct SwiftCitationData {
    let referenceId: Int
    let displayText: String
    let citation: CitationInfo
    
    init(referenceId: Int, displayText: String, citation: CitationInfo) {
        self.referenceId = referenceId
        self.displayText = displayText
        self.citation = citation
    }
}

// MARK: - Swift Adaptive Card Element

/// Citation element that can be parsed from JSON as a custom card element
@available(iOS 15.0, *)
public class SwiftCitationElement: SwiftBaseCardElement {
    
    // Citation-specific properties
    public let referenceId: Int
    public let displayText: String
    public let citation: CitationInfo
    
    // Computed property for quick access
    public var citationData: SwiftCitationData {
        return SwiftCitationData(
            referenceId: referenceId,
            displayText: displayText,
            citation: citation
        )
    }
    
    // MARK: - Initializers
    
    init(referenceId: Int, displayText: String, citation: CitationInfo, id: String? = nil) {
        self.referenceId = referenceId
        self.displayText = displayText
        self.citation = citation
        
        // Initialize with custom type
        super.init(
            type: .custom,
            id: id
        )
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case referenceId, displayText, citation
        case type, id
        case spacing, height, separator, isVisible
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode citation-specific properties
        self.referenceId = try container.decode(Int.self, forKey: .referenceId)
        self.displayText = try container.decode(String.self, forKey: .displayText)
        self.citation = try container.decode(CitationInfo.self, forKey: .citation)
        
        // Call super init with .custom type
        try super.init(from: decoder)
    }
    
    override public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        // Encode citation-specific properties
        try container.encode(referenceId, forKey: .referenceId)
        try container.encode(displayText, forKey: .displayText)
        try container.encode(citation, forKey: .citation)
        
        // Encode base properties
        try super.encode(to: encoder)
    }
}

// MARK: - Parsing Helper

@available(iOS 15.0, *)
extension SwiftCitationElement {
    
    /// Parse citation element from a dictionary
    /// Useful for parsing from adaptive card additionalProperties or custom JSON
    public static func parse(from dict: [String: Any]) -> SwiftCitationElement? {
        // Validate type
        guard let type = dict["type"] as? String, type == "Citation" else {
            print("⚠️ SwiftCitationElement: Invalid or missing type field")
            return nil
        }
        
        // Required fields
        guard let referenceId = dict["referenceId"] as? Int,
              let displayText = dict["displayText"] as? String,
              let citationDict = dict["citation"] as? [String: Any],
              let title = citationDict["title"] as? String else {
            print("⚠️ SwiftCitationElement: Missing required fields")
            return nil
        }
        
        // Optional citation fields
        let url = (citationDict["url"] as? String).flatMap { URL(string: $0) }
        let snippet = citationDict["snippet"] as? String
        let authors = citationDict["authors"] as? [String]
        let year = citationDict["year"] as? Int
        let publisher = citationDict["publisher"] as? String
        let id = dict["id"] as? String
        
        let citationInfo = CitationInfo(
            title: title,
            url: url,
            snippet: snippet,
            authors: authors,
            year: year,
            publisher: publisher
        )
        
        return SwiftCitationElement(
            referenceId: referenceId,
            displayText: displayText,
            citation: citationInfo,
            id: id
        )
    }
}

// MARK: - Objective-C Bridge

/// Objective-C compatible wrapper for citation data
/// This allows Objective-C renderers to access parsed data
@available(iOS 15.0, *)
@objc public class SwiftCitationDataBridge: NSObject {
    
    private let citationData: SwiftCitationData
    
    @objc public var referenceId: Int {
        return citationData.referenceId
    }
    
    @objc public var displayText: String {
        return citationData.displayText
    }
    
    @objc public var title: String {
        return citationData.citation.title
    }
    
    @objc public var url: URL? {
        return citationData.citation.url
    }
    
    @objc public var snippet: String? {
        return citationData.citation.snippet
    }
    
    @objc public var authors: [String]? {
        return citationData.citation.authors
    }
    
    @objc public var year: NSNumber? {
        guard let year = citationData.citation.year else { return nil }
        return NSNumber(value: year)
    }
    
    @objc public var publisher: String? {
        return citationData.citation.publisher
    }
    
    init(citationData: SwiftCitationData) {
        self.citationData = citationData
        super.init()
    }
    
    /// Create from dictionary (for Objective-C convenience)
    @objc public static func create(from dictionary: [String: Any]) -> SwiftCitationDataBridge? {
        guard let element = SwiftCitationElement.parse(from: dictionary) else {
            return nil
        }
        return SwiftCitationDataBridge(citationData: element.citationData)
    }
}

// MARK: - Debug Description

@available(iOS 15.0, *)
extension SwiftCitationElement: CustomStringConvertible {
    public var description: String {
        return """
        SwiftCitationElement(
            referenceId: \(referenceId),
            displayText: "\(displayText)",
            citation: "\(citation.title)",
            hasUrl: \(citation.url != nil),
            hasSnippet: \(citation.snippet != nil)
        )
        """
    }
}
