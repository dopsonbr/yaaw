import XCTest

@testable import YAAWKit

final class ThemeConfigurationTests: PersistenceTestCase {
    func testYAMLConfigurationAcceptsSupportedTheme() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let configuration = try store.validate(
            text: """
                version: 1
                theme:
                  active: dark-plus
                """
        )

        XCTAssertEqual(configuration.themeName, "dark-plus")
        XCTAssertEqual(
            configuration.resolvedTheme(systemAppearanceIsDark: true).displayName, "Dark+")
    }

    func testYAMLConfigurationLegacyFixedThemeKeepsWorkingWithoutPairingKeys() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let configuration = try store.validate(
            text: """
                version: 1
                theme:
                  active: dracula
                """
        )

        XCTAssertEqual(configuration.theme.mode, .fixed("dracula"))
        // A fixed theme ignores the system appearance entirely.
        XCTAssertEqual(
            configuration.resolvedTheme(systemAppearanceIsDark: true).id, "dracula")
        XCTAssertEqual(
            configuration.resolvedTheme(systemAppearanceIsDark: false).id, "dracula")
        // Absent pairing keys decode to the defaults.
        XCTAssertEqual(configuration.theme.light, "macos-light")
        XCTAssertEqual(configuration.theme.dark, "macos-dark")
    }

    func testYAMLConfigurationSystemThemeFollowsAppearance() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let defaulted = try store.validate(text: "version: 1")
        XCTAssertEqual(defaulted.theme.mode, .system)
        XCTAssertEqual(defaulted.resolvedTheme(systemAppearanceIsDark: false).id, "macos-light")
        XCTAssertEqual(defaulted.resolvedTheme(systemAppearanceIsDark: true).id, "macos-dark")

        let paired = try store.validate(
            text: """
                version: 1
                theme:
                  active: system
                  light: solarized-light
                  dark: dracula
                """
        )
        XCTAssertEqual(paired.resolvedTheme(systemAppearanceIsDark: false).id, "solarized-light")
        XCTAssertEqual(paired.resolvedTheme(systemAppearanceIsDark: true).id, "dracula")
    }

    func testYAMLConfigurationSystemThemeRoundTripsThroughSave() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        try store.save(
            YAAWConfiguration(
                theme: ThemeSettings(active: "system", light: "quiet-light", dark: "monokai")))
        let saved = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("active: system"))
        XCTAssertTrue(saved.contains("light: quiet-light"))
        XCTAssertTrue(saved.contains("dark: monokai"))

        let reloaded = store.load()
        XCTAssertEqual(reloaded.theme.mode, .system)
        XCTAssertEqual(reloaded.theme.light, "quiet-light")
        XCTAssertEqual(reloaded.theme.dark, "monokai")
    }

    func testYAMLConfigurationFallsBackForUnknownThemeAndRecordsDiagnostic() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let recorder = RecordingDiagnosticEventRecorder()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            theme:
              active: unknown-theme
            """.utf8
        ).write(to: path)

        let reloaded = YAMLConfigurationStore(path: path, diagnosticRecorder: recorder).load()

        XCTAssertEqual(reloaded.themeName, ThemeSettings.systemActiveID)
        XCTAssertEqual(reloaded.theme.mode, .system)
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Configuration"
                    && $0.name == "unsupported_theme"
                    && $0.metadata["requested"] == "unknown-theme"
                    && $0.metadata["fallback"] == ThemeSettings.systemActiveID
            }
        )
    }
}
