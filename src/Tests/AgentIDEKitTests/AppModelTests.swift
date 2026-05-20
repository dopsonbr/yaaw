import XCTest
@testable import AgentIDEKit

final class AppModelTests: XCTestCase {
    func testGlobalTerminalStartsCollapsed() {
        let model = AppModel()

        XCTAssertFalse(model.isGlobalTerminalExpanded)
    }

    func testToggleGlobalTerminalChangesVisibleState() {
        let model = AppModel()

        model.toggleGlobalTerminal()

        XCTAssertTrue(model.isGlobalTerminalExpanded)
    }

    func testRightPanelModeSelectionIsPublicBehavior() {
        let model = AppModel()

        model.selectRightPanelMode(.git)

        XCTAssertEqual(model.selectedRightPanelMode, .git)
    }
}
