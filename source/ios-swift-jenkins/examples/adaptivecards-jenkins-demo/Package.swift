// swift-tools-version:6.0
//
// examples/adaptivecards-jenkins-demo/Package.swift
//
// Runtime symbol-check example for the vendored swiftci ("jenkins") kit.
// Flavor A ("store / round-trip"): wrap the canonical AdaptiveCards.io
// "Hello World" sample card as a swiftci build Artifact, serialize the
// AgentMessage envelope to its on-the-wire JSON via encodeJSON(), decode
// it back via AgentMessage.decode(json:), and assert the card survived
// byte-for-byte. No network, no ports — deterministic on every runner.
//
// Path-deps the vendored kit at ../.. via SwiftPM's `path:` dep. A
// `path:` dep does NOT propagate the kit's package-identity overrides up
// to this resolution root, so we must re-declare the exact same hggz
// substrate forks (same revisions) here, or the resolver picks upstream
// apple/swift-nio-extras (whose CNIOExtrasZlib needs unistd.h on Windows
// and dies) instead of the hggz fork. Keep in sync with ../../Package.swift.

import PackageDescription

let package = Package(
    name: "AdaptiveCardsJenkinsDemo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AdaptiveCardsDemo", targets: ["AdaptiveCardsDemo"]),
    ],
    dependencies: [
        // Path-dep on the vendored kit.
        .package(name: "swiftci", path: "../.."),

        // ── Mirrored from ../../Package.swift (exact revisions) ─────────
        .package(url: "https://github.com/hggz/vapor.git",            revision: "5d21fd1e8913207cef6c027f301457040bfd6e7b"),
        .package(url: "https://github.com/hggz/swift-nio.git",         revision: "7c9c6861c968f8902c0610ab4ba2e23311f5092c"),
        .package(url: "https://github.com/hggz/swift-nio-extras.git",  revision: "076c9b493c6fe365ba42663fc16c4239d17dfb92"),
        .package(url: "https://github.com/hggz/async-http-client.git", revision: "eaaf46acd43c9076f3e00759a05dd5de7978db36"),
        .package(url: "https://github.com/hggz/swift-nio-ssl.git",     revision: "7f9efd53d9d4d916f8fb4ba77646ada440b6fee8"),
        .package(url: "https://github.com/hggz/websocket-kit.git",     revision: "ddfba8cf33fd420fd27360ab30907cefee1de0f2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AdaptiveCardsDemo",
            dependencies: [
                .product(name: "SwiftCIKit", package: "swiftci"),
            ]
        ),
    ]
)
