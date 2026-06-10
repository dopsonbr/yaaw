import XCTest

@testable import YAAWKit

final class DraculaThemeTests: XCTestCase {
    func testThemeCatalogExposesSupportedThemesWithGhosttyDefault() {
        XCTAssertEqual(ThemeCatalog.defaultID, "ghostty-default")
        XCTAssertEqual(ThemeCatalog.defaultTheme.id, "ghostty-default")
        XCTAssertEqual(
            ThemeCatalog.supportedIDs,
            [
                "macos-light",
                "light-2026",
                "light-modern",
                "light-plus",
                "quiet-light",
                "solarized-light",
                "macos-dark",
                "dracula",
                "ghostty-default",
                "dark-2026",
                "dark-plus",
                "dark-modern",
                "monokai",
                "solarized-dark",
                "dark-high-contrast",
                "light-high-contrast",
            ]
        )
        XCTAssertEqual(ThemeCatalog.defaultLightID, "macos-light")
        XCTAssertEqual(ThemeCatalog.defaultDarkID, "macos-dark")
    }

    func testEveryBuiltInThemeHasRequiredValidHexTokens() {
        for theme in ThemeCatalog.themes {
            XCTAssertEqual(Set(theme.tokens.map(\.role)), Set(ThemeRole.allCases), theme.id)
            for role in ThemeRole.allCases {
                XCTAssertTrue(isValidHexColor(theme.hex(for: role)), "\(theme.id) \(role.rawValue)")
            }
        }
    }

    func testEveryBuiltInThemeExposesTerminalANSIPalette() {
        for theme in ThemeCatalog.themes {
            XCTAssertEqual(theme.terminalANSIPalette.count, 16, theme.id)
            for color in theme.terminalANSIPalette {
                XCTAssertTrue(isValidHexColor(color), "\(theme.id) \(color)")
            }
        }
    }

    func testEveryBuiltInThemeExposesValidUIColors() {
        for theme in ThemeCatalog.themes {
            for role in ThemeUIRole.allCases {
                XCTAssertTrue(
                    isValidHexColor(theme.uiHex(for: role)), "\(theme.id) \(role.rawValue)")
            }
        }
    }

    func testPreferredColorSchemeFollowsThemeGroup() {
        XCTAssertEqual(ThemeCatalog.theme(id: "dracula")?.preferredColorScheme, .dark)
        XCTAssertEqual(ThemeCatalog.theme(id: "dark-2026")?.preferredColorScheme, .dark)
        XCTAssertEqual(ThemeCatalog.theme(id: "dark-high-contrast")?.preferredColorScheme, .dark)
        XCTAssertEqual(ThemeCatalog.theme(id: "light-2026")?.preferredColorScheme, .light)
        XCTAssertEqual(ThemeCatalog.theme(id: "light-high-contrast")?.preferredColorScheme, .light)
    }

    func testDraculaSecondaryUILabelMeetsTextContrast() {
        let theme = ThemeCatalog.defaultTheme
        XCTAssertGreaterThanOrEqual(
            contrastRatio(theme.uiHex(for: .secondaryLabel), theme.hex(for: .background)),
            4.5
        )
    }

    func testDraculaThemeExposesExpectedInitialTokens() {
        XCTAssertEqual(DraculaTheme.hex(for: .background), "#282a36")
        XCTAssertEqual(DraculaTheme.hex(for: .currentLine), "#44475a")
        XCTAssertEqual(DraculaTheme.hex(for: .foreground), "#f8f8f2")
        XCTAssertEqual(DraculaTheme.hex(for: .comment), "#6272a4")
        XCTAssertEqual(DraculaTheme.hex(for: .cyan), "#8be9fd")
        XCTAssertEqual(DraculaTheme.hex(for: .green), "#50fa7b")
        XCTAssertEqual(DraculaTheme.hex(for: .orange), "#ffb86c")
        XCTAssertEqual(DraculaTheme.hex(for: .pink), "#ff79c6")
        XCTAssertEqual(DraculaTheme.hex(for: .purple), "#bd93f9")
        XCTAssertEqual(DraculaTheme.hex(for: .red), "#ff5555")
        XCTAssertEqual(DraculaTheme.hex(for: .yellow), "#f1fa8c")
    }

    func testDraculaTerminalANSIPaletteMatchesCanonicalTerminalColors() {
        XCTAssertEqual(
            ThemeCatalog.theme(id: "dracula")?.terminalANSIPalette,
            [
                "#21222c",
                "#ff5555",
                "#50fa7b",
                "#f1fa8c",
                "#bd93f9",
                "#ff79c6",
                "#8be9fd",
                "#f8f8f2",
                "#6272a4",
                "#ff6e6e",
                "#69ff94",
                "#ffffa5",
                "#d6acff",
                "#ff92df",
                "#a4ffff",
                "#ffffff",
            ]
        )
    }

