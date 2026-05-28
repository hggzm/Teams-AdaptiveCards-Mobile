// swift-tools-version:5.9
import PackageDescription

// proxy-only — vendored swiftka kit snapshot.
// Vendored from hggz/swiftka as of 2026-05-28. This snapshot is
// licensed under the repo-root MIT license. No nested LICENSE file is
// included; no private commit SHAs are referenced.
//
// Only public Phase-F substrate dependencies are declared. No SSH-alias
// URLs are referenced anywhere. CI on the proxy fork resolves
// `https://github.com/hggz/swift-nio.git` at a revision pin.
//
// `platforms:` narrows minimums for Apple platforms only. Linux and
// Windows builds with no platform clause — deliberately not added.

let package = Package(
    name: "swiftka-bridge",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftKaKit",    targets: ["SwiftKaKit"]),
        .library(name: "SwiftKaBridge", targets: ["SwiftKaBridge"]),
    ],
    dependencies: [
        // hggz/swift-nio (public substrate fork, revision-pinned).
        .package(
            url: "https://github.com/hggz/swift-nio.git",
            revision: "7c9c6861c968f8902c0610ab4ba2e23311f5092c"
        ),
    ],
    targets: [
        // Vendored SQLite 3.47.1 amalgamation with FTS5 / JSON1 / RTREE
        // / THREADSAFE=2 / URI.
        .target(
            name: "Csqlite3",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_JSON1"),
                .define("SQLITE_ENABLE_RTREE"),
                .define("SQLITE_THREADSAFE", to: "2"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_USE_URI", to: "1"),
                .unsafeFlags(["-w"]),
            ]
        ),
        // The vendored swiftka kit (pure-Swift Redis-compatible server
        // library + RESP codec + dispatcher).
        .target(
            name: "SwiftKaKit",
            dependencies: [
                "Csqlite3",
                .product(name: "NIOCore",  package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/SwiftKaKit"
        ),
        // Thin AdaptiveCards-facing surface that exposes the kit's
        // storage layer as a simple AdaptiveCardStore API.
        .target(
            name: "SwiftKaBridge",
            dependencies: ["SwiftKaKit", "Csqlite3"],
            path: "Sources/SwiftKaBridge"
        ),
    ]
)
