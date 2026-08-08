// swift-tools-version: 5.10

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
        .executableTarget(
            name: "Floodlight",
            dependencies: [
                "FloodlightEngine",
                .product(name: "FFFKit", package: "fff-swift")
            ],
            path: "Sources/Floodlight",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        // Shared test scaffolding: a deterministic property-based testing
        // harness, adversarial input corpora, and the catalog/process test
        // doubles both test targets drive. Depends on nothing but the
        // engine, so it never pulls the shell into the engine's tests.
        .target(
            name: "FloodlightTestSupport",
            dependencies: ["FloodlightEngine"],
            path: "Tests/FloodlightTestSupport"
        ),
        .testTarget(
            name: "FloodlightEngineTests",
            dependencies: [
                "FloodlightEngine",
                "FloodlightTestSupport",
                .product(name: "FFFKit", package: "fff-swift")
            ],
            path: "Tests/FloodlightEngineTests"
        ),
        .testTarget(
            name: "FloodlightTests",
            dependencies: ["Floodlight", "FloodlightEngine", "FloodlightTestSupport"],
            path: "Tests/FloodlightTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
