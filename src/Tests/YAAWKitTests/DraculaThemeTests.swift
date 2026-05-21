import XCTest
@testable import YAAWKit

final class DraculaThemeTests: XCTestCase {
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
}
