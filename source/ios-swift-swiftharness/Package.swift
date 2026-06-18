// swift-tools-version:5.9
//
// SwiftHarness bridge — vendored snapshot of hggz/swiftharness.
//
// Vendored 2026-05-28. This subfolder inherits the repo-root MIT
// license; no nested LICENSE file is shipped. No private commit
// SHAs / branch names are referenced.
//
// Original swiftharness layout had seven targets (Core, Tools,
// Commands, Session, Runtime, CLI library, CLI executable). For
// the bridge drop we vendor only the four library targets needed
// to exercise SessionStore against an AdaptiveCard payload:
//
//   SwiftHarnessCore     — IDs, prompts, errors, token estimator
//   SwiftHarnessTools    — Tool registry + permission policy
//   SwiftHarnessCommands — Command registry (seeded review/agents/setup)
//   SwiftHarnessSession  — Session/Transcript models + SessionStore actor
//
// `platforms:` narrows minimum Apple OS versions only. Linux and
// Windows build with no platform clause.

import PackageDescription

let package = Package(
    name: "swiftharness-bridge",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftHarnessCore",     targets: ["SwiftHarnessCore"]),
        .library(name: "SwiftHarnessTools",    targets: ["SwiftHarnessTools"]),
        .library(name: "SwiftHarnessCommands", targets: ["SwiftHarnessCommands"]),
        .library(name: "SwiftHarnessSession",  targets: ["SwiftHarnessSession"]),
    ],
    targets: [
        .target(
            name: "SwiftHarnessCore",
            path: "Sources/SwiftHarnessCore"
        ),
        .target(
            name: "SwiftHarnessTools",
            dependencies: ["SwiftHarnessCore"],
            path: "Sources/SwiftHarnessTools"
        ),
        .target(
            name: "SwiftHarnessCommands",
            dependencies: ["SwiftHarnessCore"],
            path: "Sources/SwiftHarnessCommands"
        ),
        .target(
            name: "SwiftHarnessSession",
            dependencies: ["SwiftHarnessCore"],
            path: "Sources/SwiftHarnessSession"
        ),
    ]
)
