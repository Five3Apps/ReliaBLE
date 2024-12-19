// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReliaBLE",
    platforms: [
        .iOS(.v16),
        .macOS(.v10_14)
    ],
    products: [
        .library(
            name: "ReliaBLE",
            targets: ["ReliaBLE"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/itsniper/Willow", branch: "main"),
    ],
    targets: [
        .target(
            name: "ReliaBLE",
            dependencies: ["Willow"]
        ),
        .testTarget(
            name: "ReliaBLETests",
            dependencies: ["ReliaBLE"]
        ),
    ]
)
