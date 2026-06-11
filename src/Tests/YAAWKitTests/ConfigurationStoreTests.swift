import XCTest

@testable import YAAWKit

final class ConfigurationStoreTests: PersistenceTestCase {
    func testYAMLConfigurationSeedsDefaultsAndWritesCommentedTemplate() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let seeded = store.load()
        let template = try String(contentsOf: path, encoding: .utf8)

        XCTAssertEqual(seeded.themeName, "system")
        XCTAssertEqual(seeded.theme.light, "macos-light")
        XCTAssertEqual(seeded.theme.dark, "macos-dark")
        XCTAssertEqual(seeded.defaultAgentCLI, .codex)
        XCTAssertEqual(seeded.projects.globalChatsDirectory, "~/yaaw")
        XCTAssertEqual(seeded.fileIconPack, .material)
        XCTAssertEqual(seeded.fonts.interfaceFamily, "system")
        XCTAssertEqual(seeded.fonts.interfaceSize, 13)
        XCTAssertEqual(seeded.fonts.editorFamily, "JetBrains Mono")
        XCTAssertEqual(seeded.fonts.editorSize, 13)
        XCTAssertEqual(seeded.fonts.terminalFamily, "JetBrains Mono")
        XCTAssertEqual(seeded.fonts.terminalSize, 15)
        XCTAssertEqual(seeded.fonts.fileBrowserFamily, "inherit")
        XCTAssertEqual(seeded.fonts.fileBrowserSize, 0)
        XCTAssertTrue(seeded.fonts.ligatures)
        XCTAssertEqual(seeded.fileBrowser.markdownAndHTMLDefault, .browserPreview)
        XCTAssertEqual(seeded.agent.launchDefaults.codex, AgentLaunchDefaultSettings())
        XCTAssertTrue(seeded.ignoreRules.contains(".git"))
        XCTAssertTrue(seeded.ignoreRules.contains("node_modules"))
        XCTAssertFalse(seeded.ignoreRules.contains("Music"))
        XCTAssertTrue(template.contains("# YAAW settings."))
        XCTAssertTrue(template.contains("launchDefaults:"))
        XCTAssertTrue(template.contains("# default: [nvim, vim, vi]"))
        XCTAssertTrue(template.contains("globalChatsDirectory: \"~/yaaw\""))
        XCTAssertTrue(template.contains("fileBrowserPack: material-file-icons"))
        XCTAssertTrue(template.contains("# supported: system, macos-light, light-2026"))
        XCTAssertTrue(template.contains("active: system"))
        XCTAssertTrue(template.contains("light: macos-light"))
        XCTAssertTrue(template.contains("dark: macos-dark"))
        XCTAssertFalse(template.contains("only dracula is implemented"))
        XCTAssertTrue(template.contains("interfaceFamily: system"))
        XCTAssertTrue(template.contains("editorFamily: \"JetBrains Mono\""))
        XCTAssertTrue(template.contains("terminalFamily: \"JetBrains Mono\""))
        XCTAssertTrue(template.contains("terminalSize: 15"))
        XCTAssertTrue(template.contains("fileBrowserFamily: inherit"))
        XCTAssertTrue(template.contains("fileBrowserSize: 0"))
        XCTAssertTrue(template.contains("ligatures: true"))
        XCTAssertTrue(template.contains("markdownAndHTMLDefault: browserPreview"))
        XCTAssertTrue(
            template.contains(
                "# not changeable yet: custom palettes are reserved for future expansion."))
    }

    func testYAMLConfigurationRawTextLoadSeedsDefaultFile() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let text = try store.loadText()

        XCTAssertTrue(text.contains("# YAAW settings."))
        XCTAssertTrue(text.contains("default: codex"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testYAMLConfigurationValidatesRawText() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let configuration = try store.validate(
            text: """
                version: 1
                agent:
                  default: claude
                  launchDefaults:
                    codex:
                      permissionModeID: codex-never
                      additionalArguments: [--model, gpt-5]
                projects:
                  globalChatsDirectory: ~/custom-yaaw
                icons:
                  fileBrowserPack: catppuccin-file-icons
                fileBrowser:
                  markdownAndHTMLDefault: editor
                fonts:
                  interfaceFamily: Avenir Next
                  interfaceSize: 14.5
                  editorFamily: SF Mono
                  editorSize: 15
                  terminalFamily: JetBrains Mono
                  terminalSize: 16
                """
        )

        XCTAssertEqual(configuration.defaultAgentCLI, .claude)
        XCTAssertEqual(
            configuration.agent.launchDefaults.codex,
            AgentLaunchDefaultSettings(
                permissionModeID: "codex-never",
                additionalArguments: ["--model", "gpt-5"]
            )
        )
        XCTAssertEqual(configuration.projects.globalChatsDirectory, "~/custom-yaaw")
        XCTAssertEqual(configuration.fileIconPack, .catppuccin)
        XCTAssertEqual(configuration.fileBrowser.markdownAndHTMLDefault, .editor)
        XCTAssertEqual(configuration.fonts.interfaceFamily, "Avenir Next")
        XCTAssertEqual(configuration.fonts.interfaceSize, 14.5)
        XCTAssertEqual(configuration.fonts.editorFamily, "SF Mono")
        XCTAssertEqual(configuration.fonts.editorSize, 15)
        XCTAssertEqual(configuration.fonts.terminalFamily, "JetBrains Mono")
        XCTAssertEqual(configuration.fonts.terminalSize, 16)
        // Omitted file browser font keys inherit the interface font.
        XCTAssertEqual(configuration.fonts.fileBrowserFamily, "inherit")
        XCTAssertEqual(configuration.fonts.fileBrowserSize, 0)
        // Omitted ligatures key defaults to enabled.
        XCTAssertTrue(configuration.fonts.ligatures)
    }

    func testYAMLConfigurationFallsBackForUnknownPairingSlotAndRecordsDiagnostic() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let recorder = RecordingDiagnosticEventRecorder()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            theme:
              active: system
              light: not-a-theme
              dark: dracula
            """.utf8
        ).write(to: path)

        let reloaded = YAMLConfigurationStore(path: path, diagnosticRecorder: recorder).load()

        XCTAssertEqual(reloaded.theme.light, "macos-light")
        XCTAssertEqual(reloaded.theme.dark, "dracula")
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Configuration"
                    && $0.name == "unsupported_theme"
                    && $0.metadata["requested"] == "not-a-theme"
                    && $0.metadata["fallback"] == "macos-light"
                    && $0.metadata["slot"] == "light"
            }
        )
    }

    func testYAMLConfigurationSaveTextPreservesRawFormattingAndComments() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)
        let text = """
            # custom settings comment
            version: 1
            agent:
              default: claude
            """

        try store.saveText(text)

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), text)
        XCTAssertEqual(store.load().defaultAgentCLI, .claude)
    }

    func testYAMLConfigurationMalformedSaveTextDoesNotOverwriteExistingFile() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)
        let original = """
            # keep me
            version: 1
            agent:
              default: codex
            """
        try store.saveText(original)

        XCTAssertThrowsError(try store.saveText("{ nope"))

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original)
        XCTAssertEqual(store.load().defaultAgentCLI, .codex)
    }

    func testYAMLConfigurationLoadsOverridesAndUnknownKeys() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            version: 1
            unknownTopLevel: ignored
            agent:
              default: claude
              launchDefaults:
                codex:
                  permissionModeID: codex-on-request
                  additionalArguments: [--model, gpt-5]
            projects:
              globalChatsDirectory: /tmp/yaaw-global
            theme:
              active: dracula
            icons:
              fileBrowserPack: catppuccin-file-icons
            fonts:
              interfaceFamily: Avenir Next
              interfaceSize: 14
              editorFamily: SF Mono
              editorSize: 15
              terminalFamily: JetBrains Mono
              terminalSize: 16
            keyboardShortcuts:
              toggleBottomTerminal:
                key: k
                modifiers: [command, option]
            tools:
              editors:
                preferred: [zed, nvim]
              externalOpen:
                default: vscode
                preferred: [webstorm, unsupported, vscode, finder, vscode]
              git:
                preferred: tig
              diff:
                fallback: [delta, "--diff"]
              agents:
                codex: codex-nightly
            fileBrowser:
              markdownAndHTMLDefault: editor
            fileIndexing:
              ignoreRules:
                - .git
                - node_modules
                - vendor
            """.utf8
        ).write(to: path)
        let store = YAMLConfigurationStore(path: path)

        let reloaded = store.load()

        XCTAssertEqual(reloaded.defaultAgentCLI, .claude)
        XCTAssertEqual(
            reloaded.agent.launchDefaults.codex,
            AgentLaunchDefaultSettings(
                permissionModeID: "codex-on-request",
                additionalArguments: ["--model", "gpt-5"]
            )
        )
        XCTAssertEqual(reloaded.projects.globalChatsDirectory, "/tmp/yaaw-global")
        XCTAssertEqual(reloaded.fileIconPack, .catppuccin)
        XCTAssertEqual(reloaded.fileBrowser.markdownAndHTMLDefault, .editor)
        XCTAssertEqual(reloaded.fonts.interfaceFamily, "Avenir Next")
        XCTAssertEqual(reloaded.fonts.interfaceSize, 14)
        XCTAssertEqual(reloaded.fonts.editorFamily, "SF Mono")
        XCTAssertEqual(reloaded.fonts.editorSize, 15)
        XCTAssertEqual(reloaded.fonts.terminalFamily, "JetBrains Mono")
        XCTAssertEqual(reloaded.fonts.terminalSize, 16)
        XCTAssertEqual(reloaded.shortcut(for: .toggleBottomTerminal).key, "k")
        XCTAssertEqual(
            reloaded.shortcut(for: .toggleBottomTerminal).modifiers, [.command, .option])
        XCTAssertEqual(reloaded.tools.editors.preferred, ["zed", "nvim"])
        XCTAssertEqual(reloaded.tools.externalOpen.defaultToolID, .vscode)
        XCTAssertEqual(reloaded.tools.externalOpen.preferredToolIDs, [.webstorm, .vscode, .finder])
        XCTAssertEqual(reloaded.tools.git.preferred, "tig")
        XCTAssertEqual(reloaded.tools.diff.fallback, ["delta", "--diff"])
        XCTAssertEqual(reloaded.tools.agents.codex, "codex-nightly")
        // An explicit ignoreRules list is now respected verbatim — defaults the
        // user omitted (e.g. .build) are NOT silently re-added.
        XCTAssertEqual(reloaded.ignoreRules, [".git", "node_modules", "vendor"])
        XCTAssertFalse(reloaded.ignoreRules.contains(".build"))
    }

    func testYAMLConfigurationRespectsExplicitIgnoreRulesWithoutReinjectingDefaults() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            fileIndexing:
              ignoreRules:
                - .git
                - node_modules
            """.utf8
        ).write(to: path)
        let store = YAMLConfigurationStore(path: path)

        let reloaded = store.load()

        XCTAssertEqual(reloaded.defaultAgentCLI, .codex)
        XCTAssertEqual(reloaded.tools.editors.preferred, ["nvim", "vim", "vi"])
        XCTAssertEqual(reloaded.tools.externalOpen.defaultToolID, .zed)
        XCTAssertEqual(
            reloaded.tools.externalOpen.preferredToolIDs, ExternalOpenSettings.defaultPreferred)
        // The user's explicit list is respected verbatim — omitted defaults stay omitted.
        XCTAssertEqual(reloaded.ignoreRules, [".git", "node_modules"])
        XCTAssertFalse(reloaded.ignoreRules.contains("dist"))
    }

    func testYAMLConfigurationSeedsDefaultIgnoreRulesWhenKeyAbsent() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            agent:
              default: codex
            """.utf8
        ).write(to: path)
        let store = YAMLConfigurationStore(path: path)

        let reloaded = store.load()

        // No ignoreRules key: defaults are seeded, including `worktrees` (each git worktree
        // is a full checkout, so it is collapsed and indexed lazily on expand).
        XCTAssertEqual(reloaded.ignoreRules, FileIndexingSettings.defaultIgnoreRules)
        XCTAssertTrue(reloaded.ignoreRules.contains("worktrees"))
    }

    func testYAMLConfigurationFallsBackForUnknownIconPackAndRecordsDiagnostic() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let recorder = RecordingDiagnosticEventRecorder()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            icons:
              fileBrowserPack: unsupported-icons
            """.utf8
        ).write(to: path)

        let reloaded = YAMLConfigurationStore(path: path, diagnosticRecorder: recorder).load()

        XCTAssertEqual(reloaded.fileIconPack, .material)
        XCTAssertEqual(reloaded.icons.fileBrowserPack, FileIconPack.material.rawValue)
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Configuration"
                    && $0.name == "unsupported_icon_pack"
                    && $0.metadata["requested"] == "unsupported-icons"
                    && $0.metadata["fallback"] == FileIconPack.material.rawValue
            }
        )
    }

    func testYAMLConfigurationRecoversMalformedFileAndRecordsDiagnostic() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let recorder = RecordingDiagnosticEventRecorder()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: path)

        let recovered = YAMLConfigurationStore(path: path, diagnosticRecorder: recorder).load()

        XCTAssertEqual(recovered, YAAWConfiguration())
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Configuration"
                    && $0.name == "settings_yaml_recovered"
                    && $0.metadata["path"] == path.path
            }
        )
    }
}
