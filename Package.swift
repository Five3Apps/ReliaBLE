// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReliaBLE",
    products: [
        .library(
            name: "ReliaBLE",
            targets: ["ReliaBLE"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "ReliaBLE"
        ),
        .testTarget(
            name: "ReliaBLETests",
            dependencies: ["ReliaBLE"]
        ),
    ]
)
