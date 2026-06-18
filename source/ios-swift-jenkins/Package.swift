// swift-tools-version:6.0
import PackageDescription

// Floor is Swift 6.1 because hggz/swift-nio:windows-joannis-mirror's
// manifest declares swift-tools-version:6.1. Local dev on Windows uses
// the Swift 6.3.1 toolchain; CI uses 6.1 release.
//
// Substrate pins are revision-pinned (Phase F validated 2026-05-18).
// Branches drift; revisions don't. See bucket/VAPOR_HANDOFF.md for the
// per-fork rationale.
//
// `platforms` only narrows minimum versions for Apple platforms. Linux,
// Windows, and any other Swift-supported target build with no platform
// clause — so we deliberately do NOT restrict to Apple here.
let package = Package(
    name: "swiftci",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SwiftCIKit", targets: ["SwiftCIKit"]),
        .executable(name: "swiftci", targets: ["swiftci"]),
        .executable(name: "swiftci-agent", targets: ["swiftci-agent"]),
    ],
    dependencies: [
        // hggz Vapor-on-Windows kit (Phase F, 2026-05-18 + non-Windows
        // FileMetadata fixes: Int64 cast + _NIOFileSystemFoundationCompat
        // import for Swift 6.1's MemberImportVisibility). All six
        // revisions pinned exactly to guard against transient branch-head
        // drift.
        .package(url: "https://github.com/hggz/vapor.git",            revision: "5d21fd1e8913207cef6c027f301457040bfd6e7b"),
        .package(url: "https://github.com/hggz/swift-nio.git",         revision: "7c9c6861c968f8902c0610ab4ba2e23311f5092c"),
        .package(url: "https://github.com/hggz/swift-nio-extras.git",  revision: "076c9b493c6fe365ba42663fc16c4239d17dfb92"),
        .package(url: "https://github.com/hggz/async-http-client.git", revision: "eaaf46acd43c9076f3e00759a05dd5de7978db36"),
        .package(url: "https://github.com/hggz/swift-nio-ssl.git",     revision: "7f9efd53d9d4d916f8fb4ba77646ada440b6fee8"),
        .package(url: "https://github.com/hggz/websocket-kit.git",     revision: "ddfba8cf33fd420fd27360ab30907cefee1de0f2"),

        // YAML parser. Yams wraps libyaml; validated on Windows MSVC
        // (probe-swiftci-windows, Phase 1) with no fork required.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "SwiftCIKit",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Yams",  package: "Yams"),
            ],
            path: "Sources/SwiftCIKit"
        ),
        .executableTarget(
            name: "swiftci",
            dependencies: ["SwiftCIKit"],
            path: "Sources/SwiftCIServer"
        ),
        .executableTarget(
            name: "swiftci-agent",
            dependencies: [
                "SwiftCIKit",
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/SwiftCIAgent"
        ),
        .testTarget(
            name: "SwiftCIKitTests",
            dependencies: [
                "SwiftCIKit",
                .product(name: "VaporTesting", package: "vapor"),
            ],
            path: "Tests/SwiftCIKitTests"
        ),
    ]
)
