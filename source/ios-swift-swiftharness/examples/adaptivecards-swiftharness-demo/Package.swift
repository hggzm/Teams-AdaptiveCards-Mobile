// swift-tools-version:5.9
//
// adaptivecards-swiftharness-demo — runtime symbol-check example.
//
// Stand-alone SwiftPM package that consumes the vendored swiftharness
// snapshot via a path dependency on the bridge subfolder and
// exercises ≥3 distinct symbols from the vendored kit against the
// canonical AdaptiveCards.io "Hello world" sample card.
//
// Per the addendum: this package's smoke runner is gated by CI and
// must print `PASS adaptivecards-swiftharness-roundtrip` on stdout
// when the round-trip succeeds.

import PackageDescription

let package = Package(
    name: "adaptivecards-swiftharness-demo",
    platforms: [
        .macOS(.v12),
    ],
    dependencies: [
        // Path back to the vendored swiftharness bridge.
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AdaptiveCardsDemo",
            dependencies: [
                .product(name: "SwiftHarnessCore",
                         package: "ios-swift-swiftharness"),
                .product(name: "SwiftHarnessSession",
                         package: "ios-swift-swiftharness"),
            ],
            path: "Sources/AdaptiveCardsDemo"
        ),
    ]
)
