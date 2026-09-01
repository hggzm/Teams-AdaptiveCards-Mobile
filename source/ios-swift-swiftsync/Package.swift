// swift-tools-version:6.0
//
// source/ios-swift-swiftsync/Package.swift
//
// Vendored snapshot of the SwiftSyncCore engine from hggz/swiftsync, dropped
// alongside the production Adaptive Cards mobile SDK as an experimental,
// proxy-only parallel Swift surface. It touches none of the existing
// ObjC/Java/C++ code.
//
// SwiftSyncCore is a general-purpose, pure-Foundation directory-sync engine
// (a minimalist rsync-style recursive copy). It has NO external package
// dependencies and imports only Foundation, so it builds unchanged on Apple
// platforms, Linux, and Windows. There are deliberately no private SSH-alias
// dependency URLs and no Apple-only imports.

import PackageDescription

// `platforms` only narrows minimum versions for Apple platforms. Linux,
// Windows, Android, and any other Swift-supported target build with no
// platform clause — so we deliberately do NOT restrict to Apple here.
let package = Package(
    name: "SwiftSyncCore",
    platforms: [
        .iOS(.v15), .macOS(.v12), .tvOS(.v15),
        .watchOS(.v8), .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftSyncCore", targets: ["SwiftSyncCore"]),
    ],
    targets: [
        .target(name: "SwiftSyncCore"),
    ]
)
