// swift-tools-version:6.0
//
// examples/adaptivecards-swiftbox-demo/Package.swift
//
// Runtime symbol-check example for the vendored swiftbox kit. Flavor A
// ("store"): bootstrap a swiftbox in-process sandbox, store the canonical
// AdaptiveCards.io "Hello World" sample card in the VirtualFileSystem, read it
// back through the filesystem API and the Shell `cat` builtin, assert byte-equal.
//
// Path-deps the vendored kit at ../.. via SwiftPM's `path:` dep. SwiftboxCore
// has no external package dependencies, so there is nothing else to declare.

import PackageDescription

let package = Package(
    name: "AdaptiveCardsSwiftboxDemo",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "AdaptiveCardsDemo", targets: ["AdaptiveCardsDemo"]),
    ],
    dependencies: [
        .package(name: "Swiftbox", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AdaptiveCardsDemo",
            dependencies: [
                .product(name: "SwiftboxCore", package: "Swiftbox"),
            ]
        ),
    ]
)
