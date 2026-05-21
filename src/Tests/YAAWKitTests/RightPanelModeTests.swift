import XCTest
@testable import YAAWKit

final class RightPanelModeTests: XCTestCase {
    func testRightPanelModeCyclesForwardInRequiredOrder() {
        XCTAssertEqual(RightPanelMode.files.next, .nvim)
        XCTAssertEqual(RightPanelMode.nvim.next, .git)
        XCTAssertEqual(RightPanelMode.git.next, .files)
    }

    func testRightPanelModeCyclesBackwardInRequiredOrder() {
        XCTAssertEqual(RightPanelMode.files.previous, .git)
        XCTAssertEqual(RightPanelMode.git.previous, .nvim)
        XCTAssertEqual(RightPanelMode.nvim.previous, .files)
    }
}
