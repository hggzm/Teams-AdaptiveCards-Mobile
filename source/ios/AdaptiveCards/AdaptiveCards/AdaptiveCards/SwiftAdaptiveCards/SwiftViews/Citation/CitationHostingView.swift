//
//  CitationHostingView.swift
//  AdaptiveCards
//
//  Created on 11/09/25.
//  Copyright © 2025 Microsoft. All rights reserved.
//

import UIKit
import SwiftUI

/// UIKit wrapper for CitationView that integrates with Objective-C rendering pipeline
/// Handles automatic sizing and layout within the adaptive card view hierarchy
@available(iOS 15.0, *)
@objc public class CitationHostingView: UIView {
    
    private let citationData: SwiftCitationData
    private var hostingController: UIHostingController<AnyView>?
    private var lastReportedHeight: CGFloat = 0
    
    // MARK: - Initialization
    
    /// Initialize with citation data
    init(citationData: SwiftCitationData) {
        self.citationData = citationData
        super.init(frame: .zero)
        ACDiagnosticLogger.log("Initializing CitationHostingView for reference: \(citationData.referenceId)", category: "Citation")
        setupHostingView()
    }
    
    /// Initialize from Objective-C bridge
    @objc public init(bridge: SwiftCitationDataBridge) {
        self.citationData = SwiftCitationData(
            referenceId: bridge.referenceId,
            displayText: bridge.displayText,
            citation: CitationInfo(
                title: bridge.title,
                url: bridge.url,
                snippet: bridge.snippet,
                authors: bridge.authors,
                year: bridge.year?.intValue,
                publisher: bridge.publisher
            )
        )
        super.init(frame: .zero)
        ACDiagnosticLogger.log("Initializing CitationHostingView from bridge", category: "Citation")
        setupHostingView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
    
    // MARK: - Setup
    
    private func setupHostingView() {
        // Create SwiftUI view with height change callback
        let swiftUIView = CitationView(data: citationData, onHeightChange: { [weak self] in
            self?.notifyHeightChange()
        })
        
        // Wrap in hosting controller
        let hostingController = UIHostingController(rootView: AnyView(swiftUIView))
        hostingController.view.backgroundColor = UIColor.clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        
        // Prevent clipping
        hostingController.view.clipsToBounds = false
        self.clipsToBounds = false
        
        // Add to view hierarchy
        addSubview(hostingController.view)
        
        // Setup constraints
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        
        // Set content priorities (similar to ChainOfThought pattern)
        let requiredPriority = UILayoutPriority.required
        let verticalAxis = NSLayoutConstraint.Axis.vertical
        hostingController.view.setContentHuggingPriority(requiredPriority, for: verticalAxis)
        hostingController.view.setContentCompressionResistancePriority(requiredPriority, for: verticalAxis)
        self.setContentHuggingPriority(requiredPriority, for: verticalAxis)
        self.setContentCompressionResistancePriority(requiredPriority, for: verticalAxis)
        
        self.hostingController = hostingController
        
        // Observe size changes
        let observingOptions: NSKeyValueObservingOptions = [.new, .old]
        hostingController.view.addObserver(self, forKeyPath: "bounds", options: observingOptions, context: nil)
        
        // Initial height notification
        notifyHeightChange()
    }
    
    // MARK: - Lifecycle
    
    deinit {
        hostingController?.view.removeObserver(self, forKeyPath: "bounds")
    }
    
    // MARK: - KVO
    
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "bounds" {
            invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in
                self?.notifyHeightChange()
            }
        }
    }
    
    // MARK: - Height Management
    
    private func notifyHeightChange() {
        let currentHeight = intrinsicContentSize.height
        
        // Only notify if height changed significantly (avoid redundant updates)
        guard abs(currentHeight - lastReportedHeight) > 2.0 else { return }
        lastReportedHeight = currentHeight
        
        ACDiagnosticLogger.log("Citation height changed to \(currentHeight)pt", category: "Layout")
        
        // Invalidate intrinsic content size
        invalidateIntrinsicContentSize()
        
        // Update hosting controller
        hostingController?.view.invalidateIntrinsicContentSize()
        
        // Walk up view hierarchy to notify containers (ChainOfThought pattern)
        var view: UIView? = self.superview
        while view != nil {
            let className = NSStringFromClass(type(of: view!))
            
            if className.contains("ACRContentStackView") {
                ACDiagnosticLogger.log("Found ACRContentStackView, updating layout", category: "Layout")
                view?.invalidateIntrinsicContentSize()
                view?.setNeedsLayout()
                view?.layoutIfNeeded()
                view?.superview?.invalidateIntrinsicContentSize()
                view?.superview?.setNeedsLayout()
                break
            } else if className.contains("UIStackView") {
                view?.invalidateIntrinsicContentSize()
                view?.setNeedsLayout()
                view?.layoutIfNeeded()
            } else if let tableView = view as? UITableView {
                ACDiagnosticLogger.log("Found UITableView, performing batch update", category: "Layout")
                tableView.beginUpdates()
                tableView.endUpdates()
                break
            } else if let scrollView = view as? UIScrollView {
                scrollView.invalidateIntrinsicContentSize()
                scrollView.setNeedsLayout()
                scrollView.layoutIfNeeded()
            }
            
            view = view?.superview
        }
        
        // Force complete layout update after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            self.superview?.setNeedsLayout()
            self.superview?.layoutIfNeeded()
        }
    }
    
    // MARK: - Layout Overrides
    
    public override var intrinsicContentSize: CGSize {
        guard let hostingController = hostingController else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 25) // Default citation height
        }
        
        // Citation views are typically small and fixed height
        // Use a reasonable target width for measurement
        let targetWidth = bounds.width > 0 ? bounds.width : 50.0 // Citations are usually compact
        let tempSize = CGSize(width: targetWidth, height: 100) // Max measurement height
        
        let measuredSize = hostingController.sizeThatFits(in: tempSize)
        
        // Clamp to reasonable bounds for citation badges (typically 20-30pt high)
        let clampedHeight = min(max(measuredSize.height, 20), 40)
        
        let result = CGSize(
            width: measuredSize.width,
            height: clampedHeight
        )
        
        return result
    }
    
    public override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        guard let hostingController = hostingController else {
            return CGSize(width: targetSize.width, height: 25)
        }
        
        let constrainedSize = CGSize(
            width: targetSize.width,
            height: min(targetSize.height, 100)
        )
        
        let measuredSize = hostingController.sizeThatFits(in: constrainedSize)
        let clampedHeight = min(max(measuredSize.height, 20), 40)
        
        return CGSize(
            width: measuredSize.width,
            height: clampedHeight
        )
    }
    
    public override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        return systemLayoutSizeFitting(targetSize)
    }
    
    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        return systemLayoutSizeFitting(size)
    }
}

