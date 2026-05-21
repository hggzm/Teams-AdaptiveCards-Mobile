// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VisualSnapshotTests",
    platforms: [.iOS(.v13)],
    targets: [
        .testTarget(
            name: "VisualSnapshotTests",
            path: ".",
            exclude: [
                "run_snapshot_tests.sh",
                "Package.swift"
            ],
            sources: [
                "SnapshotTesting/SnapshotTestCase.swift",
                "Tests/AccessibilitySnapshotTests.swift",
                "Tests/CardLayoutSnapshotTests.swift",
                "Tests/A11yInteractionSnapshotTests.swift",
                "Tests/DiagStackedActionsetTests.swift"
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
