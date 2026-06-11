// swift-tools-version: 6.2

import PackageDescription

// Every target builds in Swift 6 language mode, which makes strict concurrency
// checking `complete` and turns data races + unsafe `Sendable` use into compile
// errors. Warnings-as-errors is applied as a CI gate (see scripts/check.sh),
// not baked in here (rewrite DECISIONS-LOG D-006).
let swift6: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "YAAW",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "YAAW", targets: ["YAAW"]),
        .library(name: "YAAWRenderProtocol", targets: ["YAAWRenderProtocol"]),
        .library(name: "YAAWKit", targets: ["YAAWKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.4"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
    ],
    targets: [
        // The SwiftUI app shell: thin feature views consuming the @MainActor
        // @Observable stores (Chunk E/F), the chrome toolbar, settings window,
        // and the main-side render integration (RenderHostClient over XPC +
        // TerminalSurfaceHostView compositing the helper's remote layer).
        .executableTarget(
            name: "YAAW",
            dependencies: [
                "YAAWKit",
                "YAAWRenderProtocol",
            ],
            path: "src/App",
            resources: [
                .process("Resources")
            ],
            swiftSettings: swift6
        ),
        // Pure-Swift seam shared by the app and the render helper: Codable XPC
        // message envelopes, the @objc XPC service/client protocols, and the
        // rendering-config DTOs. No Ghostty types, no AppKit-heavy deps.
        .target(
            name: "YAAWRenderProtocol",
            path: "src/RenderProtocol",
            swiftSettings: swift6
        ),
        // The library: domain model, actor services (Persistence / FileIndex /
        // SessionBinding), config, theme tokens, RenderHostClient. No Ghostty.
        .target(
            name: "YAAWKit",
            dependencies: [
                "YAAWRenderProtocol",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "src/Kit",
            resources: [
                .copy("Fonts/Resources/JetBrainsMono")
            ],
            swiftSettings: swift6,
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Release-buildable perf gate. XCTest benchmark targets crash the Swift
        // 6.3 optimizer when importing YAAWKit (DECISIONS-LOG D-010), so the
        // authoritative release perf numbers come from this plain executable:
        //   swift run -c release YAAWKitPerf
        .executableTarget(
            name: "YAAWKitPerf",
            dependencies: ["YAAWKit"],
            path: "src/Perf",
            swiftSettings: swift6
        ),
        // The headless per-surface render helper. Hosts the libghostty emulator
        // + PTY (terminal) or a WKWebView (browser) in a faceless XPC service,
        // composites natively via CAContext/CALayerHost (ADR-004), and publishes
        // typed RenderEvents back to the app. The only target that links Ghostty;
        // those types never leak into YAAWKit or the protocol seam.
        .executableTarget(
            name: "YAAWRenderHost",
            dependencies: [
                "YAAWRenderProtocol",
                "YAAWKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "src/RenderHost",
            swiftSettings: swift6
        ),
        .testTarget(
            name: "YAAWRenderProtocolTests",
            dependencies: ["YAAWRenderProtocol"],
            path: "src/Tests/RenderProtocolTests",
            swiftSettings: swift6
        ),
        .testTarget(
            name: "YAAWKitTests",
            dependencies: ["YAAWKit", "YAAWRenderProtocol"],
            path: "src/Tests/YAAWKitTests",
            swiftSettings: swift6
        ),
        .testTarget(
            name: "YAAWKitBenchmarks",
            dependencies: ["YAAWKit"],
            path: "src/Tests/YAAWKitBenchmarks",
            swiftSettings: swift6
        ),
    ]
)
