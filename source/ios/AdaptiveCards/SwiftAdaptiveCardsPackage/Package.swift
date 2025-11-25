// swift-tools-version:5.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftAdaptiveCards",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftAdaptiveCards",
            targets: ["SwiftAdaptiveCards"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftAdaptiveCards",
            dependencies: [],
            path: "Sources/SwiftAdaptiveCards"
        ),
    ]
)
