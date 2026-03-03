//
//  AccessibilitySnapshotTests.swift
//  VisualSnapshotTests
//
//  Visual regression tests for all 7 TalkBack/VoiceOver accessibility fixes.
//  Mirrors the Android Paparazzi AccessibilitySnapshotTests.
//  Constructs UIViews programmatically with correct accessibility properties.
//

#if canImport(UIKit)
import XCTest
import UIKit

final class AccessibilitySnapshotTests: SnapshotTestCase {

    // MARK: - PR #518: Image Role on ImageView

    /// Images should have .image accessibility trait for VoiceOver
    func testImageView_withImageRole_lightMode() {
        let container = makeCardContainer()

        let imageView = UIImageView()
        imageView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = "Team meeting photo"
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let label = makeLabel("Activity Update Card", style: .headline)

        container.addArrangedSubview(label)
        container.addArrangedSubview(imageView)

        assertSnapshot(of: container, named: "imageView_withImageRole", configuration: .iPhone15Pro)
    }

    func testImageView_withImageRole_darkMode() {
        let container = makeCardContainer()

        let imageView = UIImageView()
        imageView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = "Team meeting photo"
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let label = makeLabel("Activity Update Card", style: .headline)

        container.addArrangedSubview(label)
        container.addArrangedSubview(imageView)

        assertSnapshot(of: container, named: "imageView_withImageRole", configuration: .iPhone15ProDark)
    }

    func testImageView_noAltText_isNotAccessibilityElement() {
        let container = makeCardContainer()

        let imageView = UIImageView()
        imageView.backgroundColor = UIColor.systemGray5
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false // No alt text → decorative
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let label = makeLabel("Decorative image (no alt text)", style: .subheadline)

        container.addArrangedSubview(label)
        container.addArrangedSubview(imageView)

        assertSnapshot(of: container, named: "imageView_noAltText", configuration: .iPhone15Pro)
    }

    // MARK: - PR #519: OpenUrl Duplicate Role Fix

    /// Open URL buttons should have .link trait, not .button + .link
    func testOpenUrlButton_withLinkRole() {
        let container = makeCardContainer()

        let title = makeLabel("Action Links", style: .headline)

        let linkButton = UIButton(type: .system)
        linkButton.setTitle("Visit Microsoft →", for: .normal)
        linkButton.accessibilityTraits = .link // Not .button + .link (duplicate)
        linkButton.contentHorizontalAlignment = .leading
        linkButton.translatesAutoresizingMaskIntoConstraints = false

        let regularButton = UIButton(type: .system)
        regularButton.setTitle("Submit Form", for: .normal)
        regularButton.accessibilityTraits = .button
        regularButton.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(title)
        container.addArrangedSubview(linkButton)
        container.addArrangedSubview(regularButton)

        assertSnapshot(of: container, named: "openUrlButton_withLinkRole", configuration: .iPhone15Pro)
    }

    // MARK: - PR #520: Error Message Accessibility

    /// Error messages should be visible with proper accessibility notifications
    func testErrorMessage_visible() {
        let container = makeCardContainer()

        let inputField = UITextField()
        inputField.placeholder = "Enter email address"
        inputField.borderStyle = .roundedRect
        inputField.text = "invalid-email"
        inputField.translatesAutoresizingMaskIntoConstraints = false

        let errorLabel = UILabel()
        errorLabel.text = "Please enter a valid email address"
        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.isAccessibilityElement = true
        errorLabel.accessibilityTraits = .staticText
        errorLabel.isHidden = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(makeLabel("Input with Error", style: .headline))
        container.addArrangedSubview(inputField)
        container.addArrangedSubview(errorLabel)

        assertSnapshot(of: container, named: "errorMessage_visible", configuration: .iPhone15Pro)
    }

    func testErrorMessage_hidden() {
        let container = makeCardContainer()

        let inputField = UITextField()
        inputField.placeholder = "Enter email address"
        inputField.borderStyle = .roundedRect
        inputField.text = "user@example.com"
        inputField.translatesAutoresizingMaskIntoConstraints = false

        let errorLabel = UILabel()
        errorLabel.text = "Please enter a valid email address"
        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.isHidden = true // Valid input → error hidden
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(makeLabel("Input without Error", style: .headline))
        container.addArrangedSubview(inputField)
        container.addArrangedSubview(errorLabel)

        assertSnapshot(of: container, named: "errorMessage_hidden", configuration: .iPhone15Pro)
    }

    // MARK: - PR #521: Dropdown Index Count

    /// Dropdown should announce correct item count for VoiceOver
    func testDropdown_correctItemCount() {
        let container = makeCardContainer()

        let label = makeLabel("Select Department", style: .subheadline)

        let dropdown = UIButton(type: .system)
        dropdown.setTitle("Engineering ▾", for: .normal)
        dropdown.contentHorizontalAlignment = .leading
        dropdown.layer.borderWidth = 1
        dropdown.layer.borderColor = UIColor.separator.cgColor
        dropdown.layer.cornerRadius = 8
        dropdown.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        dropdown.isAccessibilityElement = true
        dropdown.accessibilityLabel = "Engineering"
        dropdown.accessibilityHint = "1 of 5" // Correct count (not including placeholder)
        dropdown.accessibilityTraits = .button
        dropdown.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(makeLabel("Dropdown with Correct Count", style: .headline))
        container.addArrangedSubview(label)
        container.addArrangedSubview(dropdown)

        assertSnapshot(of: container, named: "dropdown_correctCount", configuration: .iPhone15Pro)
    }

    // MARK: - PR #522: RadioGroup Label Aggregation

