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
                "Snapshots",
                "run_snapshot_tests.sh",
                "Package.swift"
            ],
            sources: [
                "SnapshotTesting/SnapshotTestCase.swift",
                "Tests/AccessibilitySnapshotTests.swift",
                "Tests/CardLayoutSnapshotTests.swift"
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
