import XCTest

@testable import YAAWKit

final class FontConfigurationTests: PersistenceTestCase {
    func testYAMLConfigurationFontLigaturesRoundTrip() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let disabled = try store.validate(
            text: """
                version: 1
                fonts:
                  ligatures: false
                """
        )
        XCTAssertFalse(disabled.fonts.ligatures)

        try store.save(disabled)
        let saved = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("ligatures: false"))
        XCTAssertFalse(store.load().fonts.ligatures)
    }

    func testYAMLConfigurationFileBrowserFontOverrideAndValidation() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        // Explicit override is preserved.
        let overridden = try store.validate(
            text: """
                version: 1
                fonts:
                  fileBrowserFamily: Fira Code
                  fileBrowserSize: 15
                """
        )
        XCTAssertEqual(overridden.fonts.fileBrowserFamily, "Fira Code")
        XCTAssertEqual(overridden.fonts.fileBrowserSize, 15)

        // A non-positive size collapses back to inherit (0); blank family becomes inherit.
        let inherited = try store.validate(
            text: """
                version: 1
                fonts:
                  fileBrowserFamily: "  "
                  fileBrowserSize: 0
                """
        )
        XCTAssertEqual(inherited.fonts.fileBrowserFamily, "inherit")
        XCTAssertEqual(inherited.fonts.fileBrowserSize, 0)

        // An out-of-range explicit size is clamped.
        let clamped = try store.validate(
            text: """
                version: 1
                fonts:
                  fileBrowserFamily: SF Mono
                  fileBrowserSize: 999
                """
        )
        XCTAssertEqual(clamped.fonts.fileBrowserFamily, "SF Mono")
        XCTAssertEqual(clamped.fonts.fileBrowserSize, 28)
    }

    func testYAMLConfigurationFileBrowserModeAndAgentLaunchDefaultValidation() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let configuration = try store.validate(
            text: """
                version: 1
                agent:
                  launchDefaults:
                    claude:
                      permissionModeID: default
                      additionalArguments: ["  --model  ", "", sonnet]
                    copilot:
                      permissionModeID: copilot-yolo
                      additionalArguments: [--fast]
                fileBrowser:
                  markdownAndHTMLDefault: unsupported
                """
        )

        XCTAssertNil(configuration.agent.launchDefaults.claude.permissionModeID)
        XCTAssertEqual(
            configuration.agent.launchDefaults.claude.additionalArguments,
            ["--model", "sonnet"]
        )
        XCTAssertEqual(configuration.agent.launchDefaults.copilot.permissionModeID, "copilot-yolo")
        XCTAssertEqual(configuration.agent.launchDefaults.copilot.additionalArguments, ["--fast"])
        XCTAssertEqual(configuration.fileBrowser.markdownAndHTMLDefault, .browserPreview)
    }

    func testYAMLConfigurationSaveRendersAgentLaunchDefaultsAndReloadsThem() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)
        let configuration = YAAWConfiguration(
            agent: AgentSettings(
                launchDefaults: AgentLaunchDefaultsSettings(
                    claude: AgentLaunchDefaultSettings(
                        permissionModeID: "claude-plan",
                        additionalArguments: ["--model", "sonnet"]
                    ),
                    copilot: AgentLaunchDefaultSettings(permissionModeID: "copilot-yolo")
                )
            )
        )

        try store.save(configuration)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.agent.launchDefaults, configuration.agent.launchDefaults)
        XCTAssertEqual(reloaded.agent.launchDefaults.claude.permissionModeID, "claude-plan")
        XCTAssertEqual(
            reloaded.agent.launchDefaults.claude.additionalArguments,
            ["--model", "sonnet"]
        )
        XCTAssertEqual(reloaded.agent.launchDefaults.copilot.permissionModeID, "copilot-yolo")
        XCTAssertNil(reloaded.agent.launchDefaults.codex.permissionModeID)
    }

    func testYAMLConfigurationSaveRendersFontSettingsAndReloadsThem() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)
        let configuration = YAAWConfiguration(
            fonts: FontSettings(
                interfaceFamily: "Avenir Next",
                interfaceSize: 14.5,
                editorFamily: "SF Mono",
                editorSize: 15,
                terminalFamily: "JetBrains Mono",
                terminalSize: 16
            )
        )

        try store.save(configuration)

        let text = try String(contentsOf: path, encoding: .utf8)
        let reloaded = store.load()
        XCTAssertTrue(text.contains("interfaceFamily: \"Avenir Next\""))
        XCTAssertTrue(text.contains("interfaceSize: 14.5"))
        XCTAssertTrue(text.contains("editorFamily: \"SF Mono\""))
        XCTAssertTrue(text.contains("editorSize: 15"))
        XCTAssertTrue(text.contains("terminalFamily: \"JetBrains Mono\""))
        XCTAssertTrue(text.contains("terminalSize: 16"))
        XCTAssertEqual(reloaded.fonts, configuration.fonts)
    }

    func testYAMLConfigurationClampsFontSizesAndFallbacksBlankFamilies() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            fonts:
              interfaceFamily: " "
              interfaceSize: 2
              editorFamily: ""
              editorSize: 40
              terminalFamily: "  "
              terminalSize: 999
            """.utf8
        ).write(to: path)
        let store = YAMLConfigurationStore(path: path)

        let reloaded = store.load()

        XCTAssertEqual(reloaded.fonts.interfaceFamily, "system")
        XCTAssertEqual(reloaded.fonts.interfaceSize, 9)
        XCTAssertEqual(reloaded.fonts.editorFamily, "system-monospace")
        XCTAssertEqual(reloaded.fonts.editorSize, 28)
        XCTAssertEqual(reloaded.fonts.terminalFamily, "")
        XCTAssertEqual(reloaded.fonts.terminalSize, 32)
    }
}
