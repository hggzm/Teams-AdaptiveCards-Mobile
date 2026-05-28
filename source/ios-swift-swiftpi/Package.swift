// swift-tools-version:6.0
// swiftpi vendored snapshot for the Adaptive Cards Mobile proxy
// integration drop.
//
// Vendored from hggz/swiftpi as of 2026-05-28; this snapshot inherits
// the repo-root MIT license. No nested LICENSE file. No private
// commit SHAs are referenced.
//
// Diffs from the upstream Package.swift:
//
//   1. The `swiftpi` executable target and its CLI sources have been
//      dropped (CLI front-end isn't needed for the symbol-check
//      drop — the bridge only needs libraries the demo can `import`).
//   2. The `swift-argument-parser` dependency has been removed (it
//      was only wired into the CLI target).
//   3. The NIO substrate forks remain pinned to the same public
//      hggz revisions used by hggz/swiftci and hggz/giteax; those
//      forks carry the Windows-specific Swift 6.x shims upstream
//      master does not yet have.

import PackageDescription

let package = Package(
    name: "swiftpi",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftPiCore", targets: ["SwiftPiCore"]),
        .library(name: "SwiftPiProviders", targets: ["SwiftPiProviders"]),
        .library(name: "SwiftPiTools", targets: ["SwiftPiTools"]),
        .library(name: "SwiftPiSession", targets: ["SwiftPiSession"]),
        .library(name: "SwiftPiStreaming", targets: ["SwiftPiStreaming"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/hggz/swift-nio.git",
            revision: "7c9c6861c968f8902c0610ab4ba2e23311f5092c"
        ),
        .package(
            url: "https://github.com/hggz/swift-nio-extras.git",
            revision: "076c9b493c6fe365ba42663fc16c4239d17dfb92"
        ),
        .package(
            url: "https://github.com/hggz/swift-nio-ssl.git",
            revision: "7f9efd53d9d4d916f8fb4ba77646ada440b6fee8"
        ),
        .package(
            url: "https://github.com/hggz/async-http-client.git",
            revision: "eaaf46acd43c9076f3e00759a05dd5de7978db36"
        ),
    ],
    targets: [
        .target(
            name: "SwiftPiCore",
            dependencies: []
        ),
        .testTarget(
            name: "SwiftPiCoreTests",
            dependencies: ["SwiftPiCore"]
        ),

        .target(
            name: "SwiftPiStreaming",
            dependencies: ["SwiftPiCore"]
        ),
        .testTarget(
            name: "SwiftPiStreamingTests",
            dependencies: ["SwiftPiStreaming", "SwiftPiCore"]
        ),

        .target(
            name: "SwiftPiSession",
            dependencies: ["SwiftPiCore"]
        ),
        .testTarget(
            name: "SwiftPiSessionTests",
            dependencies: ["SwiftPiSession", "SwiftPiCore"]
        ),

        .target(
            name: "SwiftPiTools",
            dependencies: ["SwiftPiCore"]
        ),
        .testTarget(
            name: "SwiftPiToolsTests",
            dependencies: ["SwiftPiTools", "SwiftPiCore"]
        ),

        .target(
            name: "SwiftPiProviders",
            dependencies: [
                "SwiftPiCore",
                "SwiftPiStreaming",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "SwiftPiProvidersTests",
            dependencies: [
                "SwiftPiProviders",
                "SwiftPiCore",
                "SwiftPiStreaming",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
