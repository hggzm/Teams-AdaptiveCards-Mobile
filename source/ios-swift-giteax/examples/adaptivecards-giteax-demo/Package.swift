// swift-tools-version:5.9
//
// examples/adaptivecards-giteax-demo/Package.swift
//
// Runtime symbol-check example for the vendored Giteax kit. Flavor A
// ("store"): spin up Giteax in-process against a tempdir, init a bare
// repo via SwiftGitX, create a user via the admin REST API, post the
// canonical AdaptiveCards.io "Hello World" sample card as the body of
// an issue, read it back, assert byte-equal.
//
// Path-deps the vendored kit at ../.. via SwiftPM's `path:` dep, which
// also re-exposes the public hggz substrate forks declared up there.

import PackageDescription

let package = Package(
    name: "AdaptiveCardsGiteaxDemo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AdaptiveCardsDemo", targets: ["AdaptiveCardsDemo"]),
    ],
    dependencies: [
        .package(name: "Giteax", path: "../.."),

        // ── Mirrored from ../../Package.swift ───────────────────────────
        // SwiftPM identity overrides do NOT propagate through `path:`
        // dependencies. Without re-declaring the hggz substrate forks
        // here, the resolver pulls upstream apple/swift-nio-extras
        // (which tries to compile a vendored zlib that wants unistd.h)
        // instead of the hggz fork (which uses the Windows `empty.c`
        // shim). Keep these in sync with ../../Package.swift.
        .package(url: "https://github.com/hggz/vapor.git",
                 revision: "d3fa2d09"),
        .package(url: "https://github.com/hggz/swift-nio.git",
                 revision: "7c9c6861"),
        .package(url: "https://github.com/hggz/swift-nio-extras.git",
                 revision: "076c9b49"),
        .package(url: "https://github.com/hggz/async-http-client.git",
                 revision: "eaaf46a"),
        .package(url: "https://github.com/hggz/swift-nio-ssl.git",
                 revision: "7f9efd5"),
        .package(url: "https://github.com/hggz/websocket-kit.git",
                 revision: "ddfba8c"),
    ],
    targets: [
        .executableTarget(
            name: "AdaptiveCardsDemo",
            dependencies: [
                .product(name: "Giteax",          package: "Giteax"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore",         package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
    ]
)
