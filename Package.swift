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
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.4.0")
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            path: "Sources/Relay"
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
