// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AdaptiveCardCustomElements",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "AdaptiveCardCustomElements",
            targets: ["AdaptiveCardCustomElements"]
        )
    ],
    targets: [
        .target(
            name: "AdaptiveCardCustomElements",
            dependencies: []
        )
    ]
)
