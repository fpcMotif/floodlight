// swift-tools-version: 5.10
// DRAFT — asset of ticket 03 (spm-modularization). Not the live manifest.

import PackageDescription

let package = Package(
    name: "Floodlight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Floodlight", targets: ["Floodlight"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/vmg-dev/fff-swift",
            from: "0.1.0"
        )
    ],
    targets: [
        // The deep module: results, ranking, action execution. Zero `public`.
        .target(
            name: "FloodlightEngine",
            dependencies: [
                .product(name: "FFFKit", package: "fff-swift")
            ],
            path: "Sources/FloodlightEngine"
        ),
        // The macOS shell: panel, hotkey, menu bar, onboarding, QuickLook, login item.
        // Sole owner of every linked framework.
        .executableTarget(
            name: "Floodlight",
            dependencies: ["FloodlightEngine"],
            path: "Sources/Floodlight",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "FloodlightEngineTests",
            dependencies: ["FloodlightEngine"],
            path: "Tests/FloodlightEngineTests"
        ),
        .testTarget(
            name: "FloodlightTests",
            dependencies: ["Floodlight"],
            path: "Tests/FloodlightTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
