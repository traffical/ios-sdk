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
        // Host-safety suite (spec S11). Public API only — no @testable — so it
        // builds and runs with `swift test -c release`, the configuration that
        // ships: optimizer on, assertions stripped, overflow trapping exactly
        // as on device. A crash anywhere fails the run.
        .testTarget(
            name: "TrafficalHardeningTests",
            dependencies: ["Traffical", "TrafficalCore"],
            path: "Tests/TrafficalHardeningTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
