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
        .package(
            url: "https://github.com/genomewalker/libghostty-spm.git",
            revision: "859807b2d92ec8e2e57806b311fad23afe5f16c4"
        )
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
                .copy("Resources/SidePanel"),
                .copy("Resources/Terminfo")
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
            path: "Tests/RelayTests"
        )
    ]
)
