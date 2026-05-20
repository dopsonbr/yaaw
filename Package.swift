// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentIDE",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AgentIDE", targets: ["AgentIDE"]),
        .executable(name: "AgentIDEE2E", targets: ["AgentIDEE2E"]),
        .library(name: "AgentIDEKit", targets: ["AgentIDEKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.1.4")
    ],
    targets: [
        .executableTarget(
            name: "AgentIDE",
            dependencies: [
                "AgentIDEKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            path: "src/App"
        ),
        .target(
            name: "AgentIDEKit",
            path: "src",
            exclude: [
                "AGENTS.md",
                "App",
                "E2E",
                "Tests"
            ],
            sources: [
                "AgentCLI",
                "Core",
                "Diagnostics",
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
        ),
        .executableTarget(
            name: "AgentIDEE2E",
            dependencies: ["AgentIDEKit"],
            path: "src/E2E"
        )
    ]
)
