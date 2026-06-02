// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ReliaBLE",
    platforms: [
        .iOS(.v18),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "ReliaBLE",
            targets: ["ReliaBLE"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/itsniper/Willow", branch: "main"),
        .package(url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", .upToNextMinor(from: "1.0.6")),
    ],
    targets: [
        .target(
            name: "ReliaBLE",
            dependencies: ["Willow"]
        ),
        .target(
            name: "ReliaBLEMock",
            dependencies: [
                "Willow",
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock")
            ],
            exclude: ["ReliaBLE/CBCentralManagerFactory.swift", "ReliaBLE/Documentation.docc"]
        ),
        .testTarget(
            name: "ReliaBLETests",
            dependencies: ["ReliaBLEMock"]
        ),
    ]
)
