//
//  ProgressBarHostingView.swift
//  AdaptiveCardCustomElements
//
//  UIKit bridge for ProgressBarView using UIHostingController
//

import UIKit
import SwiftUI

/// UIView wrapper for ProgressBarView using UIHostingController
public class ProgressBarHostingView: UIView {
    private let hostingController: UIHostingController<ProgressBarView>
    
    public init(data: ProgressBarData) {
        let progressBarView = ProgressBarView(data: data)
        self.hostingController = UIHostingController(rootView: progressBarView)
        
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
    
    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        return hostingController.view.sizeThatFits(size)
    }
    
    public override var intrinsicContentSize: CGSize {
        return hostingController.view.intrinsicContentSize
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        hostingController.view.frame = bounds
    }
}

/// Factory for creating ProgressBar views
@objc public class ProgressBarViewFactory: NSObject {
    @objc public static func createView(with data: ProgressBarDataBridge) -> UIView {
        let progressBarData = ProgressBarData(progress: data.progress, label: data.label)
        return ProgressBarHostingView(data: progressBarData)
    }
}
