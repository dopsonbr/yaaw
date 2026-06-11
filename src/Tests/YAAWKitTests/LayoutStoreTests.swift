import XCTest

@testable import YAAWKit

/// Layout + resize + bottom-terminal parity, re-pointed from `AppModelTests` onto
/// `LayoutStore`.
final class LayoutStoreTests: XCTestCase {
    @MainActor
    func testBottomTerminalStartsCollapsed() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        XCTAssertFalse(harness.layout.isBottomTerminalExpanded)
    }

    @MainActor
    func testToggleBottomTerminalChangesSelectedThreadVisibleState() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        harness.layout.toggleBottomTerminal()
        XCTAssertTrue(harness.layout.isBottomTerminalExpanded)
    }

    @MainActor
    func testPanelCollapseActionsUpdateLayoutState() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        harness.layout.toggleSidebarCollapsed()
        harness.layout.toggleRightPanelCollapsed()
        XCTAssertTrue(harness.layout.layoutState.isSidebarCollapsed)
        XCTAssertTrue(harness.layout.layoutState.isRightPanelCollapsed)
        XCTAssertFalse(harness.layout.layoutState.isWorkspaceSwapped)
    }

    @MainActor
    func testWorkspaceSwapActionUpdatesLayoutState() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        harness.layout.toggleWorkspaceSwap()
        XCTAssertTrue(harness.layout.layoutState.isWorkspaceSwapped)
    }

    @MainActor
    func testPanelResizeActionsClampLayoutState() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        harness.layout.setSidebarWidth(10)
        harness.layout.setRightPanelWidth(10)
        harness.layout.setGlobalTerminalHeight(1_000)
        XCTAssertEqual(harness.layout.layoutState.sidebarWidth, LayoutState.minimumSidebarWidth)
        XCTAssertEqual(
            harness.layout.layoutState.rightPanelWidth, LayoutState.minimumRightPanelWidth)
        XCTAssertEqual(
            harness.layout.layoutState.globalTerminalHeight, LayoutState.maximumGlobalTerminalHeight
        )
    }

    @MainActor
    func testPanelResizeActionsUseExpandedPanelLimits() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        harness.layout.setSidebarWidth(600)
        harness.layout.setRightPanelWidth(1_200)
        harness.layout.setGlobalTerminalHeight(400)
        XCTAssertEqual(harness.layout.layoutState.sidebarWidth, 520)
        XCTAssertEqual(harness.layout.layoutState.rightPanelWidth, 1_200)
        XCTAssertEqual(harness.layout.layoutState.globalTerminalHeight, 400)
    }

    @MainActor
    func testBottomTerminalHeightClampsToWindowRatioWhenProvided() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        harness.layout.setGlobalTerminalHeight(300, availableWindowHeight: 600)
        XCTAssertEqual(harness.layout.layoutState.globalTerminalHeight, 270)
    }

    @MainActor
    func testPanelResizeCanUpdateLiveWithoutPersistingEveryDragTick() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        harness.layout.setSidebarWidth(300, persist: false)
        harness.layout.setRightPanelWidth(500, persist: false)
        harness.layout.setGlobalTerminalHeight(220, persist: false)
        await harness.flush()
        let writesBeforeCommit = await harness.store.layoutStateWriteCount
        XCTAssertEqual(writesBeforeCommit, 0)
        XCTAssertEqual(harness.layout.layoutState.sidebarWidth, 300)
        XCTAssertEqual(harness.layout.layoutState.rightPanelWidth, 500)
        XCTAssertEqual(harness.layout.layoutState.globalTerminalHeight, 220)

        harness.layout.commitLayoutResize()
        await harness.flush()
        let writesAfterCommit = await harness.store.layoutStateWriteCount
        XCTAssertEqual(writesAfterCommit, 1)
    }

    @MainActor
    func testWorkspaceSwapActionPersistsLayoutState() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        harness.layout.toggleWorkspaceSwap()
        await harness.flush()
        XCTAssertTrue(harness.layout.layoutState.isWorkspaceSwapped)
        let writeCount = await harness.store.layoutStateWriteCount
        XCTAssertEqual(writeCount, 1)
        let reloaded = await harness.store.load()
        XCTAssertTrue(reloaded.layoutState.isWorkspaceSwapped)
    }

    @MainActor
    func testPanelSizeResetActionsPersistDefaults() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        harness.layout.setSidebarWidth(400)
        harness.layout.setRightPanelWidth(600)
        harness.layout.setGlobalTerminalHeight(260)
        await harness.flush()
        let writesAfterResize = await harness.store.layoutStateWriteCount

        harness.layout.resetSidebarWidth()
        harness.layout.resetRightPanelWidth()
        harness.layout.resetGlobalTerminalHeight()
        await harness.flush()

        XCTAssertEqual(harness.layout.layoutState.sidebarWidth, LayoutState.defaultSidebarWidth)
        XCTAssertEqual(
            harness.layout.layoutState.rightPanelWidth, LayoutState.defaultRightPanelWidth)
        XCTAssertEqual(
            harness.layout.layoutState.globalTerminalHeight, LayoutState.defaultGlobalTerminalHeight
        )
        let writesAfterReset = await harness.store.layoutStateWriteCount
        XCTAssertEqual(writesAfterReset, writesAfterResize + 3)
    }

    @MainActor
    func testBottomTerminalToggleDoesNotMutateSidebarOrSelection() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        let sidebarWidth = harness.layout.layoutState.sidebarWidth
        let projectID = harness.workspace.selectedProjectID
        let threadID = harness.workspace.selectedThreadID

        harness.layout.toggleBottomTerminal()

        XCTAssertEqual(harness.layout.layoutState.sidebarWidth, sidebarWidth)
        XCTAssertFalse(harness.layout.layoutState.isSidebarCollapsed)
        XCTAssertEqual(harness.workspace.selectedProjectID, projectID)
        XCTAssertEqual(harness.workspace.selectedThreadID, threadID)
        XCTAssertTrue(harness.layout.isBottomTerminalExpanded)
    }
}
