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
            revision: "c056eecfe327616a42f46ef29e706c604285cf6a"
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
                .copy("Resources/Editor")
            ],
            linkerSettings: [
                .linkedFramework("WebKit")
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
