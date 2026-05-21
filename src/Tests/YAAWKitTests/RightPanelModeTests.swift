import XCTest
@testable import YAAWKit

final class RightPanelModeTests: XCTestCase {
    func testRightPanelModeCyclesForwardInRequiredOrder() {
        XCTAssertEqual(RightPanelMode.files.next, .browser)
        XCTAssertEqual(RightPanelMode.browser.next, .git)
        XCTAssertEqual(RightPanelMode.git.next, .nvim)
        XCTAssertEqual(RightPanelMode.nvim.next, .files)
    }

    func testRightPanelModeCyclesBackwardInRequiredOrder() {
        XCTAssertEqual(RightPanelMode.files.previous, .nvim)
        XCTAssertEqual(RightPanelMode.browser.previous, .files)
        XCTAssertEqual(RightPanelMode.git.previous, .browser)
        XCTAssertEqual(RightPanelMode.nvim.previous, .git)
    }

    func testNvimTabTitleUsesOpenedFileName() {
        let tab = RightPanelTab.nvim(relativePath: "docs/user-guide/README.md")

        XCTAssertEqual(tab.title, "README.md")
    }

    func testBrowserTabTitleUsesReadableShortURL() {
        let tab = RightPanelTab.browser(urlString: "https://www.example.com/docs/user-guide/README.html?debug=true")

        XCTAssertEqual(tab.title, "example.com/docs/user-guide")
    }

    func testBrowserTabTitleUsesPreviewFileName() {
        let tab = RightPanelTab.browser(urlString: "file:///Users/example/project/docs/index.html", relativePath: "docs/index.html")

        XCTAssertEqual(tab.title, "index.html")
    }
}
