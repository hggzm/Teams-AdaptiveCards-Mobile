// swift-tools-version:6.0
// adaptivecards-swiftoauth-demo
// Runtime symbol-check example for the vendored swiftoauth kit.
// Inherits the repo-root MIT license.

import PackageDescription

let package = Package(
    name: "adaptivecards-swiftoauth-demo",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .executable(name: "AdaptiveCardsDemo", targets: ["AdaptiveCardsDemo"]),
    ],
    dependencies: [
        // Path-dep on the vendored swiftoauth snapshot one folder up.
        .package(path: "../.."),

        // SwiftPM's fork-over-upstream identity override only takes effect from
        // the ROOT package being built. Here the ROOT is this demo, which only
        // path-deps the kit; the kit's Hummingbird transitively pulls
        // apple/swift-nio, which fails to compile on Windows. Re-declaring the
        // public hggz Windows-supported forks here (same revisions the kit
        // pins) makes this demo's resolution authoritative so the forks win.
        // They are public HTTPS remotes (no SSH URLs) and carry no target
        // dependency — declaring them is enough to steer identity resolution.
        .package(url: "https://github.com/hggz/hummingbird.git",
                 revision: "3e8921437eb791e06662d9f8cbfcd55f18c4759a"),
        .package(url: "https://github.com/hggz/swift-nio.git",
                 revision: "7c9c6861c968f8902c0610ab4ba2e23311f5092c"),
        .package(url: "https://github.com/hggz/swift-nio-extras.git",
                 revision: "076c9b493c6fe365ba42663fc16c4239d17dfb92"),
    ],
    targets: [
        .executableTarget(
            name: "AdaptiveCardsDemo",
            dependencies: [
                // SwiftPM identifies a `path:` dependency by the folder
                // basename ("ios-swift-swiftoauth") rather than the manifest's
                // `name:` ("swiftoauth"), so reference the package by its
                // on-disk folder name here.
                .product(name: "SwiftOAuthCore", package: "ios-swift-swiftoauth"),
                .product(name: "SwiftOAuthServer", package: "ios-swift-swiftoauth"),
            ]
        ),
    ]
)
