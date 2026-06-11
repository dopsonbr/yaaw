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
        .library(name: "YAAWRenderProtocol", targets: ["YAAWRenderProtocol"]),
        .library(name: "YAAWKit", targets: ["YAAWKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.4"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
    ],
    targets: [
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
