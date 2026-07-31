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
    targets: [
        .target(
            name: "CFFF",
            path: "Sources/CFFF",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-LNative/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ]),
                .linkedLibrary("fff_c")
            ]
        ),
        .executableTarget(
            name: "Floodlight",
            dependencies: ["CFFF"],
            path: "Sources/Floodlight",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "FloodlightTests",
            dependencies: ["Floodlight"],
            path: "Tests/FloodlightTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