    func testMacOSThemesExposeAppleSystemTokens() throws {
        let light = try XCTUnwrap(ThemeCatalog.theme(id: "macos-light"))
        XCTAssertEqual(light.group, .light)
        XCTAssertEqual(light.hex(for: .background), "#f5f5f7")
        XCTAssertEqual(light.hex(for: .currentLine), "#e3e3e8")
        XCTAssertEqual(light.hex(for: .foreground), "#1d1d1f")
        XCTAssertEqual(light.hex(for: .comment), "#6e6e73")
        XCTAssertEqual(light.hex(for: .cyan), "#007aff")

        let dark = try XCTUnwrap(ThemeCatalog.theme(id: "macos-dark"))
        XCTAssertEqual(dark.group, .dark)
        XCTAssertEqual(dark.hex(for: .background), "#1e1e1e")
        XCTAssertEqual(dark.hex(for: .currentLine), "#2d2d2d")
        XCTAssertEqual(dark.hex(for: .foreground), "#f5f5f7")
        XCTAssertEqual(dark.hex(for: .comment), "#98989d")
        XCTAssertEqual(dark.hex(for: .cyan), "#0a84ff")
    }

    func testMacOSThemesExposeExplicitANSIPalettes() throws {
        let light = try XCTUnwrap(ThemeCatalog.theme(id: "macos-light"))
        XCTAssertEqual(
            light.terminalANSIPalette,
            [
                "#1d1d1f", "#d70015", "#248a3d", "#946300",
                "#0040dd", "#8944ab", "#0071a4", "#e3e3e8",
                "#6e6e73", "#ff3b30", "#34c759", "#ffcc00",
                "#007aff", "#af52de", "#30b0c7", "#ffffff",
            ]
        )

        let dark = try XCTUnwrap(ThemeCatalog.theme(id: "macos-dark"))
        XCTAssertEqual(
            dark.terminalANSIPalette,
            [
                "#1e1e1e", "#ff453a", "#32d74b", "#ffd60a",
                "#0a84ff", "#bf5af2", "#64d2ff", "#d1d1d6",
                "#58585e", "#ff6961", "#30db5b", "#ffd426",
                "#409cff", "#da8fff", "#70d7ff", "#f5f5f7",
            ]
        )
    }

    func testMacOSThemesMeetTextContrast() throws {
        for id in ["macos-light", "macos-dark"] {
            let theme = try XCTUnwrap(ThemeCatalog.theme(id: id))
            XCTAssertGreaterThanOrEqual(
                contrastRatio(theme.hex(for: .foreground), theme.hex(for: .background)),
                7, id
            )
            XCTAssertGreaterThanOrEqual(
                contrastRatio(theme.uiHex(for: .secondaryLabel), theme.hex(for: .background)),
                4.5, id
            )
        }
    }

    func testMaterialTintFollowsThemeKind() throws {
        let light = try XCTUnwrap(ThemeCatalog.theme(id: "macos-light"))
        let dark = try XCTUnwrap(ThemeCatalog.theme(id: "macos-dark"))
        XCTAssertTrue(light.prefersSystemMaterials)
        XCTAssertTrue(dark.prefersSystemMaterials)
        // System-palette themes keep the tint too: bare material washes out
        // the theme-token selection pills.
        XCTAssertEqual(light.materialTintOpacity, 0.7)
        XCTAssertEqual(dark.materialTintOpacity, 0.7)

        let dracula = try XCTUnwrap(ThemeCatalog.theme(id: "dracula"))
        XCTAssertFalse(dracula.prefersSystemMaterials)
        XCTAssertEqual(dracula.materialTintOpacity, 0.7)
        XCTAssertEqual(dracula.materialTintHex, dracula.hex(for: .background))

        let highContrast = try XCTUnwrap(ThemeCatalog.theme(id: "dark-high-contrast"))
        XCTAssertEqual(highContrast.materialTintOpacity, 1.0)
    }

    func testGhosttyDefaultKeepsExplicitANSIPalette() throws {
        let theme = try XCTUnwrap(ThemeCatalog.theme(id: "ghostty-default"))
        XCTAssertEqual(theme.terminalANSIPalette.first, "#1d1f21")
        XCTAssertEqual(theme.terminalANSIPalette.last, "#eaeaea")
        XCTAssertEqual(theme.terminalANSIPalette.count, 16)
    }

    private func isValidHexColor(_ value: String) -> Bool {
        guard value.count == 7, value.first == "#" else { return false }
        return value.dropFirst().allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character.lowercased())
        }
    }

    private func contrastRatio(_ firstHex: String, _ secondHex: String) -> Double {
        let firstLuminance = relativeLuminance(firstHex)
        let secondLuminance = relativeLuminance(secondHex)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ hex: String) -> Double {
        let components = rgbComponents(hex)
        return 0.2126 * components.red + 0.7152 * components.green + 0.0722 * components.blue
    }

    private func rgbComponents(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        let scanner = Scanner(string: value)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        return (
            red: linearizedColorComponent(Double((rgb >> 16) & 0xff) / 255.0),
            green: linearizedColorComponent(Double((rgb >> 8) & 0xff) / 255.0),
            blue: linearizedColorComponent(Double(rgb & 0xff) / 255.0)
        )
    }

    private func linearizedColorComponent(_ component: Double) -> Double {
        component <= 0.03928
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
