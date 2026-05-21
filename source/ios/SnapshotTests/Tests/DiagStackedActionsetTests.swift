//
//  DiagStackedActionsetTests.swift
//  VisualSnapshotTests
//
//  Diagnostic-shape preview tests for the stacked-ActionSet symptom.
//
//  These tests do NOT render Adaptive Cards JSON through the SDK (the SPM
//  snapshot target does not link the AdaptiveCards framework). Instead they
//  construct synthetic UIKit views that approximate the SHAPE of each
//  variant so the relative layouts can be inspected side-by-side.
//
//  Variant key:
//    A control  : 4 ActionSets stacked (10 buttons total) + msteams.width Full
//    B no width : 4 ActionSets stacked (10 buttons total) without msteams.width
//    C single   : 1 ActionSet with 1 button (collapsed)
//    D v1.5     : same layout as A; the schema version bump is invisible at this layer
//
//  Artifacts land in Snapshots/Baselines/ as diag_stacked_*_iPhone15Pro_light.png
//  and are uploaded by agent-gate.yml inside the ios-snapshot-baselines artifact.
//

#if canImport(UIKit)
import XCTest
import UIKit

final class DiagStackedActionsetTests: SnapshotTestCase {

    func testDiagStacked_A_control_4ActionSetsFullWidth() {
        let card = makeContainer(fullWidth: true)
        card.addArrangedSubview(makeLabel("Stacked ActionSet repro - variant A control", style: .headline))
        addActionSet(to: card, titles: ["Mark timestamp", "Skip", "Notify"])
        addActionSet(to: card, titles: ["Add note", "Add comment"])
        addActionSet(to: card, titles: ["Open form 1", "Open form 2", "Open form 3"])
        addActionSet(to: card, titles: ["Submit", "Reset"])
        assertSnapshot(of: card, named: "diag_stacked_A_control", configuration: .iPhone15Pro)
    }

    func testDiagStacked_B_noMsteamsWidth() {
        let card = makeContainer(fullWidth: false)
        card.addArrangedSubview(makeLabel("Stacked ActionSet repro - variant B no msteams.width", style: .headline))
        addActionSet(to: card, titles: ["Mark timestamp", "Skip", "Notify"])
        addActionSet(to: card, titles: ["Add note", "Add comment"])
        addActionSet(to: card, titles: ["Open form 1", "Open form 2", "Open form 3"])
        addActionSet(to: card, titles: ["Submit", "Reset"])
        assertSnapshot(of: card, named: "diag_stacked_B_noWidth", configuration: .iPhone15Pro)
    }

    func testDiagStacked_C_singleActionSet() {
        let card = makeContainer(fullWidth: true)
        card.addArrangedSubview(makeLabel("Stacked ActionSet repro - variant C single ActionSet", style: .headline))
        addActionSet(to: card, titles: ["Mark timestamp"])
        assertSnapshot(of: card, named: "diag_stacked_C_single", configuration: .iPhone15Pro)
    }

    func testDiagStacked_D_v15Layout() {
        let card = makeContainer(fullWidth: true)
        card.addArrangedSubview(makeLabel("Stacked ActionSet repro - variant D v1.5 (layout identical to A)", style: .headline))
        addActionSet(to: card, titles: ["Mark timestamp", "Skip", "Notify"])
        addActionSet(to: card, titles: ["Add note", "Add comment"])
        addActionSet(to: card, titles: ["Open form 1", "Open form 2", "Open form 3"])
        addActionSet(to: card, titles: ["Submit", "Reset"])
        assertSnapshot(of: card, named: "diag_stacked_D_v15", configuration: .iPhone15Pro)
    }

    // MARK: - Helpers (local copies to avoid cross-class private dependency)

    private func makeContainer(fullWidth: Bool) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.backgroundColor = .systemBackground
        stack.translatesAutoresizingMaskIntoConstraints = false
        let w: CGFloat = fullWidth ? 393 : 320
        stack.widthAnchor.constraint(equalToConstant: w).isActive = true
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

    private func addActionSet(to card: UIStackView, titles: [String]) {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        for title in titles {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
            b.layer.cornerRadius = 6
            b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            b.accessibilityTraits = .button
            b.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(b)
        }
        card.addArrangedSubview(row)
    }
}

#endif // canImport(UIKit)
