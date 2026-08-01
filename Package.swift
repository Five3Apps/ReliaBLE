// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ReliaBLE",
    // Every platform is pinned to the lowest OS version that ships the `Synchronization` module, because
    // `Peripheral` and `PeripheralHandleRegistry` guard their mutable state with `Synchronization.Mutex`.
    // Declaring each platform explicitly is what makes that safe: an undeclared platform would otherwise
    // inherit SPM's default floor and fail on `import Synchronization`.
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
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
            dependencies: ["Willow"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "ReliaBLEMock",
            dependencies: [
                "Willow",
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock")
            ],
            exclude: ["ReliaBLE/CBCentralManagerFactory.swift", "ReliaBLE/Documentation.docc"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ReliaBLETests",
            dependencies: [
                "ReliaBLEMock",
                "Willow",
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock")
            ],
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
