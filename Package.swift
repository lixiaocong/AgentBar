// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentBarCore", targets: ["AgentBarCore"]),
        .executable(name: "AgentBar", targets: ["AgentBar"]),
        .executable(name: "AgentBarWidgetExtension", targets: ["AgentBarWidgetExtension"]),
    ],
    targets: [
        .target(
            name: "AgentBarCore"
        ),
        .executableTarget(
            name: "AgentBar",
            dependencies: ["AgentBarCore"]
        ),
        .executableTarget(
            name: "AgentBarWidgetExtension",
            dependencies: ["AgentBarCore"],
            swiftSettings: [
                .unsafeFlags(["-application-extension"])
            ]
        ),
        .testTarget(
            name: "AgentBarTests",
            dependencies: ["AgentBar", "AgentBarCore"]
        )
    ]
)
