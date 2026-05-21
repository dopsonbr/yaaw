import XCTest
@testable import YAAWKit

final class RightPanelModeTests: XCTestCase {
    func testRightPanelModeCyclesForwardInRequiredOrder() {
        XCTAssertEqual(RightPanelMode.files.next, .git)
        XCTAssertEqual(RightPanelMode.git.next, .nvim)
        XCTAssertEqual(RightPanelMode.nvim.next, .files)
    }

    func testRightPanelModeCyclesBackwardInRequiredOrder() {
        XCTAssertEqual(RightPanelMode.files.previous, .nvim)
        XCTAssertEqual(RightPanelMode.git.previous, .files)
        XCTAssertEqual(RightPanelMode.nvim.previous, .git)
    }
}
