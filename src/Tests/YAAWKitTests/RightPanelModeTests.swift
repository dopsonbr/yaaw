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
        let tab = RightPanelTab.browser(
            urlString: "https://www.example.com/docs/user-guide/README.html?debug=true")

        XCTAssertEqual(tab.title, "example.com/docs/user-guide")
    }

    func testBrowserTabTitleUsesPreviewFileName() {
        let tab = RightPanelTab.browser(
            urlString: "file:///Users/example/project/docs/index.html",
            relativePath: "docs/index.html")

        XCTAssertEqual(tab.title, "index.html")
    }

    func testClosingSelectedNvimTabFallsBackToDefaultNvimTab() {
        var state = RightPanelState.defaultState(selectedMode: .files)
        let tab = state.openNvimTab(relativePath: "src/App/RootView.swift")

        XCTAssertEqual(state.closeTab(id: tab.id), tab)

        XCTAssertFalse(state.tabs.contains(tab))
        XCTAssertEqual(state.selectedTabID, RightPanelTab.defaultNvimID)
        XCTAssertEqual(state.selectedMode, .nvim)
    }

    func testClosingSelectedBrowserTabFallsBackToNearestBrowserTab() {
        var state = RightPanelState.defaultState(selectedMode: .files)
        let first = state.openBrowserTab(urlString: "https://example.com/docs")
        let second = state.openBrowserTab(urlString: "https://example.com/status")
        state.selectTab(id: first.id)

        XCTAssertEqual(state.closeTab(id: first.id), first)

        XCTAssertFalse(state.tabs.contains(first))
        XCTAssertTrue(state.tabs.contains(second))
        XCTAssertEqual(state.selectedTabID, second.id)
        XCTAssertEqual(state.selectedMode, .browser)
    }

    func testPinnedRightPanelTabsCannotBeClosed() {
        var state = RightPanelState.defaultState(selectedMode: .git)

        XCTAssertNil(state.closeTab(id: RightPanelTab.filesID))
        XCTAssertNil(state.closeTab(id: RightPanelTab.defaultBrowserID))
        XCTAssertNil(state.closeTab(id: RightPanelTab.gitID))
        XCTAssertNil(state.closeTab(id: RightPanelTab.defaultNvimID))

        XCTAssertEqual(state.tabs, RightPanelState.defaultTabs)
        XCTAssertEqual(state.selectedTabID, RightPanelTab.gitID)
    }

    func testClosingUnselectedTabKeepsCurrentSelection() {
        var state = RightPanelState.defaultState(selectedMode: .files)
        let browserTab = state.openBrowserTab(urlString: "https://example.com/docs")
        let nvimTab = state.openNvimTab(relativePath: "README.md")

        XCTAssertEqual(state.selectedTabID, nvimTab.id)
        XCTAssertEqual(state.closeTab(id: browserTab.id), browserTab)

        XCTAssertEqual(state.selectedTabID, nvimTab.id)
        XCTAssertEqual(state.selectedMode, .nvim)
    }
}
