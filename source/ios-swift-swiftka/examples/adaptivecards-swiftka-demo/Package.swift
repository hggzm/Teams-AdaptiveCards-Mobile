// swift-tools-version:5.9
import PackageDescription

// proxy-only — symbol-check example for the vendored swiftka kit.
// Path-deps the kit at ../.. so CI links against the vendored
// snapshot rather than any external SwiftPM resolution.

let package = Package(
    name: "adaptivecards-swiftka-demo",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .executable(name: "adaptivecards-swiftka-demo", targets: ["AdaptiveCardsDemo"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AdaptiveCardsDemo",
            dependencies: [
                .product(name: "SwiftKaKit",    package: "ios-swift-swiftka"),
                .product(name: "SwiftKaBridge", package: "ios-swift-swiftka"),
            ],
            path: "Sources/AdaptiveCardsDemo"
        ),
    ]
)