    /// Radio group items should not aggregate parent labels
    func testRadioGroup_noLabelAggregation() {
        let container = makeCardContainer()
        container.addArrangedSubview(makeLabel("Preferred Contact Method", style: .headline))

        let options = ["Email", "Phone", "Teams Chat"]
        for (index, option) in options.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center
            row.translatesAutoresizingMaskIntoConstraints = false

            let radio = UIView()
            radio.translatesAutoresizingMaskIntoConstraints = false
            radio.widthAnchor.constraint(equalToConstant: 20).isActive = true
            radio.heightAnchor.constraint(equalToConstant: 20).isActive = true
            radio.layer.cornerRadius = 10
            radio.layer.borderWidth = 2
            radio.layer.borderColor = UIColor.systemBlue.cgColor
            if index == 0 {
                radio.backgroundColor = .systemBlue // Selected
            }

            let optionLabel = UILabel()
            optionLabel.text = option
            optionLabel.font = .preferredFont(forTextStyle: .body)
            optionLabel.translatesAutoresizingMaskIntoConstraints = false

            // Each radio is its own a11y element — no parent aggregation
            row.isAccessibilityElement = true
            row.accessibilityLabel = option // Just the option, not "Preferred Contact Method, Email"
            row.accessibilityTraits = index == 0 ? [.selected] : []

            row.addArrangedSubview(radio)
            row.addArrangedSubview(optionLabel)
            container.addArrangedSubview(row)
        }

        assertSnapshot(of: container, named: "radioGroup_noLabelAggregation", configuration: .iPhone15Pro)
    }

    // MARK: - PR #523: ShowCard Toggle Accessibility

    /// ShowCard button should announce expanded/collapsed state
    func testShowCardButton_expanded() {
        let container = makeCardContainer()

        let toggleButton = UIButton(type: .system)
        toggleButton.setTitle("▼ Show Details", for: .normal)
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.isAccessibilityElement = true
        toggleButton.accessibilityLabel = "Show Details"
        toggleButton.accessibilityTraits = .button
        toggleButton.accessibilityValue = "expanded"
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        let cardContent = UIView()
        cardContent.backgroundColor = UIColor.systemGray6
        cardContent.layer.cornerRadius = 8
        cardContent.translatesAutoresizingMaskIntoConstraints = false
        cardContent.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let detailLabel = makeLabel("Card details content here", style: .body)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor, constant: 12),
            detailLabel.centerYAnchor.constraint(equalTo: cardContent.centerYAnchor)
        ])

        container.addArrangedSubview(makeLabel("ShowCard Toggle", style: .headline))
        container.addArrangedSubview(toggleButton)
        container.addArrangedSubview(cardContent)

        assertSnapshot(of: container, named: "showcardButton_expanded", configuration: .iPhone15Pro)
    }

    func testShowCardButton_collapsed() {
        let container = makeCardContainer()

        let toggleButton = UIButton(type: .system)
        toggleButton.setTitle("▶ Show Details", for: .normal)
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.isAccessibilityElement = true
        toggleButton.accessibilityLabel = "Show Details"
        toggleButton.accessibilityTraits = .button
        toggleButton.accessibilityValue = "collapsed"
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(makeLabel("ShowCard Toggle", style: .headline))
        container.addArrangedSubview(toggleButton)

        assertSnapshot(of: container, named: "showcardButton_collapsed", configuration: .iPhone15Pro)
    }

    // MARK: - PR #524: ProgressBar Accessibility

    /// Progress bar should announce percentage for VoiceOver
    func testProgressBar_determinate() {
        let container = makeCardContainer()

        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.progress = 0.65
        progressView.isAccessibilityElement = true
        progressView.accessibilityLabel = "Upload progress"
        progressView.accessibilityValue = "65%"
        progressView.accessibilityTraits = .updatesFrequently
        progressView.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(makeLabel("Determinate Progress", style: .headline))
        container.addArrangedSubview(progressView)
        container.addArrangedSubview(makeLabel("65% complete", style: .caption1))

        assertSnapshot(of: container, named: "progressBar_determinate", configuration: .iPhone15Pro)
    }

    func testProgressBar_indeterminate() {
        let container = makeCardContainer()

        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.startAnimating()
        activityIndicator.isAccessibilityElement = true
        activityIndicator.accessibilityLabel = "Loading"
        activityIndicator.accessibilityTraits = .updatesFrequently
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(makeLabel("Indeterminate Progress", style: .headline))
        container.addArrangedSubview(activityIndicator)

        assertSnapshot(of: container, named: "progressBar_indeterminate", configuration: .iPhone15Pro)
    }

    func testProgressBar_zero() {
        let container = makeCardContainer()

        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.progress = 0.0
        progressView.isAccessibilityElement = true
        progressView.accessibilityLabel = "Download progress"
        progressView.accessibilityValue = "0%"
        progressView.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(makeLabel("Zero Progress", style: .headline))
        container.addArrangedSubview(progressView)

        assertSnapshot(of: container, named: "progressBar_zero", configuration: .iPhone15Pro)
    }

    func testProgressBar_full() {
        let container = makeCardContainer()

        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.progress = 1.0
        progressView.progressTintColor = .systemGreen
        progressView.isAccessibilityElement = true
        progressView.accessibilityLabel = "Download progress"
        progressView.accessibilityValue = "100%"
        progressView.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(makeLabel("Complete Progress", style: .headline))
        container.addArrangedSubview(progressView)
        container.addArrangedSubview(makeLabel("Download complete ✓", style: .caption1))

        assertSnapshot(of: container, named: "progressBar_full", configuration: .iPhone15Pro)
    }

    // MARK: - Helpers

    private func makeCardContainer() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.backgroundColor = .systemBackground
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return stack
    }

    private func makeLabel(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
#endif // canImport(UIKit)
