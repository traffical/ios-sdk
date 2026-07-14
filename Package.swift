// swift-tools-version: 5.9
// The Traffical iOS SDK.

import PackageDescription

let package = Package(
    name: "Traffical",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v7),
    ],
    products: [
        .library(name: "Traffical", targets: ["Traffical"]),
        .library(name: "TrafficalCore", targets: ["TrafficalCore"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TrafficalCore",
            path: "Sources/TrafficalCore"
        ),
        .target(
            name: "Traffical",
            dependencies: ["TrafficalCore"],
            path: "Sources/Traffical",
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "TrafficalCoreTests",
            dependencies: ["TrafficalCore"],
            path: "Tests/TrafficalCoreTests"
        ),
        .testTarget(
            name: "TrafficalTests",
            dependencies: ["Traffical"],
            path: "Tests/TrafficalTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
