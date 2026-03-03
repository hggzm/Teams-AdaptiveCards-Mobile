//
//  CardLayoutSnapshotTests.swift
//  VisualSnapshotTests
//
//  Visual regression tests for complete card layouts.
//  Constructs multi-component card UIs matching typical Adaptive Card patterns.
//

#if canImport(UIKit)
import XCTest
import UIKit

final class CardLayoutSnapshotTests: SnapshotTestCase {

    // MARK: - Activity Update Card

    func testActivityUpdateCard() {
        let card = makeCardContainer()

        // Header row: avatar + text
        let header = UIStackView()
        header.axis = .horizontal
        header.spacing = 12
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false

        let avatar = UIView()
        avatar.backgroundColor = .systemBlue
        avatar.layer.cornerRadius = 20
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 40).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        avatar.isAccessibilityElement = true
        avatar.accessibilityTraits = .image
        avatar.accessibilityLabel = "Matt Hidinger"

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(makeLabel("Matt Hidinger", style: .headline))
        textStack.addArrangedSubview(makeLabel("Created a new adaptive card", style: .subheadline))

        header.addArrangedSubview(avatar)
        header.addArrangedSubview(textStack)

        // Hero image
        let heroImage = UIView()
        heroImage.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.2)
        heroImage.layer.cornerRadius = 8
        heroImage.translatesAutoresizingMaskIntoConstraints = false
        heroImage.heightAnchor.constraint(equalToConstant: 180).isActive = true
        heroImage.isAccessibilityElement = true
        heroImage.accessibilityTraits = .image
        heroImage.accessibilityLabel = "Adaptive Cards hero image"

        // Action buttons
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 12
        actions.distribution = .fillEqually
        actions.translatesAutoresizingMaskIntoConstraints = false

        let viewButton = makeActionButton("View", trait: .link)
        let commentButton = makeActionButton("Comment", trait: .button)
        actions.addArrangedSubview(viewButton)
        actions.addArrangedSubview(commentButton)

        card.addArrangedSubview(header)
        card.addArrangedSubview(heroImage)
        card.addArrangedSubview(actions)

        assertSnapshots(of: card, named: "activityUpdateCard", configurations: SnapshotConfiguration.core)
    }

    // MARK: - Input Form Card

    func testInputFormCard() {
        let card = makeCardContainer()

        card.addArrangedSubview(makeLabel("Submit Expense Report", style: .title2))
        card.addArrangedSubview(makeTextField(placeholder: "Description", text: "Team lunch"))
        card.addArrangedSubview(makeTextField(placeholder: "Amount ($)", text: "45.00"))

        // Category dropdown
        let categoryLabel = makeLabel("Category", style: .subheadline)
        let dropdown = UIButton(type: .system)
        dropdown.setTitle("Food & Dining ▾", for: .normal)
        dropdown.contentHorizontalAlignment = .leading
        dropdown.layer.borderWidth = 1
        dropdown.layer.borderColor = UIColor.separator.cgColor
        dropdown.layer.cornerRadius = 8
        dropdown.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        dropdown.accessibilityLabel = "Food & Dining"
        dropdown.accessibilityHint = "2 of 6"
        dropdown.translatesAutoresizingMaskIntoConstraints = false

        // Error message (visible)
        let errorLabel = UILabel()
        errorLabel.text = "Receipt is required for amounts over $25"
        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.isAccessibilityElement = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let submitButton = makeActionButton("Submit", trait: .button)

        card.addArrangedSubview(categoryLabel)
        card.addArrangedSubview(dropdown)
        card.addArrangedSubview(errorLabel)
        card.addArrangedSubview(submitButton)

        assertSnapshot(of: card, named: "inputFormCard", configuration: .iPhone15Pro)
    }

    // MARK: - Poll Results Card

    func testPollResultsCard() {
        let card = makeCardContainer()

        card.addArrangedSubview(makeLabel("Sprint Retrospective Poll", style: .title2))
        card.addArrangedSubview(makeLabel("What should we focus on next sprint?", style: .body))

        let options = [
            ("Performance", 0.45, true),
            ("Accessibility", 0.30, false),
            ("New Features", 0.25, false)
        ]

        for (name, progress, selected) in options {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center
            row.translatesAutoresizingMaskIntoConstraints = false
            row.isAccessibilityElement = true
            row.accessibilityLabel = name
            row.accessibilityTraits = selected ? [.selected] : []

            let radio = UIView()
            radio.translatesAutoresizingMaskIntoConstraints = false
            radio.widthAnchor.constraint(equalToConstant: 18).isActive = true
            radio.heightAnchor.constraint(equalToConstant: 18).isActive = true
            radio.layer.cornerRadius = 9
            radio.layer.borderWidth = 2
            radio.layer.borderColor = UIColor.systemBlue.cgColor
            if selected { radio.backgroundColor = .systemBlue }

            let label = makeLabel(name, style: .body)

            let progressView = UIProgressView(progressViewStyle: .default)
            progressView.progress = Float(progress)
            progressView.accessibilityValue = "\(Int(progress * 100))%"
            progressView.translatesAutoresizingMaskIntoConstraints = false

            let pctLabel = makeLabel("\(Int(progress * 100))%", style: .caption1)
            pctLabel.setContentHuggingPriority(.required, for: .horizontal)

            row.addArrangedSubview(radio)
            row.addArrangedSubview(label)
            row.addArrangedSubview(progressView)
            row.addArrangedSubview(pctLabel)

            card.addArrangedSubview(row)
        }

        assertSnapshot(of: card, named: "pollResultsCard", configuration: .iPhone15Pro)
    }

    // MARK: - ShowCard Interaction Card

    func testShowCardInteractionCard() {
        let card = makeCardContainer()

        card.addArrangedSubview(makeLabel("Meeting Notes", style: .title2))
        card.addArrangedSubview(makeLabel("Sprint planning — March 2, 2026", style: .subheadline))

        // Collapsed ShowCard button
        let showDetailsButton = UIButton(type: .system)
        showDetailsButton.setTitle("▶ Show Attendees", for: .normal)
        showDetailsButton.contentHorizontalAlignment = .leading
        showDetailsButton.accessibilityLabel = "Show Attendees"
        showDetailsButton.accessibilityValue = "collapsed"
        showDetailsButton.translatesAutoresizingMaskIntoConstraints = false

        // Expanded ShowCard button
        let showNotesButton = UIButton(type: .system)
        showNotesButton.setTitle("▼ Show Action Items", for: .normal)
        showNotesButton.contentHorizontalAlignment = .leading
        showNotesButton.accessibilityLabel = "Show Action Items"
        showNotesButton.accessibilityValue = "expanded"
        showNotesButton.translatesAutoresizingMaskIntoConstraints = false

        // Expanded content
        let expandedContent = UIView()
        expandedContent.backgroundColor = UIColor.systemGray6
        expandedContent.layer.cornerRadius = 8
        expandedContent.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(makeLabel("• Fix image a11y traits", style: .body))
        contentStack.addArrangedSubview(makeLabel("• Add snapshot tests", style: .body))
        contentStack.addArrangedSubview(makeLabel("• Update documentation", style: .body))

        expandedContent.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: expandedContent.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: expandedContent.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: expandedContent.trailingAnchor, constant: -12),
            contentStack.bottomAnchor.constraint(equalTo: expandedContent.bottomAnchor, constant: -12)
        ])

        card.addArrangedSubview(showDetailsButton)
        card.addArrangedSubview(showNotesButton)
        card.addArrangedSubview(expandedContent)

        assertSnapshot(of: card, named: "showcardInteractionCard", configuration: .iPhone15Pro)
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

    private func makeTextField(placeholder: String, text: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.text = text
        field.borderStyle = .roundedRect
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeActionButton(_ title: String, trait: UIAccessibilityTraits) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityTraits = trait
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}
#endif // canImport(UIKit)
