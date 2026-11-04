// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Louder",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Louder", targets: ["Louder"]),
        .executable(name: "louder-cli", targets: ["louder-cli"]),
        .library(name: "LouderEngine", targets: ["LouderEngine"]),
    ],
    targets: [
        .target(name: "LouderEngine"),
        .executableTarget(name: "louder-cli", dependencies: ["LouderEngine"]),
        .executableTarget(name: "Louder", dependencies: ["LouderEngine"]),
        .testTarget(name: "LouderEngineTests", dependencies: ["LouderEngine"]),
    ]
)
