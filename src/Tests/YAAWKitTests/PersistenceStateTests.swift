import XCTest

@testable import YAAWKit

final class PersistenceStateTests: PersistenceTestCase {
    func testSQLiteRestoresRightPanelNvimTabs() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        var state = RightPanelState.defaultState(selectedMode: .files)
        let selectedTab = state.openNvimTab(relativePath: "src/App/RootView.swift")

        await store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID, displayName: "Thread", projectID: projectID,
                        workingDirectory: root)
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .nvim],
                rightPanelStatesByThreadID: [threadID: state],
                selectedRightPanelMode: .nvim,
                isGlobalTerminalExpanded: false
            )
        )

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()
        let reloadedState = try XCTUnwrap(reloaded.rightPanelStatesByThreadID[threadID])

        XCTAssertEqual(reloadedState.selectedTabID, selectedTab.id)
        XCTAssertEqual(reloadedState.selectedTab.relativePath, "src/App/RootView.swift")
        XCTAssertTrue(reloadedState.tabs.contains { $0.id == selectedTab.id })
    }

    func testSQLiteRestoresRightPanelBrowserTabs() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        var state = RightPanelState.defaultState(selectedMode: .files)
        let urlTab = state.openBrowserTab(
            urlString: "https://example.com/docs", relativePath: nil)
        let fileTab = state.openBrowserTab(
            urlString: "file:///tmp/yaaw/index.html", relativePath: "index.html")

        await store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID, displayName: "Thread", projectID: projectID,
                        workingDirectory: root)
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .browser],
                rightPanelStatesByThreadID: [threadID: state],
                selectedRightPanelMode: .browser,
                isGlobalTerminalExpanded: false
            )
        )

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()
        let reloadedState = try XCTUnwrap(reloaded.rightPanelStatesByThreadID[threadID])

        XCTAssertEqual(reloaded.rightPanelModesByThreadID[threadID], .browser)
        XCTAssertEqual(reloadedState.selectedTabID, fileTab.id)
        XCTAssertTrue(reloadedState.tabs.contains { $0.id == urlTab.id })
        XCTAssertTrue(reloadedState.tabs.contains { $0.id == fileTab.id })
        XCTAssertEqual(reloadedState.selectedTab.relativePath, "index.html")
        XCTAssertEqual(reloadedState.selectedTab.urlString, "file:///tmp/yaaw/index.html")
    }

    func testSQLiteLayoutStatePersistsThroughReload() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        var snapshot = await store.load()
        let layoutState = LayoutState(
            sidebarWidth: 312,
            rightPanelWidth: 366,
            globalTerminalHeight: 188,
            isSidebarCollapsed: true,
            isRightPanelCollapsed: true,
            isGlobalTerminalExpanded: true,
            isWorkspaceSwapped: true
        )
        snapshot.layoutState = layoutState

        await store.save(snapshot)
        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.layoutState.sidebarWidth, layoutState.sidebarWidth)
        XCTAssertEqual(reloaded.layoutState.rightPanelWidth, layoutState.rightPanelWidth)
        XCTAssertEqual(reloaded.layoutState.globalTerminalHeight, layoutState.globalTerminalHeight)
        XCTAssertEqual(reloaded.layoutState.isSidebarCollapsed, layoutState.isSidebarCollapsed)
        XCTAssertEqual(
            reloaded.layoutState.isRightPanelCollapsed, layoutState.isRightPanelCollapsed)
        XCTAssertFalse(reloaded.layoutState.isGlobalTerminalExpanded)
        XCTAssertTrue(reloaded.layoutState.isWorkspaceSwapped)
    }

    func testSQLiteFileIndexMetadataPersistsThroughReload() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let metadata = FileIndexMetadata(
            threadID: threadID,
            rootPath: root.path,
            indexedAt: Date(timeIntervalSince1970: 456),
            fileCount: 12,
            ignoredDirectoryCount: 3
        )
        let snapshot = YAAWSnapshot(
            projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
            threads: [
                AgentThread(
                    id: threadID,
                    displayName: "Thread",
                    projectID: projectID,
                    workingDirectory: root
                )
            ],
            selectedProjectID: projectID,
            selectedThreadID: threadID,
            rightPanelModesByThreadID: [threadID: .files],
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false,
            fileIndexMetadataByThreadID: [threadID: metadata]
        )

        await store.save(snapshot)
        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.fileIndexMetadataByThreadID[threadID], metadata)
    }

    func testSQLiteCachedFileIndexPersistsThroughReload() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let threadID = UUID()
        let metadata = FileIndexMetadata(
            threadID: threadID,
            cacheKey: "file-index:v1:test",
            rootPath: "/tmp/yaaw",
            gitIdentity: "branch:refs/heads/main",
            ignoreRulesFingerprint: "abc123",
            schemaVersion: 1,
            indexedAt: Date(timeIntervalSince1970: 789),
            fileCount: 2,
            ignoredDirectoryCount: 1
        )
        let entries = [
            FileBrowserEntry(relativePath: "src", isDirectory: true),
            FileBrowserEntry(relativePath: "src/App.swift", isDirectory: false),
        ]

        await store.upsertCachedFileIndex(CachedFileIndex(metadata: metadata, entries: entries))

        let reopened = try SQLiteYAAWStore(databasePath: path)
        let loadedIndex = await reopened.cachedFileIndex(cacheKey: "file-index:v1:test")
        let cached = try XCTUnwrap(loadedIndex)

        XCTAssertEqual(cached.metadata.cacheKey, metadata.cacheKey)
        XCTAssertEqual(cached.metadata.rootPath, metadata.rootPath)
        XCTAssertEqual(cached.metadata.gitIdentity, metadata.gitIdentity)
        XCTAssertEqual(cached.metadata.ignoreRulesFingerprint, metadata.ignoreRulesFingerprint)
        XCTAssertEqual(cached.metadata.schemaVersion, metadata.schemaVersion)
        XCTAssertEqual(cached.metadata.indexedAt, metadata.indexedAt)
        XCTAssertEqual(cached.metadata.fileCount, metadata.fileCount)
        XCTAssertEqual(cached.metadata.ignoredDirectoryCount, metadata.ignoredDirectoryCount)
        XCTAssertEqual(cached.entries, entries)
    }

    func testSQLiteRightPanelTabOrderPersistedOnReload() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)

        // A state whose tabs are intentionally not in default order: open a git
        // tab then a (persistable) files-relative tab so multiple ordered rows
        // exist, then select a specific tab.
        var state = RightPanelState.defaultState(selectedMode: .files)
        state.selectTab(id: RightPanelTab.gitID)
        let expectedTabIDs = state.tabs.map(\.id)
        let expectedSelectedTabID = state.selectedTabID

        let snapshot = YAAWSnapshot(
            projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
            threads: [
                AgentThread(
                    id: threadID, displayName: "Thread", projectID: projectID,
                    workingDirectory: root)
            ],
            selectedProjectID: projectID,
            selectedThreadID: threadID,
            rightPanelModesByThreadID: [threadID: .git],
            rightPanelStatesByThreadID: [threadID: state],
            selectedRightPanelMode: .git,
            isGlobalTerminalExpanded: false
        )

        var current = snapshot
        for _ in 0..<5 {
            let store = try SQLiteYAAWStore(databasePath: path)
            await store.save(current)
            current = await store.load()
            let reloadedState = try XCTUnwrap(current.rightPanelStatesByThreadID[threadID])
            XCTAssertEqual(reloadedState.tabs.map(\.id), expectedTabIDs)
            XCTAssertEqual(reloadedState.selectedTabID, expectedSelectedTabID)
        }
    }

    func testPreparedStatementCacheReusedAcrossOperations() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let project = Project(id: projectID, displayName: "Project", rootDirectory: root)
        var thread = AgentThread(
            id: threadID, displayName: "Thread", projectID: projectID, workingDirectory: root)

        await store.upsertProject(project)
        await store.upsertThread(thread)
        let countAfterWarmup = await store.preparedStatementCacheCount

        for index in 0..<25 {
            thread.displayName = "Thread \(index)"
            await store.upsertThread(thread)
        }
        let countAfterRepeats = await store.preparedStatementCacheCount

        // Repeating the identical upsertThread SQL adds no new cache entries.
        XCTAssertEqual(countAfterRepeats, countAfterWarmup)
        XCTAssertGreaterThan(countAfterRepeats, 0)

        // The persisted value reflects the final repeated write.
        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()
        XCTAssertEqual(reloaded.threads.first { $0.id == threadID }?.displayName, "Thread 24")
    }

    func testSQLitePersistsBottomTerminalExpandedThreads() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)

        await store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: firstThreadID, displayName: "First", projectID: projectID,
                        workingDirectory: root),
                    AgentThread(
                        id: secondThreadID, displayName: "Second", projectID: projectID,
                        workingDirectory: root),
                ],
                selectedProjectID: projectID,
                selectedThreadID: firstThreadID,
                selectedRightPanelMode: .files,
                bottomTerminalExpandedThreadIDs: [secondThreadID],
                isGlobalTerminalExpanded: false
            )
        )

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.bottomTerminalExpandedThreadIDs, [secondThreadID])
        XCTAssertFalse(reloaded.isGlobalTerminalExpanded)
    }

    func testSQLitePersistsPinsProjectOrderAndSidebarExpansion() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)

        await store.save(
            YAAWSnapshot(
                projects: [
                    Project(
                        id: firstProjectID, displayName: "First", rootDirectory: root,
                        isPinned: false, sortOrder: 0, isArchived: true),
                    Project(
                        id: secondProjectID, displayName: "Second", rootDirectory: root,
                        isPinned: true, sortOrder: 0),
                ],
                threads: [
                    AgentThread(
                        id: firstThreadID, displayName: "First", projectID: firstProjectID,
                        workingDirectory: root),
                    AgentThread(
                        id: secondThreadID,
                        displayName: "Second",
                        projectID: secondProjectID,
                        workingDirectory: root,
                        isPinned: true
                    ),
                ],
                selectedProjectID: secondProjectID,
                selectedThreadID: secondThreadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false,
                expandedProjectIDs: [secondProjectID],
                expandedArchivedProjectIDs: [secondProjectID]
            )
        )

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.projects.map(\.id), [secondProjectID, firstProjectID])
        XCTAssertEqual(reloaded.projects.map(\.isPinned), [true, false])
        XCTAssertEqual(reloaded.projects.map(\.sortOrder), [0, 0])
        XCTAssertEqual(
            reloaded.projects.first { $0.id == firstProjectID }?.isArchived, true)
        XCTAssertEqual(
            reloaded.projects.first { $0.id == secondProjectID }?.isArchived, false)
        XCTAssertEqual(reloaded.threads.first { $0.id == secondThreadID }?.isPinned, true)
        XCTAssertEqual(reloaded.expandedProjectIDs, [secondProjectID])
        XCTAssertEqual(reloaded.expandedArchivedProjectIDs, [secondProjectID])
    }

    func testSQLiteLayoutStateMissingRowsUseDefaults() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        _ = await store.load()
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                DELETE FROM layout_state;
                INSERT INTO layout_state (key, value) VALUES ('sidebar_width', '333');
                """,
                database: database
            )
        }

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.layoutState.sidebarWidth, 333)
        XCTAssertEqual(reloaded.layoutState.rightPanelWidth, LayoutState.defaultRightPanelWidth)
        XCTAssertEqual(
            reloaded.layoutState.globalTerminalHeight, LayoutState.defaultGlobalTerminalHeight)
        XCTAssertFalse(reloaded.layoutState.isSidebarCollapsed)
        XCTAssertFalse(reloaded.layoutState.isRightPanelCollapsed)
        XCTAssertFalse(reloaded.layoutState.isGlobalTerminalExpanded)
        XCTAssertFalse(reloaded.layoutState.isWorkspaceSwapped)
    }

    func testSQLiteStorePersistsThreadActivityState() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let updatedAt = Date(timeIntervalSince1970: 123)
        let activity = ThreadActivityState(
            threadID: threadID,
            status: .needsInput,
            preview: "Approve the command",
            isUnread: true,
            title: "Needs input",
            body: "Approve the command",
            source: .helper,
            updatedAt: updatedAt
        )

        await store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID, displayName: "Thread", projectID: projectID,
                        workingDirectory: root)
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false,
                threadActivityByThreadID: [threadID: activity]
            )
        )

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.threadActivityByThreadID[threadID], activity)
    }
}
