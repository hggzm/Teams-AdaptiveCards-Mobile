//
//  CitationExamples.swift
//  AdaptiveCards
//
//  Created on 11/09/25.
//  Copyright © 2025 Microsoft. All rights reserved.
//

import Foundation

/// Example JSON payloads and usage patterns for Citation elements
@available(iOS 15.0, *)
public struct CitationExamples {
    
    // MARK: - Sample JSON Payloads
    
    /// Simple citation with minimal information
    public static let simpleCitationJSON = """
    {
      "type": "Citation",
      "referenceId": 1,
      "displayText": "[1]",
      "citation": {
        "title": "Introduction to Machine Learning"
      }
    }
    """
    
    /// Full citation with all fields
    public static let fullCitationJSON = """
    {
      "type": "Citation",
      "referenceId": 1,
      "displayText": "[1]",
      "id": "citation-1",
      "citation": {
        "title": "Deep Learning: Foundations and Applications",
        "url": "https://arxiv.org/abs/example",
        "snippet": "This comprehensive study explores the foundational principles of deep learning and their practical applications in modern AI systems.",
        "authors": ["Dr. Jane Smith", "Prof. John Doe", "Dr. Alice Johnson"],
        "year": 2024,
        "publisher": "MIT Press"
      }
    }
    """
    
    /// Adaptive card with inline citations
    public static let cardWithCitationsJSON = """
    {
      "type": "AdaptiveCard",
      "version": "1.5",
      "body": [
        {
          "type": "TextBlock",
          "text": "Recent advances in artificial intelligence",
          "weight": "bolder",
          "size": "large"
        },
        {
          "type": "TextBlock",
          "text": "Multiple studies have shown significant improvements in model performance",
          "wrap": true
        },
        {
          "type": "Citation",
          "referenceId": 1,
          "displayText": "[1]",
          "citation": {
            "title": "Neural Network Optimization Techniques",
            "url": "https://arxiv.org/abs/2024.12345",
            "authors": ["Smith, J.", "Doe, J."],
            "year": 2024
          }
        },
        {
          "type": "TextBlock",
          "text": "with transformer architectures showing particular promise",
          "wrap": true
        },
        {
          "type": "Citation",
          "referenceId": 2,
          "displayText": "[2]",
          "citation": {
            "title": "Attention Is All You Need",
            "url": "https://arxiv.org/abs/1706.03762",
            "authors": ["Vaswani, A.", "Shazeer, N.", "Parmar, N."],
            "year": 2017,
            "publisher": "NeurIPS"
          }
        }
      ]
    }
    """
    
    /// Citation in metadata (alternative approach)
    public static let cardWithCitationMetadataJSON = """
    {
      "type": "AdaptiveCard",
      "version": "1.5",
      "body": [
        {
          "type": "TextBlock",
          "text": "Research findings [1]",
          "wrap": true
        }
      ],
      "metadata": {
        "citations": [
          {
            "referenceId": 1,
            "displayText": "[1]",
            "citation": {
              "title": "Important Research Paper",
              "url": "https://example.com/paper",
              "authors": ["Author Name"],
              "year": 2024
            }
          }
        ]
      }
    }
    """
    
    // MARK: - Programmatic Creation Examples
    
    /// Create a citation element programmatically
    public static func createSampleCitation() -> SwiftCitationElement {
        let citation = CitationInfo(
            title: "Machine Learning in Production",
            url: URL(string: "https://example.com/ml-production"),
            snippet: "A comprehensive guide to deploying ML models in production environments.",
            authors: ["Dr. Sarah Johnson", "Prof. Michael Chen"],
            year: 2024,
            publisher: "Tech Press"
        )
        
        return SwiftCitationElement(
            referenceId: 1,
            displayText: "[1]",
            citation: citation,
            id: "citation-1"
        )
    }
    
    /// Create multiple citations for a research article
    public static func createResearchCitations() -> [SwiftCitationElement] {
        let citations = [
            CitationInfo(
                title: "Foundations of Deep Learning",
                url: URL(string: "https://arxiv.org/example1"),
                authors: ["LeCun, Y.", "Bengio, Y.", "Hinton, G."],
                year: 2015
            ),
            CitationInfo(
                title: "Attention Mechanisms in Neural Networks",
                url: URL(string: "https://arxiv.org/example2"),
                authors: ["Bahdanau, D.", "Cho, K."],
                year: 2014
            ),
            CitationInfo(
                title: "Transfer Learning and Domain Adaptation",
                url: URL(string: "https://arxiv.org/example3"),
                snippet: "This paper introduces novel techniques for transfer learning across domains.",
                authors: ["Pan, S.J.", "Yang, Q."],
                year: 2010,
                publisher: "IEEE"
            )
        ]
        
        return citations.enumerated().map { index, citation in
            SwiftCitationElement(
                referenceId: index + 1,
                displayText: "[\(index + 1)]",
                citation: citation,
                id: "citation-\(index + 1)"
            )
        }
    }
    
