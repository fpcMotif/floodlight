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
        .target(
            name: "FloodlightEngine",
            path: "Sources/FloodlightEngine"
        ),
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
        .testTarget(
            name: "FloodlightEngineTests",
            dependencies: ["FloodlightEngine"],
            path: "Tests/FloodlightEngineTests"
        ),
        .testTarget(
            name: "FloodlightTests",
            dependencies: ["Floodlight", "FloodlightEngine"],
            path: "Tests/FloodlightTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