// MARK: - Factory Methods

@available(iOS 15.0, *)
extension CitationHostingView {
    
    /// Create hosting view from SwiftCitationElement
    public static func createFromElement(_ element: SwiftCitationElement) -> UIView {
        return CitationHostingView(citationData: element.citationData)
    }
    
    /// Create hosting view from dictionary (for Objective-C convenience)
    @objc public static func createFromDictionary(_ dict: [String: Any]) -> UIView? {
        guard let element = SwiftCitationElement.parse(from: dict) else {
            ACDiagnosticLogger.log("Failed to parse citation from dictionary", category: "Error")
            return nil
        }
        return CitationHostingView(citationData: element.citationData)
    }
    
    /// Check if dictionary contains valid citation data
    @objc public static func isValidCitationData(_ dict: [String: Any]) -> Bool {
        return SwiftCitationElement.parse(from: dict) != nil
    }
}

// MARK: - Helper Extensions

@available(iOS 15.0, *)
extension CitationHostingView {
    
    /// Get the underlying SwiftUI view (for debugging)
    var swiftUIView: UIHostingController<AnyView>? {
        return hostingController
    }
    
    /// Force refresh the view
    @objc public func refresh() {
        notifyHeightChange()
    }
}

// MARK: - Objective-C Factory

/// Factory class for creating Citation views from Objective-C
/// This follows the same pattern as ChainOfThoughtViewFactory
@objc(CitationViewFactory)
public class CitationViewFactory: NSObject {
    
    /// Creates a citation hosting view from a dictionary
    /// Expected format: {"type": "Citation", "referenceId": 1, "displayText": "[1]", "citation": {...}}
    @objc public static func createCitationView(from dictionary: [String: Any]) -> UIView? {
        ACDiagnosticLogger.log("Factory called to create citation view", category: "Citation")
        
        guard #available(iOS 15.0, *) else {
            ACDiagnosticLogger.log("iOS 15.0+ required for citations", category: "Error")
            return nil
        }
        
        return CitationHostingView.createFromDictionary(dictionary)
    }
    
    /// Creates citation view from Objective-C bridge
    @objc public static func createCitationViewFromBridge(_ bridge: SwiftCitationDataBridge) -> UIView? {
        guard #available(iOS 15.0, *) else {
            ACDiagnosticLogger.log("iOS 15.0+ required for citations", category: "Error")
            return nil
        }
        
        return CitationHostingView(bridge: bridge)
    }
    
    /// Checks if the given dictionary contains valid citation data
    @objc public static func isValidCitation(_ dictionary: [String: Any]) -> Bool {
        guard #available(iOS 15.0, *) else { return false }
        return CitationHostingView.isValidCitationData(dictionary)
    }
}
