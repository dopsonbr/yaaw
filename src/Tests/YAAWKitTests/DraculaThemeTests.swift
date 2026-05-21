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
                "light-high-contrast"
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

    private func isValidHexColor(_ value: String) -> Bool {
        guard value.count == 7, value.first == "#" else { return false }
        return value.dropFirst().allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character.lowercased())
        }
    }
}
