// swift-tools-version:6.0
//
// examples/adaptivecards-swiftsync-demo/Package.swift
//
// Runtime symbol-check example for the vendored SwiftSyncCore kit. Flavor A
// ("store / round-trip"): sync the canonical adaptivecards.io "Hello World"
// sample card from a temp source directory into a temp destination directory
// via the public `Syncer` API, read it back, and assert byte-equal.
//
// Path-deps the vendored kit at ../.. . SwiftSyncCore is pure Foundation with no
// external package dependencies, so there is no substrate to mirror here.

import PackageDescription

let package = Package(
    name: "AdaptiveCardsSwiftSyncDemo",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "AdaptiveCardsDemo", targets: ["AdaptiveCardsDemo"]),
    ],
    dependencies: [
        // Path-dep on the vendored kit.
        .package(name: "SwiftSyncCore", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AdaptiveCardsDemo",
            dependencies: [
                .product(name: "SwiftSyncCore", package: "SwiftSyncCore"),
            ]
        ),
    ]
)
