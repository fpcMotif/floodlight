// swift-tools-version: 6.4

import PackageDescription

/// Upcoming features that stay opt-in until a later language mode. Swift 6
/// already implies complete concurrency checking. These two match Approachable
/// Concurrency in Xcode 27 / Swift 6.4.
let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let shellSettings: [SwiftSetting] = upcoming + [
    .unsafeFlags(["-Osize"]),
]

let package = Package(
    name: "Floodlight",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Floodlight", targets: ["Floodlight"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/vmg-dev/fff-swift",
            from: "0.2.0"
        ),
    ],
    targets: [
        // The deep module: results, ranking, action execution. Zero `public`.
        .target(
            name: "FloodlightEngine",
            dependencies: [
                .product(name: "FFFKit", package: "fff-swift"),
            ],
            path: "Sources/FloodlightEngine",
            swiftSettings: upcoming
        ),
        // The macOS shell: panel, hotkey, menu bar, onboarding, QuickLook, login item.
        .executableTarget(
            name: "Floodlight",
            dependencies: [
                "FloodlightEngine",
            ],
            path: "Sources/Floodlight",
            exclude: ["Resources"],
            swiftSettings: shellSettings,
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-dead_strip_dylibs"]),
            ]
        ),
        // Shared test scaffolding: a deterministic property-based testing
        // harness, adversarial input corpora, and the catalog/process test
        // doubles both test targets drive. Depends on nothing but the
        // engine, so it never pulls the shell into the engine's tests.
        .target(
            name: "FloodlightTestSupport",
            dependencies: ["FloodlightEngine"],
            path: "Tests/FloodlightTestSupport",
            swiftSettings: upcoming
        ),
        .testTarget(
            name: "FloodlightEngineTests",
            dependencies: [
                "FloodlightEngine",
                "FloodlightTestSupport",
                .product(name: "FFFKit", package: "fff-swift"),
            ],
            path: "Tests/FloodlightEngineTests",
            swiftSettings: upcoming
        ),
        .testTarget(
            name: "FloodlightTests",
            dependencies: ["Floodlight", "FloodlightEngine", "FloodlightTestSupport"],
            path: "Tests/FloodlightTests",
            swiftSettings: upcoming
        ),
    ],
    swiftLanguageModes: [.v6]
)
