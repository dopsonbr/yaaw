// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "YAAW",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "YAAW", targets: ["YAAW"]),
        .executable(name: "YAAWToolHost", targets: ["YAAWToolHost"]),
        .executable(name: "YAAWE2E", targets: ["YAAWE2E"]),
        .library(name: "YAAWKit", targets: ["YAAWKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.1.4"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .executableTarget(
            name: "YAAW",
            dependencies: [
                "YAAWKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            path: "src/App",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "YAAWToolHost",
            dependencies: ["YAAWKit"],
            path: "src/ToolHost",
            sources: ["main.swift"]
        ),
        .target(
            name: "YAAWKit",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "src",
            exclude: [
                "AGENTS.md",
                "App",
                "E2E",
                "Tests",
                "ToolHost"
            ],
            sources: [
                "AgentCLI",
                "Core",
                "Diagnostics",
                "FileBrowser",
                "Icons",
                "IsolatedTools",
                "Layout",
                "MarkdownPreview",
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
            name: "YAAWKitTests",
            dependencies: ["YAAWKit"],
            path: "src/Tests/YAAWKitTests"
        ),
        .testTarget(
            name: "YAAWKitBenchmarks",
            dependencies: ["YAAWKit"],
            path: "src/Tests/YAAWKitBenchmarks"
        ),
        .executableTarget(
            name: "YAAWE2E",
            dependencies: ["YAAWKit"],
            path: "src/E2E"
        )
    ]
)
