// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VLCKitSPM",
    platforms: [
        .macOS(.v10_13)
    ],
    products: [
        .library(
            name: "VLCKitSPM",
            targets: ["VLCKitSPM"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "VLCKit",
            path: "Binaries/VLCKit.xcframework"
        ),
        .target(
            name: "VLCKitSPM",
            dependencies: ["VLCKit"]
        )
    ]
)
