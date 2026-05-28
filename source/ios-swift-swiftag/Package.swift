// swift-tools-version:6.0
import PackageDescription

// `platforms` only narrows minimum versions for Apple platforms. Linux,
// Windows, Android, and any other Swift-supported target build with no
// platform clause — so we deliberately do NOT restrict to Apple here.
let package = Package(
    name: "swiftag",
    platforms: [
        .iOS(.v15), .macOS(.v12), .tvOS(.v15),
        .watchOS(.v8), .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftAg", targets: ["SwiftAg"]),
        .library(name: "SwiftAgProvidersOpenAI", targets: ["SwiftAgProvidersOpenAI"]),
        .library(name: "SwiftAgProvidersAnthropic", targets: ["SwiftAgProvidersAnthropic"]),
        .executable(name: "swiftag-demo", targets: ["swiftag-demo"]),
    ],
    targets: [
        .target(
            name: "SwiftAg",
            path: "Sources/SwiftAg"
        ),
        .target(
            name: "SwiftAgProvidersOpenAI",
            dependencies: ["SwiftAg"],
            path: "Sources/SwiftAgProvidersOpenAI"
        ),
        .target(
            name: "SwiftAgProvidersAnthropic",
            dependencies: ["SwiftAg"],
            path: "Sources/SwiftAgProvidersAnthropic"
        ),
        .executableTarget(
            name: "swiftag-demo",
            dependencies: ["SwiftAg", "SwiftAgProvidersOpenAI"],
            path: "Sources/swiftag-demo"
        ),
        .testTarget(
            name: "SwiftAgTests",
            dependencies: ["SwiftAg", "SwiftAgProvidersOpenAI"],
            path: "Tests/SwiftAgTests"
        ),
    ]
)
