import AppKit
import GhosttyTerminal
import SwiftUI
import XCTest
import YAAWKit

@testable import YAAWToolHostSupport

final class TerminalHostRenderingConfigurationTests: XCTestCase {
    func testDraculaColorsRenderThroughGhosttyThemeForBothAppearances() {
        let configuration = TerminalHostRenderingConfiguration.make(
            for: ThemeCatalog.defaultTheme,
            fontSize: 17,
            fontFamily: "JetBrains Mono"
        )

        XCTAssertEqual(configuration.terminalTheme.light, configuration.terminalTheme.dark)
        XCTAssertTrue(configuration.terminalTheme.light.rendered.contains("background = 282a36"))
        XCTAssertTrue(configuration.terminalTheme.light.rendered.contains("foreground = f8f8f2"))
        XCTAssertTrue(configuration.terminalTheme.light.rendered.contains("palette = 0=#21222c"))
        XCTAssertTrue(configuration.terminalTheme.light.rendered.contains("palette = 15=#ffffff"))

        let nonThemeConfig = configuration.terminalConfiguration.rendered
        XCTAssertTrue(nonThemeConfig.contains("font-size = 17"))
        XCTAssertTrue(nonThemeConfig.contains("font-family = JetBrains Mono"))
        XCTAssertTrue(nonThemeConfig.contains("window-padding-x = 0"))
        XCTAssertTrue(nonThemeConfig.contains("window-padding-y = 0"))
        XCTAssertFalse(nonThemeConfig.contains("background ="))
        XCTAssertFalse(nonThemeConfig.contains("foreground ="))
        XCTAssertFalse(nonThemeConfig.contains("palette ="))
    }

    @MainActor
    func testGhosttyStateUsesYAAWThemeEvenBeforeDarkAppearanceAdoption() {
        let configuration = TerminalHostRenderingConfiguration.make(
            for: ThemeCatalog.defaultTheme,
            fontSize: 15,
            fontFamily: nil
        )
        let state = TerminalViewState(
            theme: configuration.terminalTheme,
            terminalConfiguration: configuration.terminalConfiguration
        )

        XCTAssertEqual(state.effectiveColorScheme, .light)
        XCTAssertTrue(state.renderedConfig.contains("background = 282a36"))
        XCTAssertTrue(state.renderedConfig.contains("foreground = f8f8f2"))
        XCTAssertFalse(state.renderedConfig.contains("background = F7F7F7"))
        XCTAssertFalse(state.renderedConfig.contains("foreground = 000000"))

        state.adopt(colorScheme: .dark)

        XCTAssertEqual(state.effectiveColorScheme, .dark)
        XCTAssertTrue(state.renderedConfig.contains("background = 282a36"))
        XCTAssertTrue(state.renderedConfig.contains("foreground = f8f8f2"))
    }

    func testMakeForRenderingResolvesThemeAndFontFallbacks() throws {
        let resolved = TerminalHostRenderingConfiguration.make(
            for: IsolatedTerminalRendering(
                themeID: "dracula",
                terminalFontFamily: "Menlo",
                terminalFontSize: 17
            ))
        let expected = TerminalHostRenderingConfiguration.make(
            for: try XCTUnwrap(ThemeCatalog.theme(id: "dracula")),
            fontSize: 17,
            fontFamily: "Menlo"
        )
        XCTAssertEqual(
            resolved.terminalTheme.light.rendered, expected.terminalTheme.light.rendered)
        XCTAssertEqual(
            resolved.terminalConfiguration.rendered, expected.terminalConfiguration.rendered)
        XCTAssertEqual(resolved.appKitAppearanceName, expected.appKitAppearanceName)
        XCTAssertEqual(resolved.swiftUIColorScheme, expected.swiftUIColorScheme)

        // Unknown theme + nil font size fall back to the catalog default and
        // the default terminal size.
        let fallback = TerminalHostRenderingConfiguration.make(
            for: IsolatedTerminalRendering(themeID: "no-such-theme"))
        let fallbackExpected = TerminalHostRenderingConfiguration.make(
            for: ThemeCatalog.defaultTheme,
            fontSize: Float(FontSettings().terminalSize),
            fontFamily: nil
        )
        XCTAssertEqual(
            fallback.terminalTheme.light.rendered, fallbackExpected.terminalTheme.light.rendered)
        XCTAssertEqual(
            fallback.terminalConfiguration.rendered,
            fallbackExpected.terminalConfiguration.rendered)
    }

    @MainActor
    func testLiveRenderingUpdateAppliesNewThemeAndFontSize() throws {
        let initial = TerminalHostRenderingConfiguration.make(
            for: IsolatedTerminalRendering(themeID: "dracula", terminalFontSize: 15))
        let state = TerminalViewState(
            theme: initial.terminalTheme,
            terminalConfiguration: initial.terminalConfiguration
        )
        state.adopt(colorScheme: initial.swiftUIColorScheme)
        XCTAssertTrue(state.renderedConfig.contains("background = 282a36"))
        XCTAssertTrue(state.renderedConfig.contains("font-size = 15"))

        // The live-update path used by the helper's setRenderingConfiguration:
        // state mutators only, never view/state.configuration (surface rebuild).
        let lightTheme = try XCTUnwrap(ThemeCatalog.theme(id: "light-2026"))
        let updated = TerminalHostRenderingConfiguration.make(
            for: IsolatedTerminalRendering(themeID: "light-2026", terminalFontSize: 18))
        XCTAssertTrue(state.setTheme(updated.terminalTheme))
        XCTAssertTrue(state.setTerminalConfiguration(updated.terminalConfiguration))
        state.adopt(colorScheme: updated.swiftUIColorScheme)

        let lightBackground = lightTheme.hex(for: .background)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        XCTAssertTrue(state.renderedConfig.contains("background = \(lightBackground)"))
        XCTAssertFalse(state.renderedConfig.contains("background = 282a36"))
        XCTAssertTrue(state.renderedConfig.contains("font-size = 18"))
        XCTAssertFalse(state.renderedConfig.contains("font-size = 15"))
        XCTAssertEqual(state.effectiveColorScheme, .light)
    }

    func testPreferredAppearanceFollowsThemeColorScheme() throws {
        let darkConfiguration = TerminalHostRenderingConfiguration.make(
            for: try XCTUnwrap(ThemeCatalog.theme(id: "dracula")),
            fontSize: 14,
            fontFamily: nil
        )
        let lightConfiguration = TerminalHostRenderingConfiguration.make(
            for: try XCTUnwrap(ThemeCatalog.theme(id: "light-2026")),
            fontSize: 14,
            fontFamily: nil
        )

        XCTAssertEqual(darkConfiguration.appKitAppearanceName, .darkAqua)
        XCTAssertEqual(darkConfiguration.swiftUIColorScheme, .dark)
        XCTAssertEqual(lightConfiguration.appKitAppearanceName, .aqua)
        XCTAssertEqual(lightConfiguration.swiftUIColorScheme, .light)
    }
}
