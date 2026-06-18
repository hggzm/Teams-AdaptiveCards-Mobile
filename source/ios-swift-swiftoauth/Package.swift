// swift-tools-version:6.0
// swiftoauth vendored snapshot for the Adaptive Cards Mobile proxy
// integration drop.
//
// Vendored from hggz/swiftoauth as of 2026-06-17; this snapshot inherits
// the repo-root MIT license. No nested LICENSE file. No private commit
// SHAs are referenced.
//
// Diffs from the upstream Package.swift:
//
//   1. The `swiftoauth` executable target and its CLI sources
//      (ArgumentParser command front-end + AsyncHTTPClientTransport)
//      have been dropped — the symbol-check drop only needs libraries
//      the demo can `import`.
//   2. The `swift-argument-parser`, `async-http-client`, and
//      `swift-nio-ssl` dependencies have been removed; they were only
//      wired into the dropped CLI executable. The loopback callback
//      server (SwiftOAuthServer) runs on Hummingbird's HTTP/1 runtime
//      alone, which pulls swift-nio + swift-nio-extras but NOT
//      nio-ssl/compression — so this drop needs no zlib and no TLS
//      stack on any platform.
//   3. The NIO substrate forks remain pinned to the same public hggz
//      revisions used by hggz/swiftci and hggz/giteax; those forks
//      carry the Windows-specific Swift 6.x shims upstream master does
//      not yet have.

import PackageDescription

let package = Package(
    name: "swiftoauth",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftOAuthCore", targets: ["SwiftOAuthCore"]),
        .library(name: "SwiftOAuthServer", targets: ["SwiftOAuthServer"]),
    ],
    dependencies: [
        // Cross-platform SHA-256 for PKCE S256 (NOT CryptoKit — Apple-only).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),

        // Loopback callback server substrate. Public hggz Windows-supported
        // forks, pinned to the Hummingbird-compatible SHAs used by the sibling
        // hggz repos (swiftci / giteax).
        .package(url: "https://github.com/hggz/hummingbird.git",
                 revision: "3e8921437eb791e06662d9f8cbfcd55f18c4759a"),
        .package(url: "https://github.com/hggz/swift-nio.git",
                 revision: "7c9c6861c968f8902c0610ab4ba2e23311f5092c"),
        .package(url: "https://github.com/hggz/swift-nio-extras.git",
                 revision: "076c9b493c6fe365ba42663fc16c4239d17dfb92"),
    ],
    targets: [
        .target(
            name: "SwiftOAuthCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "SwiftOAuthServer",
            dependencies: [
                "SwiftOAuthCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "SwiftOAuthCoreTests",
            dependencies: ["SwiftOAuthCore"]
        ),
        .testTarget(
            name: "SwiftOAuthServerTests",
            dependencies: [
                "SwiftOAuthServer",
                "SwiftOAuthCore",
            ]
        ),
    ]
)
