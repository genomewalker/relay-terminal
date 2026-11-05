// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Relay", targets: ["Relay"]),
        .executable(name: "relay-bridge", targets: ["RelayBridge"])
    ],
    dependencies: [
        .package(path: "Vendor/libghostty-spm")
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            path: "Sources/Relay",
            resources: [
                .copy("Resources/Editor"),
                .copy("Resources/Fonts"),
                .copy("Resources/SidePanel"),
                .copy("Resources/Terminfo"),
                .copy("Resources/Rotation"),
                .copy("Resources/RichContent"),
                .copy("Resources/VPN")
            ],
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("Network")
            ]
        ),
        .executableTarget(
            name: "RelayBridge",
            path: "Sources/RelayBridge"
        ),
        .testTarget(
            name: "RelayTests",
            dependencies: ["Relay"],
            path: "Tests/RelayTests",
            resources: [.copy("ShepherdSeeds")]
        )
    ]
)
