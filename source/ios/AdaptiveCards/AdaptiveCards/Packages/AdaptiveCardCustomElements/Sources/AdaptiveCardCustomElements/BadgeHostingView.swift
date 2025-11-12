//
//  BadgeHostingView.swift
//  AdaptiveCardCustomElements
//
//  UIKit bridge for BadgeView using UIHostingController
//

import UIKit
import SwiftUI

/// UIView wrapper for BadgeView using UIHostingController
public class BadgeHostingView: UIView {
    private let hostingController: UIHostingController<BadgeView>
    
    public init(data: BadgeData) {
        let badgeView = BadgeView(data: data)
        self.hostingController = UIHostingController(rootView: badgeView)
        
        super.init(frame: .zero)
        
        setupHostingController()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupHostingController() {
        // Configure hosting controller
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        
        // Add to view hierarchy
        addSubview(hostingController.view)
        
        // Setup constraints
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        
        // Set content hugging and compression resistance
        hostingController.view.setContentHuggingPriority(.required, for: .horizontal)
        hostingController.view.setContentHuggingPriority(.required, for: .vertical)
        hostingController.view.setContentCompressionResistancePriority(.required, for: .horizontal)
        hostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    public override var intrinsicContentSize: CGSize {
        return hostingController.view.intrinsicContentSize
    }
}

/// Factory for creating BadgeHostingView instances
@objc public class BadgeViewFactory: NSObject {
    
    /// Create a UIView for a Badge element
    /// - Parameter bridgeData: Badge data from Objective-C bridge
    /// - Returns: UIView instance displaying the badge
    @objc public static func createView(with bridgeData: BadgeDataBridge) -> UIView {
        let data = bridgeData.toBadgeData()
        return BadgeHostingView(data: data)
    }
}
