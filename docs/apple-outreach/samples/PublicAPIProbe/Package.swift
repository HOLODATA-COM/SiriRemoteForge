// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HyperVibePublicAPIProbe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "InputProbe", targets: ["InputProbe"]),
        .executable(name: "AudioInputProbe", targets: ["AudioInputProbe"]),
    ],
    targets: [
        .executableTarget(
            name: "InputProbe",
            linkerSettings: [.linkedFramework("GameController")]
        ),
        .executableTarget(
            name: "AudioInputProbe",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
