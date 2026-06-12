import XCTest

@testable import YAAWKit

/// Right-panel mode/tab, open-in-nvim/browser, and file-browser parity, re-pointed
/// from `AppModelTests` onto `RightPanelStore` (+ `ActivityStore` for the browser).
final class RightPanelStoreTests: XCTestCase {
    @MainActor
    private func makeHarness(
        externalToolResolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> StoreHarness {
        let fixture = StoreFixture()
        return await StoreHarnessBuilder.make(
            store: fixture.makeStore(),
            externalToolResolver: externalToolResolver,
            environment: environment)
    }

    @MainActor
    func testRightPanelModeSelectionIsPublicBehavior() async {
        let harness = await makeHarness()
        harness.rightPanel.selectRightPanelMode(.git)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, .git)
    }

    @MainActor
    func testRightPanelModeIsScopedToSelectedThread() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        harness.rightPanel.selectRightPanelMode(.git)
        harness.workspace.selectThread(id: fixture.secondThreadID)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, .files)
        harness.workspace.selectThread(id: fixture.firstThreadID)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, .git)
    }

    @MainActor
    func testRightPanelTabOrderKeepsFilesGitNvimTabsThenPlusSlot() async {
        let harness = await makeHarness()
        harness.rightPanel.openFileInNvim(relativePath: "README.md")
        harness.rightPanel.openFileInNvim(relativePath: "src/App/RootView.swift")
        XCTAssertEqual(
            harness.rightPanel.selectedRightPanelState.tabs.map(\.id),
            [
                RightPanelTab.filesID, RightPanelTab.defaultBrowserID, RightPanelTab.gitID,
                RightPanelTab.defaultNvimID, RightPanelTab.nvimTabID(relativePath: "README.md"),
                RightPanelTab.nvimTabID(relativePath: "src/App/RootView.swift"),
            ])
    }

    @MainActor
    func testClosingSelectedBrowserTabRemovesItAndSelectsDefaultBrowserTab() async {
        let harness = await makeHarness()
        harness.rightPanel.openBrowserTab(urlString: "example.com/docs")
        let tabID = harness.rightPanel.selectedRightPanelTab.id
        harness.rightPanel.closeRightPanelTab(id: tabID)
        XCTAssertFalse(harness.rightPanel.selectedRightPanelState.tabs.contains { $0.id == tabID })
        XCTAssertEqual(harness.rightPanel.selectedRightPanelTab.id, RightPanelTab.defaultBrowserID)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, .browser)
    }

    @MainActor
    func testClosingSelectedNvimTabRemovesItAndSelectsDefaultNvimTab() async {
        let harness = await makeHarness()
        harness.rightPanel.openFileInNvim(relativePath: "README.md")
        let tabID = RightPanelTab.nvimTabID(relativePath: "README.md")
        harness.rightPanel.closeRightPanelTab(id: tabID)
        XCTAssertFalse(harness.rightPanel.selectedRightPanelState.tabs.contains { $0.id == tabID })
        XCTAssertEqual(harness.rightPanel.selectedRightPanelTab.id, RightPanelTab.defaultNvimID)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, .nvim)
    }

    @MainActor
    func testOpeningFileSwitchesToNvimAndUsesRelativePath() async throws {
        let fixture = StoreFixture()
        let resolver = StaticExecutableResolver(paths: ["nvim": "/tools/nvim"])
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), externalToolResolver: resolver, environment: [:])

        harness.rightPanel.openFileInNvim(relativePath: "src/App/RootView.swift")
        let tabID = RightPanelTab.nvimTabID(relativePath: "src/App/RootView.swift")
        let launchResult = await harness.workspace.surfaceLaunch(
            for: .nvimTab(threadID: fixture.firstThreadID, tabID: tabID))
        let launch = try XCTUnwrap(launchResult)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, .nvim)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelTab.id, tabID)
        XCTAssertEqual(launch.workingDirectory, fixture.root)
        XCTAssertEqual(launch.command, ["/tools/nvim", "src/App/RootView.swift"])
    }

    @MainActor
    func testOpeningEscapingFileInNvimDoesNotChangeRightPanelState() async {
        let resolver = StaticExecutableResolver(paths: ["nvim": "/tools/nvim"])
        let harness = await makeHarness(externalToolResolver: resolver, environment: [:])
        let originalSelectedFile = harness.rightPanel.selectedFileRelativePath
        let originalMode = harness.rightPanel.selectedRightPanelMode
        let originalState = harness.rightPanel.selectedRightPanelState

        harness.rightPanel.openFileInNvim(relativePath: "../outside.swift")

        XCTAssertEqual(harness.rightPanel.selectedFileRelativePath, originalSelectedFile)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, originalMode)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelState, originalState)
    }

    @MainActor
    func testOpeningSupportedFileInBrowserUsesFileURLAndStaysInWorkingDirectory() async throws {
        let root = try storeTemporaryDirectory()
        let preview = root.appendingPathComponent("index.html")
        try "<h1>Preview</h1>".write(to: preview, atomically: true, encoding: .utf8)
        let harness = await makeBrowserHarness(root: root)

        XCTAssertTrue(harness.rightPanel.openFileInBrowser(relativePath: "index.html"))
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, .browser)
        XCTAssertEqual(
            harness.rightPanel.selectedRightPanelTab.id,
            RightPanelTab.browserTabID(urlString: nil, relativePath: "index.html"))
        XCTAssertEqual(harness.rightPanel.selectedRightPanelTab.relativePath, "index.html")
        XCTAssertEqual(
            harness.rightPanel.selectedRightPanelTab.urlString,
            preview.standardizedFileURL.absoluteString)
        XCTAssertNil(harness.rightPanel.selectedBrowserUnavailableMessage)
    }

    @MainActor
    func testBrowserSurfaceLaunchCarriesLoadCommandForOpenedFile() async throws {
        let root = try storeTemporaryDirectory()
        let preview = root.appendingPathComponent("index.html")
        try "<h1>Preview</h1>".write(to: preview, atomically: true, encoding: .utf8)
        let harness = await makeBrowserHarness(root: root)
        XCTAssertTrue(harness.rightPanel.openFileInBrowser(relativePath: "index.html"))

        let threadID = try XCTUnwrap(harness.workspace.selectedThreadID)
        let tabID = harness.rightPanel.selectedRightPanelTab.id
        let launchResult = await harness.workspace.surfaceLaunch(
            for: .browser(threadID: threadID, tabID: tabID))
        let launch = try XCTUnwrap(launchResult)

        // The browser helper hosts a WKWebView; the file URL travels in the launch
        // command as `["load", urlString]` (the helper parses `command.first`).
        XCTAssertEqual(launch.command, ["load", preview.standardizedFileURL.absoluteString])
        XCTAssertEqual(launch.workingDirectory, root)
    }

    @MainActor
    func testBrowserSurfaceLaunchIsNilForEmptyBrowserTab() async {
        let harness = await makeHarness()
        let threadID = harness.workspace.selectedThreadID ?? UUID()
        harness.rightPanel.openBrowserTab()
        let tabID = harness.rightPanel.selectedRightPanelTab.id
        // An empty browser tab (no URL) has no surface to launch.
        let launch = await harness.workspace.surfaceLaunch(
            for: .browser(threadID: threadID, tabID: tabID))
        XCTAssertNil(launch)
    }

    @MainActor
    func testBrowserRejectsUnsupportedAndEscapingFilePathsWithoutChangingTab() async {
        let harness = await makeHarness()
        let originalTab = harness.rightPanel.selectedRightPanelTab
        XCTAssertFalse(harness.rightPanel.openFileInBrowser(relativePath: "../secret.html"))
        XCTAssertEqual(harness.rightPanel.selectedRightPanelTab, originalTab)
        XCTAssertNotNil(harness.rightPanel.selectedBrowserUnavailableMessage)
        XCTAssertFalse(harness.rightPanel.openFileInBrowser(relativePath: "Package.swift"))
        XCTAssertEqual(harness.rightPanel.selectedRightPanelTab, originalTab)
    }

    @MainActor
    func testMissingRightPanelToolFallsBackToRawCommandName() async throws {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(),
            externalToolResolver: StaticExecutableResolver(paths: [:]), environment: [:])

        harness.rightPanel.openFileInNvim(relativePath: "README.md")
        let nvimResult = await harness.workspace.surfaceLaunch(
            for: .nvim(threadID: fixture.firstThreadID))
        let nvimLaunch = try XCTUnwrap(nvimResult)
        harness.rightPanel.selectRightPanelMode(.git)
        let gitResult = await harness.workspace.surfaceLaunch(
            for: .lazygit(threadID: fixture.firstThreadID))
        let gitLaunch = try XCTUnwrap(gitResult)

        XCTAssertEqual(nvimLaunch.command, ["nvim", "README.md"])
        XCTAssertEqual(gitLaunch.command, ["git", "--no-pager", "diff"])
    }

    @MainActor
    func testExternalOpenFileTargetUsesSelectedThreadWorkingDirectory() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        let target = harness.rightPanel.externalOpenFileTarget(
            relativePath: "src/App/RootView.swift")
        XCTAssertEqual(
            target,
            ExternalOpenTarget(
                url: fixture.root.appendingPathComponent("src/App/RootView.swift"), kind: .file))
    }

    @MainActor
    func testFileBrowserPathResolutionRejectsEscapingRelativePaths() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        XCTAssertEqual(
            harness.rightPanel.fileBrowserURL(relativePath: "src/App/RootView.swift"),
            fixture.root.appendingPathComponent("src/App/RootView.swift").standardizedFileURL)
        XCTAssertNil(harness.rightPanel.fileBrowserURL(relativePath: "../outside.swift"))
        XCTAssertNil(
            harness.rightPanel.fileBrowserExternalOpenTarget(
                relativePath: "../outside.swift", isDirectory: false))
    }

    // MARK: - Helpers

    @MainActor
    private func makeBrowserHarness(root: URL) async -> StoreHarness {
        let projectID = UUID()
        let threadID = UUID()
        return await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                    threads: [
                        AgentThread(
                            id: threadID, displayName: "Thread", projectID: projectID,
                            workingDirectory: root)
                    ],
                    selectedProjectID: projectID, selectedThreadID: threadID,
                    rightPanelModesByThreadID: [threadID: .files], selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false)))
    }
}
