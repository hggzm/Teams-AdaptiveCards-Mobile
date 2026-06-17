// swift-tools-version:5.9
//
// Vendored snapshot of swiftbox's pure-Swift core (`SwiftboxCore`), dropped
// into AdaptiveCards-Mobile as an experimental, proxy-only parallel Swift
// surface. It touches none of the production ObjC (`source/ios`), Java
// (`source/android`), or C++ (`source/shared`) code.
//
// `platforms` only narrows minimum versions for Apple platforms. Linux,
// Windows, and any other Swift-supported target build with no platform clause —
// so this deliberately does NOT restrict to Apple. The core is pure
// cross-platform `Foundation` Swift (no Darwin/UIKit/AppKit/CoreFoundation/
// Combine/os.* imports), so it builds and tests on Windows MSVC.
//
// SwiftboxCore has NO external package dependencies; there are intentionally no
// `.package(url:)` lines, hence no SSH-alias URLs to resolve in CI.

import PackageDescription

let package = Package(
    name: "Swiftbox",
    platforms: [
        .iOS(.v16), .macOS(.v13), .tvOS(.v16),
        .watchOS(.v9), .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftboxCore", targets: ["SwiftboxCore"]),
    ],
    targets: [
        .target(name: "SwiftboxCore"),
    ]
)
