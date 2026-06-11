import XCTest

@testable import YAAWKit

/// Configuration / theme / appearance / keyboard-shortcut parity, re-pointed from
/// `AppModelTests` (and the deferred `KeyboardShortcutEventMatchingTests`) onto
/// `SettingsStore`.
final class SettingsStoreTests: XCTestCase {
    @MainActor
    func testReloadConfigurationAppliesThemeAndRecordsDiagnostic() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        harness.settings.reloadConfiguration(
            YAAWConfiguration(theme: ThemeSettings(active: "solarized-light")))

        XCTAssertEqual(harness.settings.configuration.themeName, "solarized-light")
        XCTAssertEqual(harness.settings.resolvedTheme.displayName, "Solarized Light")
        XCTAssertTrue(
            harness.diagnosticRecorder.events.contains {
                $0.category == "Configuration" && $0.name == "settings_yaml_reloaded"
                    && $0.metadata["theme"] == "solarized-light"
            })
    }

    @MainActor
    func testSystemAppearanceDrivesResolvedThemeForSystemMode() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(),
            configuration: YAAWConfiguration(theme: ThemeSettings(active: "system")),
            systemAppearanceIsDark: true)

        XCTAssertEqual(harness.settings.resolvedTheme.id, "macos-dark")
        harness.settings.updateSystemAppearance(isDark: false)
        XCTAssertEqual(harness.settings.resolvedTheme.id, "macos-light")

        harness.settings.reloadConfiguration(
            YAAWConfiguration(theme: ThemeSettings(active: "dracula")))
        harness.settings.updateSystemAppearance(isDark: true)
        XCTAssertEqual(harness.settings.resolvedTheme.id, "dracula")
    }

    @MainActor
    func testUpdateSystemAppearanceIgnoresRedundantFlips() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), systemAppearanceIsDark: false)

        harness.settings.updateSystemAppearance(isDark: false)
        XCTAssertFalse(harness.settings.systemAppearanceIsDark)
        harness.settings.updateSystemAppearance(isDark: true)
        XCTAssertTrue(harness.settings.systemAppearanceIsDark)
    }

    @MainActor
    func testReloadConfigurationAppliesFontsAndRecordsDiagnostic() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        harness.settings.reloadConfiguration(
            YAAWConfiguration(
                fonts: FontSettings(
                    interfaceFamily: "Avenir Next", interfaceSize: 14, editorFamily: "SF Mono",
                    editorSize: 15, terminalFamily: "JetBrains Mono", terminalSize: 16)))

        XCTAssertEqual(harness.settings.configuration.fonts.interfaceFamily, "Avenir Next")
        XCTAssertEqual(harness.settings.configuration.fonts.interfaceSize, 14)
        XCTAssertEqual(harness.settings.configuration.fonts.editorFamily, "SF Mono")
        XCTAssertEqual(harness.settings.configuration.fonts.editorSize, 15)
        XCTAssertEqual(harness.settings.configuration.fonts.terminalFamily, "JetBrains Mono")
        XCTAssertEqual(harness.settings.configuration.fonts.terminalSize, 16)
        XCTAssertTrue(
            harness.diagnosticRecorder.events.contains {
                $0.category == "Configuration" && $0.name == "settings_yaml_reloaded"
                    && $0.metadata["interface_font_size"] == "14.0"
                    && $0.metadata["editor_font_size"] == "15.0"
                    && $0.metadata["terminal_font_size"] == "16.0"
            })
    }

    /// Re-homed from Chunk 0's deferred `KeyboardShortcutEventMatchingTests`:
    /// unbound and duplicate-bound shortcuts are disabled.
    @MainActor
    func testStoreDisablesUnboundAndDuplicateShortcuts() async {
        let fixture = StoreFixture()
        var shortcuts = KeyboardShortcutSettings()
        // Unbind one action and force a duplicate binding between two others.
        shortcuts.setDefinition(
            KeyboardShortcutDefinition(key: "", modifiers: []), for: .toggleSidebar)
        let duplicateChord = KeyboardShortcutDefinition(key: "j", modifiers: [.command])
        shortcuts.setDefinition(duplicateChord, for: .nextRightPanelMode)
        shortcuts.setDefinition(duplicateChord, for: .previousRightPanelMode)
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(),
            configuration: YAAWConfiguration(keyboardShortcuts: shortcuts))

        XCTAssertFalse(harness.settings.isKeyboardShortcutEnabled(for: .toggleSidebar))
        XCTAssertFalse(harness.settings.isKeyboardShortcutEnabled(for: .nextRightPanelMode))
        XCTAssertFalse(harness.settings.isKeyboardShortcutEnabled(for: .previousRightPanelMode))
        // A uniquely-bound action stays enabled.
        XCTAssertTrue(harness.settings.isKeyboardShortcutEnabled(for: .newThread))
    }
}
