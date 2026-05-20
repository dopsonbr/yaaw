// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentIDE",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AgentIDE", targets: ["AgentIDE"]),
        .library(name: "AgentIDEKit", targets: ["AgentIDEKit"])
    ],
    targets: [
        .executableTarget(
            name: "AgentIDE",
            dependencies: ["AgentIDEKit"],
            path: "src/App"
        ),
        .target(
            name: "AgentIDEKit",
            path: "src",
            exclude: [
                "AGENTS.md",
                "App",
                "Tests"
            ],
            sources: [
                "Core",
                "FileBrowser",
                "Layout",
                "Persistence",
                "Projects",
                "RightPanel",
                "Terminal",
                "Theme",
                "Threads"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AgentIDEKitTests",
            dependencies: ["AgentIDEKit"],
            path: "src/Tests/AgentIDEKitTests"
        )
    ]
)
