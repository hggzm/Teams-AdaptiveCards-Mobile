// swift-tools-version:6.0
// adaptivecards-swiftpi-demo
// Runtime symbol-check example for the vendored swiftpi kit.
// Inherits the repo-root MIT license.

import PackageDescription

let package = Package(
    name: "adaptivecards-swiftpi-demo",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .executable(name: "AdaptiveCardsDemo", targets: ["AdaptiveCardsDemo"]),
    ],
    dependencies: [
        // Path-dep on the vendored swiftpi snapshot one folder up.
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AdaptiveCardsDemo",
            dependencies: [
                // SwiftPM identifies a `path:` dependency by the
                // folder basename ("ios-swift-swiftpi") rather than
                // the manifest's `name:` ("swiftpi"), so reference
                // the package by its on-disk folder name here.
                .product(name: "SwiftPiCore", package: "ios-swift-swiftpi"),
            ]
        ),
    ]
)
