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
