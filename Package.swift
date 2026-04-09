// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentBar", targets: ["AgentBar"])
    ],
    targets: [
        .executableTarget(
            name: "AgentBar"
        ),
        .testTarget(
            name: "AgentBarTests",
            dependencies: ["AgentBar"]
        )
    ]
)
