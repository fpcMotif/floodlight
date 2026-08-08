// swift-tools-version: 5.10

import PackageDescription

/// Complete strict concurrency checking, on every target.
///
/// The indexing and discovery paths hand snapshots between a serial queue, the
/// cooperative pool, and the main actor; a data race there shows up as a
/// corrupted result list, which is a bug report nobody can reproduce. This makes
/// the compiler find them instead. It lives in the package settings rather than
/// in the check invocation so it holds in Xcode and in an editor too — unlike
/// warnings-as-errors, which is a flag `make check` passes so that exploratory
/// local builds stay lenient.
///
/// This is checking, not Swift 6 language mode: violations are warnings that
/// `make check` turns into errors, and the migration is separate work.
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
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
            from: "0.1.0"
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
            swiftSettings: strictConcurrency
        ),
        // The macOS shell: panel, hotkey, menu bar, onboarding, QuickLook, login item.
        .executableTarget(
            name: "Floodlight",
            dependencies: [
                "FloodlightEngine",
                .product(name: "FFFKit", package: "fff-swift"),
            ],
            path: "Sources/Floodlight",
            exclude: ["Resources"],
            swiftSettings: strictConcurrency,
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement"),
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
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "FloodlightEngineTests",
            dependencies: [
                "FloodlightEngine",
                "FloodlightTestSupport",
                .product(name: "FFFKit", package: "fff-swift"),
            ],
            path: "Tests/FloodlightEngineTests",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "FloodlightTests",
            dependencies: ["Floodlight", "FloodlightEngine", "FloodlightTestSupport"],
            path: "Tests/FloodlightTests",
            swiftSettings: strictConcurrency
        ),
    ],
    swiftLanguageVersions: [.v5]
)