    // MARK: - Usage Examples
    
    /// Example: Parse citation from JSON string
    public static func parseFromJSON() -> SwiftCitationElement? {
        guard let jsonData = simpleCitationJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        
        return SwiftCitationElement.parse(from: dict)
    }
    
    /// Example: Create SwiftUI view from citation
    public static func createView(from citation: SwiftCitationElement) -> CitationHostingView {
        return CitationHostingView(citationData: citation.citationData)
    }
    
    // MARK: - Integration Examples
    
    /// Example registration code for Objective-C renderer
    public static let registrationCode = """
    // In your app initialization or ACRRegistration setup:
    
    ACRRegistration *registration = [ACRRegistration getInstance];
    
    // Register citation renderer for custom element type
    [registration setCustomElementRenderer:[[ACRCitationRenderer alloc] init]
                                       key:@"Citation"];
    
    // Now citation elements will be automatically rendered when parsing cards
    """
    
    /// Example card parsing with citations
    public static let parsingExample = """
    // Swift code to parse and render a card with citations:
    
    let jsonString = CitationExamples.cardWithCitationsJSON
    guard let jsonData = jsonString.data(using: .utf8) else { return }
    
    // Parse adaptive card (using existing SDK)
    let parseResult = ACOAdaptiveCard.fromJson(jsonData)
    
    if let card = parseResult?.card {
        // Render card (citations will be automatically handled by ACRCitationRenderer)
        let renderResult = ACRRenderer.render(
            card,
            config: hostConfig,
            widthConstraint: 320,
            theme: .default
        )
        
        // Add rendered view to your UI
        if let view = renderResult.view {
            parentView.addSubview(view)
        }
    }
    """
    
    // MARK: - Testing Helpers
    
    /// Create test citation for unit tests
    public static func createTestCitation(
        referenceId: Int = 1,
        title: String = "Test Citation",
        includeUrl: Bool = true,
        includeSnippet: Bool = true
    ) -> SwiftCitationElement {
        let citation = CitationInfo(
            title: title,
            url: includeUrl ? URL(string: "https://test.example.com") : nil,
            snippet: includeSnippet ? "This is a test citation snippet for unit testing." : nil,
            authors: ["Test Author"],
            year: 2024,
            publisher: "Test Publisher"
        )
        
        return SwiftCitationElement(
            referenceId: referenceId,
            displayText: "[\(referenceId)]",
            citation: citation,
            id: "test-citation-\(referenceId)"
        )
    }
}

// MARK: - Documentation Examples

/**
 # Citation Component Usage Guide
 
 ## Overview
 The Citation component provides a SwiftUI-based rendering solution for academic and reference citations
 within Adaptive Cards, without requiring C++ SDK modifications.
 
 ## Basic Usage
 
 ### JSON Format
 ```json
 {
   "type": "Citation",
   "referenceId": 1,
   "displayText": "[1]",
   "citation": {
     "title": "Paper Title",
     "url": "https://example.com",
     "authors": ["Author Name"],
     "year": 2024
   }
 }
 ```
 
 ### Programmatic Creation
 ```swift
 let citation = CitationInfo(
     title: "Research Paper",
     url: URL(string: "https://example.com")
 )
 
 let element = SwiftCitationElement(
     referenceId: 1,
     displayText: "[1]",
     citation: citation
 )
 
 let view = CitationHostingView(citationData: element.citationData)
 ```
 
 ## Integration
 
 ### Renderer Registration
 Register the renderer during app initialization:
 ```objc
 [[ACRRegistration getInstance] setCustomElementRenderer:[[ACRCitationRenderer alloc] init]
                                                      key:@"Citation"];
 ```
 
 ### Automatic Rendering
 Once registered, citations in adaptive cards are automatically rendered:
 ```swift
 let card = ACOAdaptiveCard.fromJson(cardJSON)
 let rendered = ACRRenderer.render(card, config: config, widthConstraint: 320)
 ```
 
 ## Features
 
 - ✅ Compact inline display with expandable details
 - ✅ Full citation information in modal sheet
 - ✅ Clickable links to source material
 - ✅ Author and publication metadata
 - ✅ Accessibility support
 - ✅ Dynamic sizing and layout
 - ✅ Dark mode support
 
 ## Architecture
 
 The component follows a clean layered architecture:
 1. **Swift Model** (`SwiftCitationElement`) - Data parsing and validation
 2. **SwiftUI View** (`CitationView`) - Modern UI implementation
 3. **UIKit Bridge** (`CitationHostingView`) - Integration with existing views
 4. **Obj-C Renderer** (`ACRCitationRenderer`) - Adaptive Card pipeline integration
 
 ## Best Practices
 
 1. Always provide a `title` (required field)
 2. Include `url` when available for source verification
 3. Use consistent `displayText` format (e.g., "[1]", "[2]")
 4. Keep `snippet` concise (1-2 sentences recommended)
 5. Include publication `year` for academic citations
 */
