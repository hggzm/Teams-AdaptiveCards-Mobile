// swift-tools-version:6.0
import PackageDescription

// Mandatory runtime symbol-check example for ios-swift-swiftag.
// Consumes the vendored SwiftAg package via a relative path so this
// example builds and runs on the proxy-only CI without any remote
// SwiftPM resolution.
let package = Package(
    name: "adaptivecards-swiftag-demo",
    platforms: [
        .iOS(.v15), .macOS(.v12), .tvOS(.v15),
        .watchOS(.v8), .visionOS(.v1),
    ],
    dependencies: [
        .package(name: "swiftag", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "adaptivecards-swiftag-demo",
            dependencies: [
                .product(name: "SwiftAg", package: "swiftag"),
            ],
            path: "Sources/AdaptiveCardsDemo"
        ),
    ]
)
