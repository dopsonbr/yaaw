import Foundation
import YAAWKit

extension E2ERunner {
    // MARK: - File browser + browser tabs + nvim/git launches

    func assertFileBrowserAndBrowserTabs(
        stores: AppStores, codexThreadID: UUID, claudeThreadID: UUID
    ) async throws {
        let workspace = stores.workspace
        let activity = stores.activity
        let rightPanel = stores.rightPanel

        activity.refreshSelectedFileBrowser()
        try await e2eWaitUntil("file index finished and contains README.md") {
            !activity.fileBrowserState.isIndexing
                && activity.fileBrowserState.visibleEntries.contains {
                    $0.relativePath == "README.md"
                }
        }
        workspace.selectThread(id: claudeThreadID)
        activity.refreshSelectedFileBrowser()
        try await e2eWaitUntil("same-directory thread refreshed shared file index cache") {
            activity.fileBrowserState.visibleEntries.contains { $0.relativePath == "README.md" }
        }
        workspace.selectThread(id: codexThreadID)
        activity.updateFileSearchQuery("root")
        try e2eAssert(
            activity.fileBrowserState.visibleEntries.first?.relativePath
                == "src/App/RootView.swift",
            "fuzzy search preferred RootView.swift")

        try assertBrowserTabs(rightPanel: rightPanel)
        try assertNvimAndGitLaunches(
            stores: stores, codexThreadID: codexThreadID)
    }

    private func assertBrowserTabs(rightPanel: RightPanelStore) throws {
        try e2eAssert(
            rightPanel.openFileInBrowser(relativePath: "index.html"),
            "HTML fixture opened in Browser mode")
        try e2eAssert(
            rightPanel.selectedRightPanelMode == .browser, "browser preview selected Browser mode")
        try e2eAssert(
            rightPanel.selectedRightPanelTab.relativePath == "index.html",
            "browser tab tracked HTML relative path")
        try e2eAssert(
            rightPanel.selectedRightPanelTab.urlString
                == paths.projectDirectory.appendingPathComponent("index.html").standardizedFileURL
                .absoluteString,
            "browser tab loaded HTML fixture file URL")
        try e2eAssert(
            rightPanel.openFileInBrowser(relativePath: "diagram.svg"),
            "SVG fixture opened in Browser mode")
        try e2eAssert(
            rightPanel.selectedRightPanelTab.relativePath == "diagram.svg",
            "browser tab tracked SVG relative path")
        let browserTabIDs = rightPanel.selectedRightPanelState.tabs
            .filter { $0.kind == .browser }.map(\.id)
        try e2eAssert(
            browserTabIDs.contains(
                RightPanelTab.browserTabID(urlString: nil, relativePath: "index.html"))
                && browserTabIDs.contains(
                    RightPanelTab.browserTabID(urlString: nil, relativePath: "diagram.svg")),
            "browser tabs included HTML and SVG preview files")
        try e2eAssert(
            rightPanel.openFileInBrowser(relativePath: "README.md"),
            "Markdown fixture opened in Browser mode")
        try e2eAssert(
            rightPanel.selectedRightPanelTab.relativePath == "README.md",
            "browser tab tracked Markdown relative path")
        rightPanel.openBrowserTab(urlString: "example.com")
        try e2eAssert(
            rightPanel.selectedRightPanelTab.urlString == "https://example.com",
            "typed browser URL normalized")
    }

    private func assertNvimAndGitLaunches(stores: AppStores, codexThreadID: UUID) throws {
        let rightPanel = stores.rightPanel
        rightPanel.openFileInNvim(relativePath: "src/App/RootView.swift")
        try e2eAssert(
            rightPanel.externalOpenFileTarget(relativePath: "src/App/RootView.swift")
                == ExternalOpenTarget(
                    url: paths.projectDirectory.appendingPathComponent("src/App/RootView.swift")
                        .standardizedFileURL,
                    kind: .file),
            "external-open file target uses the selected thread working directory")
    }

    // MARK: - nvim/git surface launches (async, build via binding actor)

    func assertToolFallbacksAndRecovery(stores: AppStores, codexThreadID: UUID) async throws {
        let workspace = stores.workspace
        let nvimLaunch = try e2eUnwrap(
            await workspace.surfaceLaunch(for: .nvim(threadID: codexThreadID)),
            "nvim surface exists")
        let nvimCommandSuffix = Array(nvimLaunch.command.suffix(2))
        try e2eAssert(
            nvimCommandSuffix == ["nvim", "src/App/RootView.swift"]
                || nvimCommandSuffix == [
                    paths.binDirectory.appendingPathComponent("nvim").path,
                    "src/App/RootView.swift",
                ],
            "nvim surface included the selected relative path")

        stores.rightPanel.selectRightPanelMode(.git)
        let gitLaunch = try e2eUnwrap(
            await workspace.surfaceLaunch(for: .lazygit(threadID: codexThreadID)),
            "git surface exists")
        try e2eAssert(
            gitLaunch.command.last?.hasSuffix("/lazygit") == true, "git mode launched lazygit")

        try await assertMissingLazygitFallsBackToGitDiff()
        try await assertMissingNvimFallsBackToVimThenVi()
        try assertImagePastePolicyUsesNativeShortcut()
        try await assertMissingDirectoryRecovery()
        try await assertUnboundThreadLinkRecovery()
    }

    // MARK: - Layout + archive

    func assertLayoutAndArchive(stores: AppStores, claudeThreadID: UUID) throws {
        let layout = stores.layout
        layout.toggleBottomTerminal()
        layout.setRightPanelWidth(960)
        layout.setSidebarWidth(320)
        layout.setGlobalTerminalHeight(240)
        layout.toggleWorkspaceSwap()
        layout.toggleRightPanelCollapsed()
        layout.toggleRightPanelCollapsed()
        stores.workspace.archiveThread(id: claudeThreadID)
        try e2eAssert(
            stores.workspace.archivedThreadsForSelectedProject.contains { $0.id == claudeThreadID },
            "archive moved the claude thread")
    }

    // MARK: - Reload + session resume

    func assertReloadResumesSession(databasePath: URL, codexThreadID: UUID) async throws {
        let reloaded = try await makeStores(databasePath: databasePath)
        let workspace = reloaded.workspace
        try e2eAssert(
            workspace.selectedThread?.id == codexThreadID,
            "relaunch preserved selected codex thread")
        try e2eAssert(
            workspace.selectedThread?.sessionIdentity == "codex-e2e-001",
            "relaunch preserved codex session identity")
        try e2eAssert(
            reloaded.layout.layoutState.sidebarWidth == 320,
            "relaunch preserved resized sidebar width")
        try e2eAssert(
            reloaded.layout.layoutState.rightPanelWidth == 960,
            "relaunch preserved resized right panel width")
        try e2eAssert(
            reloaded.layout.layoutState.isWorkspaceSwapped,
            "relaunch preserved swapped main and right panels")
        try e2eAssert(
            reloaded.layout.layoutState.globalTerminalHeight == 240,
            "relaunch preserved resized bottom terminal height")

        let resumedLaunch = try e2eUnwrap(
            await workspace.surfaceLaunch(for: .project(threadID: codexThreadID)),
            "resumed project terminal surface")
        let resumedCommand = resumedLaunch.command.joined(separator: " ")
        try e2eAssert(
            resumedCommand.contains("resume") && resumedCommand.contains("codex-e2e-001"),
            "reopened codex thread resumed the stored session identity")
    }
}
