import XCTest

@testable import YAAWKit

final class DraculaThemeTests: XCTestCase {
    func testThemeCatalogExposesSupportedThemesWithDraculaDefault() {
        XCTAssertEqual(ThemeCatalog.defaultID, "dracula")
        XCTAssertEqual(ThemeCatalog.defaultTheme.id, "dracula")
        XCTAssertEqual(
            ThemeCatalog.supportedIDs,
            [
                "light-2026",
                "light-modern",
                "light-plus",
                "quiet-light",
                "solarized-light",
                "dracula",
                "dark-2026",
                "dark-plus",
                "dark-modern",
                "monokai",
                "solarized-dark",
                "dark-high-contrast",
                "light-high-contrast",
            ]
        )
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
            ThemeCatalog.defaultTheme.terminalANSIPalette,
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
