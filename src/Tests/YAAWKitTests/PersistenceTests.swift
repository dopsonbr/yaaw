import SQLite3
import XCTest

@testable import YAAWKit

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class PersistenceTests: XCTestCase {
    func testSQLiteMigrationInitializesCurrentSchema() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteYAAWStore(databasePath: path)

        let version = try sqliteUserVersion(path: path)

        XCTAssertEqual(version, SQLiteYAAWStore.schemaVersion)
        XCTAssertTrue(
            try sqliteTableColumns(path: path, table: "threads").contains(
                "pending_session_rename"))
    }

    func testSQLiteStoreUsesWALJournalMode() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteYAAWStore(databasePath: path)

        XCTAssertEqual(try sqliteStringPragma(path: path, name: "journal_mode"), "wal")
    }

    func testSQLiteStoreDoesNotReportWALFailureOnSupportedFilesystem() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let recorder = RecordingDiagnosticEventRecorder()
        _ = try SQLiteYAAWStore(databasePath: path, diagnosticRecorder: recorder)

        XCTAssertFalse(
            recorder.events.contains { $0.name == "sqlite_wal_not_enabled" },
            "WAL readback should not report a failure on a supported filesystem"
        )
    }

    func testSQLiteMigrationRecoversPartialVersionZeroSchema() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    root_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL
                )
                """,
                database: database
            )
        }

        let store = try SQLiteYAAWStore(databasePath: path)
        let loaded = store.load()

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteYAAWStore.schemaVersion)
        XCTAssertFalse(loaded.projects.isEmpty)
        XCTAssertFalse(loaded.threads.isEmpty)
    }

    func testSQLiteMigrationAddsAgentCLIToVersionOneThreads() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    root_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL
                );
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    working_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1))
                );
                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE right_panel_modes (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'nvim', 'git'))
                );
                PRAGMA user_version = 1;
                """,
                database: database
            )
        }

        _ = try SQLiteYAAWStore(databasePath: path)

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteYAAWStore.schemaVersion)
        XCTAssertTrue(try sqliteTableColumns(path: path, table: "threads").contains("agent_cli"))
    }

    func testSQLiteMigrationRejectsVersionOneThreadsWithoutExplicitAgentCLI() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let projectID = UUID()
        let threadID = UUID()
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    root_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL
                );
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    working_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1))
                );
                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE right_panel_modes (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'nvim', 'git'))
                );
                INSERT INTO projects (id, display_name, root_directory, created_at, last_opened_at)
                VALUES ('\(projectID.uuidString)', 'Legacy', '/tmp', 0, 0);
                INSERT INTO threads (id, display_name, project_id, working_directory, created_at, last_opened_at, is_archived)
                VALUES ('\(threadID.uuidString)', 'Legacy Thread', '\(projectID.uuidString)', '/tmp', 0, 0, 0);
                PRAGMA user_version = 1;
                """,
                database: database
            )
        }

        XCTAssertThrowsError(try SQLiteYAAWStore(databasePath: path)) { error in
            XCTAssertEqual(
                error as? SQLiteStoreError,
                .executionFailed(
                    "Cannot migrate existing threads without explicit agent_cli choices")
            )
        }
    }

    func testSQLiteMigrationFailureRecordsDiagnosticEvent() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let projectID = UUID()
        let threadID = UUID()
        let recorder = RecordingDiagnosticEventRecorder()
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    root_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL
                );
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    working_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1))
                );
                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE right_panel_modes (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'nvim', 'git'))
                );
                INSERT INTO projects (id, display_name, root_directory, created_at, last_opened_at)
                VALUES ('\(projectID.uuidString)', 'Legacy', '/tmp', 0, 0);
                INSERT INTO threads (id, display_name, project_id, working_directory, created_at, last_opened_at, is_archived)
                VALUES ('\(threadID.uuidString)', 'Legacy Thread', '\(projectID.uuidString)', '/tmp', 0, 0, 0);
                PRAGMA user_version = 1;
                """,
                database: database
            )
        }

        XCTAssertThrowsError(try SQLiteYAAWStore(databasePath: path, diagnosticRecorder: recorder))

        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "SQLite"
                    && $0.name == "sqlite_open_or_migrate_failed"
                    && $0.metadata["database"] == path.path
                    && $0.metadata["error"]?.contains("Cannot migrate existing threads") == true
            }
        )
    }

    func testSQLiteStorePersistsPlanOneSnapshot() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let createdAt = Date(timeIntervalSince1970: 42)
        let snapshot = YAAWSnapshot(
            projects: [
                Project(
                    id: projectID,
                    displayName: "Project",
                    rootDirectory: root,
                    createdAt: createdAt,
                    lastOpenedAt: createdAt
                )
            ],
            threads: [
                AgentThread(
                    id: firstThreadID,
                    displayName: "First",
                    projectID: projectID,
                    workingDirectory: root,
                    createdAt: createdAt,
                    lastOpenedAt: createdAt,
                    isArchived: true
                ),
                AgentThread(
                    id: secondThreadID,
                    displayName: "Second",
                    projectID: projectID,
                    workingDirectory: root,
                    agentCLI: .claude,
                    createdAt: createdAt,
                    lastOpenedAt: createdAt
                ),
            ],
            selectedProjectID: projectID,
            selectedThreadID: secondThreadID,
            rightPanelModesByThreadID: [firstThreadID: .git, secondThreadID: .nvim],
            selectedRightPanelMode: .nvim,
            isGlobalTerminalExpanded: true
        )

        store.save(snapshot)
        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.projects, snapshot.projects)
        XCTAssertEqual(reloaded.threads.map(\.id), snapshot.threads.map(\.id))
        XCTAssertEqual(reloaded.threads.map(\.isArchived), [true, false])
        XCTAssertEqual(reloaded.threads.map(\.agentCLI), [.codex, .claude])
        XCTAssertEqual(reloaded.threads.map(\.sessionIdentity), [nil, nil])
        XCTAssertEqual(reloaded.threads.map(\.pendingSessionRename), [nil, nil])
        XCTAssertEqual(reloaded.selectedProjectID, projectID)
        XCTAssertEqual(reloaded.selectedThreadID, secondThreadID)
        XCTAssertEqual(reloaded.rightPanelModesByThreadID[firstThreadID], .git)
        XCTAssertEqual(reloaded.rightPanelModesByThreadID[secondThreadID], .nvim)
        XCTAssertEqual(
            reloaded.rightPanelStatesByThreadID[firstThreadID]?.selectedTabID, RightPanelTab.gitID)
        XCTAssertEqual(
            reloaded.rightPanelStatesByThreadID[secondThreadID]?.selectedTabID,
            RightPanelTab.defaultNvimID)
        XCTAssertTrue(reloaded.isGlobalTerminalExpanded)
    }

    func testSQLiteStorePersistsSelectionChangeInBatch() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let createdAt = Date(timeIntervalSince1970: 42)
        let oldOpenedAt = Date(timeIntervalSince1970: 100)
        let newOpenedAt = Date(timeIntervalSince1970: 200)
        let firstProject = Project(
            id: firstProjectID,
            displayName: "First Project",
            rootDirectory: root,
            createdAt: createdAt,
            lastOpenedAt: oldOpenedAt
        )
        var secondProject = Project(
            id: secondProjectID,
            displayName: "Second Project",
            rootDirectory: root,
            createdAt: createdAt,
            lastOpenedAt: oldOpenedAt
        )
        let firstThread = AgentThread(
            id: firstThreadID,
            displayName: "First",
            projectID: firstProjectID,
            workingDirectory: root,
            createdAt: createdAt,
            lastOpenedAt: oldOpenedAt
        )
        var secondThread = AgentThread(
            id: secondThreadID,
            displayName: "Second",
            projectID: secondProjectID,
            workingDirectory: root,
            createdAt: createdAt,
            lastOpenedAt: oldOpenedAt
        )
        store.save(
            YAAWSnapshot(
                projects: [firstProject, secondProject],
                threads: [firstThread, secondThread],
                selectedProjectID: firstProjectID,
                selectedThreadID: firstThreadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        secondProject.lastOpenedAt = newOpenedAt
        secondThread.lastOpenedAt = newOpenedAt

        store.persistSelectionChange(
            selectedProjectID: secondProjectID,
            selectedThreadID: secondThreadID,
            touchedProject: secondProject,
            touchedThread: secondThread,
            expandedProjectID: secondProjectID
        )

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()
        XCTAssertEqual(reloaded.selectedProjectID, secondProjectID)
        XCTAssertEqual(reloaded.selectedThreadID, secondThreadID)
        XCTAssertEqual(
            reloaded.projects.first { $0.id == secondProjectID }?.lastOpenedAt,
            newOpenedAt
        )
        XCTAssertEqual(
            reloaded.threads.first { $0.id == secondThreadID }?.lastOpenedAt,
            newOpenedAt
        )
        XCTAssertTrue(reloaded.expandedProjectIDs.contains(secondProjectID))
    }

    func testPersistSelectionChangeMatchesAcrossStores() throws {
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let firstProject = Project(
            id: firstProjectID, displayName: "First Project", rootDirectory: root)
        var secondProject = Project(
            id: secondProjectID, displayName: "Second Project", rootDirectory: root)
        let firstThread = AgentThread(
            id: firstThreadID, displayName: "First", projectID: firstProjectID,
            workingDirectory: root)
        var secondThread = AgentThread(
            id: secondThreadID, displayName: "Second", projectID: secondProjectID,
            workingDirectory: root)
        secondProject.lastOpenedAt = Date(timeIntervalSince1970: 200)
        secondThread.lastOpenedAt = Date(timeIntervalSince1970: 200)

        func seededSnapshot() -> YAAWSnapshot {
            YAAWSnapshot(
                projects: [firstProject, secondProject],
                threads: [firstThread, secondThread],
                selectedProjectID: firstProjectID,
                selectedThreadID: firstThreadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        }

        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let sqliteStore = try SQLiteYAAWStore(databasePath: path)
        sqliteStore.save(seededSnapshot())
        let inMemoryStore = InMemoryYAAWStore(snapshot: seededSnapshot())

        for store in [sqliteStore as YAAWStore, inMemoryStore as YAAWStore] {
            store.persistSelectionChange(
                selectedProjectID: secondProjectID,
                selectedThreadID: secondThreadID,
                touchedProject: secondProject,
                touchedThread: secondThread,
                expandedProjectID: secondProjectID
            )
        }

        let fromSQLite = try SQLiteYAAWStore(databasePath: path).load()
        let fromMemory = inMemoryStore.load()
        XCTAssertEqual(fromSQLite.selectedProjectID, fromMemory.selectedProjectID)
        XCTAssertEqual(fromSQLite.selectedThreadID, fromMemory.selectedThreadID)
        XCTAssertEqual(fromSQLite.selectedProjectID, secondProjectID)
        XCTAssertEqual(fromSQLite.selectedThreadID, secondThreadID)
        XCTAssertEqual(
            fromSQLite.expandedProjectIDs.contains(secondProjectID),
            fromMemory.expandedProjectIDs.contains(secondProjectID)
        )
        XCTAssertTrue(fromSQLite.expandedProjectIDs.contains(secondProjectID))
    }

    func testSQLitePersistsPendingThreadRename() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)

        store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID,
                        displayName: "Thread",
                        projectID: projectID,
                        workingDirectory: root,
                        agentCLI: .codex,
                        sessionIdentity: "codex-1",
                        canonicalSessionName: "Thread",
                        pendingSessionRename: "Renamed Thread"
                    )
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.threads.first?.pendingSessionRename, "Renamed Thread")
        XCTAssertEqual(reloaded.threads.first?.sessionIdentity, "codex-1")
    }

    func testSQLiteStorePersistsThreadActivityState() throws {
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

        store.save(
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

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.threadActivityByThreadID[threadID], activity)
    }

    func testSQLiteDoesNotRestoreTransientRightPanelNvimTabs() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        var state = RightPanelState.defaultState(selectedMode: .files)
        let selectedTab = state.openNvimTab(relativePath: "src/App/RootView.swift")

        store.save(
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

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()
        let reloadedState = try XCTUnwrap(reloaded.rightPanelStatesByThreadID[threadID])

        XCTAssertEqual(reloadedState.selectedTabID, RightPanelTab.defaultNvimID)
        XCTAssertEqual(reloadedState.tabs.map(\.id), RightPanelState.defaultTabs.map(\.id))
        XCTAssertFalse(reloadedState.tabs.contains { $0.id == selectedTab.id })
    }

    func testSQLiteDoesNotRestoreTransientRightPanelBrowserTabs() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        var state = RightPanelState.defaultState(selectedMode: .files)
        let selectedTab = state.openBrowserTab(
            urlString: "https://example.com/docs", relativePath: nil)
        _ = state.openBrowserTab(
            urlString: "file:///tmp/yaaw/index.html", relativePath: "index.html")

        store.save(
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

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()
        let reloadedState = try XCTUnwrap(reloaded.rightPanelStatesByThreadID[threadID])

        XCTAssertEqual(reloaded.rightPanelModesByThreadID[threadID], .browser)
        XCTAssertEqual(reloadedState.selectedTabID, RightPanelTab.defaultBrowserID)
        XCTAssertEqual(reloadedState.tabs.map(\.id), RightPanelState.defaultTabs.map(\.id))
        XCTAssertFalse(reloadedState.tabs.contains { $0.id == selectedTab.id })
        XCTAssertFalse(reloadedState.tabs.contains { $0.relativePath == "index.html" })
    }

    func testSQLiteMigrationSeedsRightPanelTabsFromVersionSevenModes() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let projectID = UUID()
        let threadID = UUID()
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    root_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL
                );
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    working_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    agent_cli TEXT NOT NULL CHECK (agent_cli IN ('codex', 'claude', 'opencode', 'copilot')),
                    session_identity TEXT,
                    canonical_session_name TEXT
                );
                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE right_panel_modes (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'nvim', 'git'))
                );
                CREATE TABLE layout_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE file_index_metadata (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    root_path TEXT NOT NULL,
                    indexed_at REAL NOT NULL,
                    file_count INTEGER NOT NULL,
                    ignored_directory_count INTEGER NOT NULL
                );
                CREATE TABLE bottom_terminal_state (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    is_expanded INTEGER NOT NULL CHECK (is_expanded IN (0, 1))
                );
                INSERT INTO projects (id, display_name, root_directory, created_at, last_opened_at)
                VALUES ('\(projectID.uuidString)', 'Project', '/tmp', 0, 0);
                INSERT INTO threads (
                    id,
                    display_name,
                    project_id,
                    working_directory,
                    created_at,
                    last_opened_at,
                    is_archived,
                    agent_cli
                )
                VALUES ('\(threadID.uuidString)', 'Thread', '\(projectID.uuidString)', '/tmp', 0, 0, 0, 'codex');
                INSERT INTO app_state (key, value) VALUES ('selected_project_id', '\(projectID.uuidString)');
                INSERT INTO app_state (key, value) VALUES ('selected_thread_id', '\(threadID.uuidString)');
                INSERT INTO right_panel_modes (thread_id, mode) VALUES ('\(threadID.uuidString)', 'git');
                PRAGMA user_version = 7;
                """,
                database: database
            )
        }

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteYAAWStore.schemaVersion)
        XCTAssertTrue(
            try sqliteTableColumns(path: path, table: "right_panel_tabs").contains("tab_id"))
        XCTAssertTrue(
            try sqliteTableColumns(path: path, table: "right_panel_tabs").contains("url_string"))
        XCTAssertEqual(
            reloaded.rightPanelStatesByThreadID[threadID]?.selectedTabID, RightPanelTab.gitID)
        XCTAssertEqual(
            reloaded.rightPanelStatesByThreadID[threadID]?.tabs.map(\.id),
            [
                RightPanelTab.filesID, RightPanelTab.defaultBrowserID, RightPanelTab.gitID,
                RightPanelTab.defaultNvimID,
            ]
        )
    }

    func testSQLiteLayoutStatePersistsThroughReload() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        var snapshot = store.load()
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

        store.save(snapshot)
        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.layoutState.sidebarWidth, layoutState.sidebarWidth)
        XCTAssertEqual(reloaded.layoutState.rightPanelWidth, layoutState.rightPanelWidth)
        XCTAssertEqual(reloaded.layoutState.globalTerminalHeight, layoutState.globalTerminalHeight)
        XCTAssertEqual(reloaded.layoutState.isSidebarCollapsed, layoutState.isSidebarCollapsed)
        XCTAssertEqual(
            reloaded.layoutState.isRightPanelCollapsed, layoutState.isRightPanelCollapsed)
        XCTAssertFalse(reloaded.layoutState.isGlobalTerminalExpanded)
        XCTAssertTrue(reloaded.layoutState.isWorkspaceSwapped)
    }

    func testSQLiteMigrationAddsAgentCLISessionColumnsToVersionThreeThreads() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    root_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL
                );
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    working_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    agent_cli TEXT NOT NULL CHECK (agent_cli IN ('codex', 'claude'))
                );
                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE right_panel_modes (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'nvim', 'git'))
                );
                CREATE TABLE layout_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                PRAGMA user_version = 3;
                """,
                database: database
            )
        }

        _ = try SQLiteYAAWStore(databasePath: path)
        let columns = try sqliteTableColumns(path: path, table: "threads")

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteYAAWStore.schemaVersion)
        XCTAssertTrue(columns.contains("session_identity"))
        XCTAssertTrue(columns.contains("canonical_session_name"))
    }

    func testSQLiteMigrationAddsFileIndexMetadataTableToVersionFourDatabase() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    root_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL
                );
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    working_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    agent_cli TEXT NOT NULL CHECK (agent_cli IN ('codex', 'claude')),
                    session_identity TEXT,
                    canonical_session_name TEXT
                );
                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE right_panel_modes (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'nvim', 'git'))
                );
                CREATE TABLE layout_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                PRAGMA user_version = 4;
                """,
                database: database
            )
        }

        _ = try SQLiteYAAWStore(databasePath: path)
        let columns = try sqliteTableColumns(path: path, table: "file_index_metadata")

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteYAAWStore.schemaVersion)
        XCTAssertTrue(columns.contains("thread_id"))
        XCTAssertTrue(columns.contains("root_path"))
        XCTAssertTrue(columns.contains("cache_key"))
        XCTAssertTrue(columns.contains("git_identity"))
        XCTAssertTrue(columns.contains("ignore_rules_fingerprint"))
        XCTAssertTrue(columns.contains("schema_version"))
        XCTAssertTrue(columns.contains("indexed_at"))
        XCTAssertTrue(columns.contains("file_count"))
        XCTAssertTrue(columns.contains("ignored_directory_count"))
    }

    func testSQLiteMigrationAddsSharedFileIndexCacheTables() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteYAAWStore(databasePath: path)

        XCTAssertTrue(
            try sqliteTableColumns(path: path, table: "file_index_cache_metadata").contains(
                "cache_key"))
        XCTAssertTrue(
            try sqliteTableColumns(path: path, table: "file_index_cache_entries").contains(
                "relative_path"))
        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteYAAWStore.schemaVersion)
    }

    func testSQLiteFileIndexMetadataPersistsThroughReload() throws {
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

        store.save(snapshot)
        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.fileIndexMetadataByThreadID[threadID], metadata)
    }

    func testSQLiteCachedFileIndexPersistsThroughReload() throws {
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

        store.upsertCachedFileIndex(CachedFileIndex(metadata: metadata, entries: entries))

        let cached = try XCTUnwrap(
            SQLiteYAAWStore(databasePath: path).cachedFileIndex(cacheKey: "file-index:v1:test"))

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

    func testSQLiteAcceptsAllSupportedAgentCLIKinds() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let threads = AgentCLIKind.allCases.map { kind in
            AgentThread(
                displayName: kind.displayName,
                projectID: projectID,
                workingDirectory: root,
                agentCLI: kind
            )
        }

        store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: threads,
                selectedProjectID: projectID,
                selectedThreadID: threads.first?.id,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(Set(reloaded.threads.map(\.agentCLI)), Set(AgentCLIKind.allCases))
    }

    func testSQLitePersistsBottomTerminalExpandedThreads() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)

        store.save(
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

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.bottomTerminalExpandedThreadIDs, [secondThreadID])
        XCTAssertFalse(reloaded.isGlobalTerminalExpanded)
    }

    func testSQLitePersistsPinsProjectOrderAndSidebarExpansion() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)

        store.save(
            YAAWSnapshot(
                projects: [
                    Project(
                        id: firstProjectID, displayName: "First", rootDirectory: root,
                        isPinned: false, sortOrder: 0),
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

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.projects.map(\.id), [secondProjectID, firstProjectID])
        XCTAssertEqual(reloaded.projects.map(\.isPinned), [true, false])
        XCTAssertEqual(reloaded.projects.map(\.sortOrder), [0, 0])
        XCTAssertEqual(reloaded.threads.first { $0.id == secondThreadID }?.isPinned, true)
        XCTAssertEqual(reloaded.expandedProjectIDs, [secondProjectID])
        XCTAssertEqual(reloaded.expandedArchivedProjectIDs, [secondProjectID])
    }

    func testSQLiteMigrationAddsPinnedOrderAndSidebarStateToVersionTenDatabase() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let projectID = UUID()
        let threadID = UUID()
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    root_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL
                );
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    working_directory TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_opened_at REAL NOT NULL,
                    is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                    agent_cli TEXT NOT NULL CHECK (agent_cli IN ('codex', 'claude', 'opencode', 'copilot')),
                    session_identity TEXT,
                    canonical_session_name TEXT
                );
                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                INSERT INTO projects (id, display_name, root_directory, created_at, last_opened_at)
                VALUES ('\(projectID.uuidString)', 'Project', '/tmp', 0, 0);
                INSERT INTO threads (
                    id, display_name, project_id, working_directory, created_at, last_opened_at,
                    is_archived, agent_cli, session_identity, canonical_session_name
                )
                VALUES ('\(threadID.uuidString)', 'Thread', '\(projectID.uuidString)', '/tmp', 0, 0, 0, 'codex', NULL, NULL);
                INSERT INTO app_state (key, value) VALUES ('selected_project_id', '\(projectID.uuidString)');
                PRAGMA user_version = 10;
                """,
                database: database
            )
        }

        _ = try SQLiteYAAWStore(databasePath: path)

        XCTAssertTrue(try sqliteTableColumns(path: path, table: "projects").contains("is_pinned"))
        XCTAssertTrue(try sqliteTableColumns(path: path, table: "projects").contains("sort_order"))
        XCTAssertTrue(try sqliteTableColumns(path: path, table: "threads").contains("is_pinned"))
        XCTAssertEqual(try sqliteSidebarProjectExpanded(path: path, projectID: projectID), true)
    }

    func testSQLiteLayoutStateMissingRowsUseDefaults() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        _ = store.load()
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                DELETE FROM layout_state;
                INSERT INTO layout_state (key, value) VALUES ('sidebar_width', '333');
                """,
                database: database
            )
        }

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.layoutState.sidebarWidth, 333)
        XCTAssertEqual(reloaded.layoutState.rightPanelWidth, LayoutState.defaultRightPanelWidth)
        XCTAssertEqual(
            reloaded.layoutState.globalTerminalHeight, LayoutState.defaultGlobalTerminalHeight)
        XCTAssertFalse(reloaded.layoutState.isSidebarCollapsed)
        XCTAssertFalse(reloaded.layoutState.isRightPanelCollapsed)
        XCTAssertFalse(reloaded.layoutState.isGlobalTerminalExpanded)
        XCTAssertFalse(reloaded.layoutState.isWorkspaceSwapped)
    }

    func testSQLiteTransactionRejectsPartialInvalidThreadWrite() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let invalidThread = AgentThread(
            displayName: "Invalid",
            projectID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        )
        let snapshot = YAAWSnapshot(
            projects: [
                Project(
                    id: projectID, displayName: "Project",
                    rootDirectory: invalidThread.workingDirectory)
            ],
            threads: [invalidThread],
            selectedProjectID: projectID,
            selectedThreadID: invalidThread.id,
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false
        )

        store.save(snapshot)
        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertNotEqual(reloaded.projects.map(\.id), [projectID])
        XCTAssertFalse(reloaded.threads.contains { $0.id == invalidThread.id })
    }

    func testSQLiteLoadFallsBackWhenPersistedUUIDIsInvalid() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteYAAWStore(databasePath: path)
        try withSQLiteDatabase(path: path) { database in
            try executeSQL(
                """
                DELETE FROM projects;
                INSERT INTO projects (id, display_name, root_directory, created_at, last_opened_at)
                VALUES ('not-a-uuid', 'Bad', '/tmp', 0, 0);
                """,
                database: database
            )
        }

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.projects.first?.displayName, "Global")
        XCTAssertEqual(reloaded.threads.first?.displayName, "Hello World")
    }

    func testYAMLConfigurationSeedsDefaultsAndWritesCommentedTemplate() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let seeded = store.load()
        let template = try String(contentsOf: path, encoding: .utf8)

        XCTAssertEqual(seeded.themeName, "dracula")
        XCTAssertEqual(seeded.defaultAgentCLI, .codex)
        XCTAssertEqual(seeded.projects.globalChatsDirectory, "~/yaaw")
        XCTAssertEqual(seeded.fileIconPack, .material)
        XCTAssertEqual(seeded.fonts.interfaceFamily, "system")
        XCTAssertEqual(seeded.fonts.interfaceSize, 13)
        XCTAssertEqual(seeded.fonts.editorFamily, "system-monospace")
        XCTAssertEqual(seeded.fonts.editorSize, 13)
        XCTAssertEqual(seeded.fonts.terminalFamily, "")
        XCTAssertEqual(seeded.fonts.terminalSize, 12)
        XCTAssertTrue(seeded.ignoreRules.contains(".git"))
        XCTAssertTrue(seeded.ignoreRules.contains("node_modules"))
        XCTAssertTrue(seeded.ignoreRules.contains("Music"))
        XCTAssertTrue(template.contains("# YAAW settings."))
        XCTAssertTrue(template.contains("# default: [nvim, vim, vi]"))
        XCTAssertTrue(template.contains("globalChatsDirectory: \"~/yaaw\""))
        XCTAssertTrue(template.contains("fileBrowserPack: material-file-icons"))
        XCTAssertTrue(template.contains("# supported: light-2026, light-modern"))
        XCTAssertFalse(template.contains("only dracula is implemented"))
        XCTAssertTrue(template.contains("interfaceFamily: system"))
        XCTAssertTrue(template.contains("editorFamily: system-monospace"))
        XCTAssertTrue(template.contains("terminalSize: 12"))
        XCTAssertTrue(
            template.contains(
                "# not changeable yet: custom palettes are reserved for future expansion."))
    }

    func testYAMLConfigurationRawTextLoadSeedsDefaultFile() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let text = try store.loadText()

        XCTAssertTrue(text.contains("# YAAW settings."))
        XCTAssertTrue(text.contains("default: codex"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testYAMLConfigurationValidatesRawText() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let configuration = try store.validate(
            text: """
                version: 1
                agent:
                  default: claude
                projects:
                  globalChatsDirectory: ~/custom-yaaw
                icons:
                  fileBrowserPack: catppuccin-file-icons
                fonts:
                  interfaceFamily: Avenir Next
                  interfaceSize: 14.5
                  editorFamily: SF Mono
                  editorSize: 15
                  terminalFamily: JetBrains Mono
                  terminalSize: 16
                """
        )

        XCTAssertEqual(configuration.defaultAgentCLI, .claude)
        XCTAssertEqual(configuration.projects.globalChatsDirectory, "~/custom-yaaw")
        XCTAssertEqual(configuration.fileIconPack, .catppuccin)
        XCTAssertEqual(configuration.fonts.interfaceFamily, "Avenir Next")
        XCTAssertEqual(configuration.fonts.interfaceSize, 14.5)
        XCTAssertEqual(configuration.fonts.editorFamily, "SF Mono")
        XCTAssertEqual(configuration.fonts.editorSize, 15)
        XCTAssertEqual(configuration.fonts.terminalFamily, "JetBrains Mono")
        XCTAssertEqual(configuration.fonts.terminalSize, 16)
    }

    func testYAMLConfigurationSaveRendersFontSettingsAndReloadsThem() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)
        let configuration = YAAWConfiguration(
            fonts: FontSettings(
                interfaceFamily: "Avenir Next",
                interfaceSize: 14.5,
                editorFamily: "SF Mono",
                editorSize: 15,
                terminalFamily: "JetBrains Mono",
                terminalSize: 16
            )
        )

        try store.save(configuration)

        let text = try String(contentsOf: path, encoding: .utf8)
        let reloaded = store.load()
        XCTAssertTrue(text.contains("interfaceFamily: \"Avenir Next\""))
        XCTAssertTrue(text.contains("interfaceSize: 14.5"))
        XCTAssertTrue(text.contains("editorFamily: \"SF Mono\""))
        XCTAssertTrue(text.contains("editorSize: 15"))
        XCTAssertTrue(text.contains("terminalFamily: \"JetBrains Mono\""))
        XCTAssertTrue(text.contains("terminalSize: 16"))
        XCTAssertEqual(reloaded.fonts, configuration.fonts)
    }

    func testYAMLConfigurationAcceptsSupportedTheme() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)

        let configuration = try store.validate(
            text: """
                version: 1
                theme:
                  active: dark-plus
                """
        )

        XCTAssertEqual(configuration.themeName, "dark-plus")
        XCTAssertEqual(configuration.resolvedTheme.displayName, "Dark+")
    }

    func testYAMLConfigurationSaveTextPreservesRawFormattingAndComments() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)
        let text = """
            # custom settings comment
            version: 1
            agent:
              default: claude
            """

        try store.saveText(text)

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), text)
        XCTAssertEqual(store.load().defaultAgentCLI, .claude)
    }

    func testYAMLConfigurationMalformedSaveTextDoesNotOverwriteExistingFile() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let store = YAMLConfigurationStore(path: path)
        let original = """
            # keep me
            version: 1
            agent:
              default: codex
            """
        try store.saveText(original)

        XCTAssertThrowsError(try store.saveText("{ nope"))

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original)
        XCTAssertEqual(store.load().defaultAgentCLI, .codex)
    }

    func testYAMLConfigurationLoadsOverridesAndUnknownKeys() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            version: 1
            unknownTopLevel: ignored
            agent:
              default: claude
            projects:
              globalChatsDirectory: /tmp/yaaw-global
            theme:
              active: dracula
            icons:
              fileBrowserPack: catppuccin-file-icons
            fonts:
              interfaceFamily: Avenir Next
              interfaceSize: 14
              editorFamily: SF Mono
              editorSize: 15
              terminalFamily: JetBrains Mono
              terminalSize: 16
            keyboardShortcuts:
              toggleBottomTerminal:
                key: k
                modifiers: [command, option]
            tools:
              editors:
                preferred: [zed, nvim]
              externalOpen:
                default: vscode
                preferred: [webstorm, unsupported, vscode, finder, vscode]
              git:
                preferred: tig
              diff:
                fallback: [delta, "--diff"]
              agents:
                codex: codex-nightly
            fileIndexing:
              ignoreRules:
                - .git
                - node_modules
                - vendor
            """.utf8
        ).write(to: path)
        let store = YAMLConfigurationStore(path: path)

        let reloaded = store.load()

        XCTAssertEqual(reloaded.defaultAgentCLI, .claude)
        XCTAssertEqual(reloaded.projects.globalChatsDirectory, "/tmp/yaaw-global")
        XCTAssertEqual(reloaded.fileIconPack, .catppuccin)
        XCTAssertEqual(reloaded.fonts.interfaceFamily, "Avenir Next")
        XCTAssertEqual(reloaded.fonts.interfaceSize, 14)
        XCTAssertEqual(reloaded.fonts.editorFamily, "SF Mono")
        XCTAssertEqual(reloaded.fonts.editorSize, 15)
        XCTAssertEqual(reloaded.fonts.terminalFamily, "JetBrains Mono")
        XCTAssertEqual(reloaded.fonts.terminalSize, 16)
        XCTAssertEqual(reloaded.shortcut(for: .toggleBottomTerminal).key, "k")
        XCTAssertEqual(
            reloaded.shortcut(for: .toggleBottomTerminal).modifiers, [.command, .option])
        XCTAssertEqual(reloaded.tools.editors.preferred, ["zed", "nvim"])
        XCTAssertEqual(reloaded.tools.externalOpen.defaultToolID, .vscode)
        XCTAssertEqual(reloaded.tools.externalOpen.preferredToolIDs, [.webstorm, .vscode, .finder])
        XCTAssertEqual(reloaded.tools.git.preferred, "tig")
        XCTAssertEqual(reloaded.tools.diff.fallback, ["delta", "--diff"])
        XCTAssertEqual(reloaded.tools.agents.codex, "codex-nightly")
        XCTAssertTrue(reloaded.ignoreRules.contains("vendor"))
        XCTAssertTrue(reloaded.ignoreRules.contains("Music"))
    }

    func testYAMLConfigurationRendersEveryKeyboardShortcutAction() throws {
        let rendered = YAMLConfigurationStore.render(YAAWConfiguration())

        for action in KeyboardShortcutAction.allCases {
            XCTAssertTrue(rendered.contains("\(action.rawValue):"), "Missing \(action.rawValue)")
        }
    }

    func testYAMLConfigurationAllowsUnboundKeyboardShortcuts() throws {
        let store = YAMLConfigurationStore(
            path: try temporaryDirectory().appendingPathComponent("settings.yaml"))

        let configuration = try store.validate(
            text: """
                keyboardShortcuts:
                  archiveSelectedThread:
                    key: ""
                    modifiers: []
                """
        )

        XCTAssertTrue(configuration.shortcut(for: .archiveSelectedThread).isUnbound)
    }

    func testYAMLConfigurationFallsBackInvalidKeyboardShortcutToDefault() throws {
        let store = YAMLConfigurationStore(
            path: try temporaryDirectory().appendingPathComponent("settings.yaml"))

        let configuration = try store.validate(
            text: """
                keyboardShortcuts:
                  toggleBottomTerminal:
                    key: too-long
                    modifiers: []
                """
        )

        XCTAssertEqual(
            configuration.shortcut(for: .toggleBottomTerminal),
            KeyboardShortcutAction.toggleBottomTerminal.defaultShortcut)
    }

    func testYAMLConfigurationDetectsDuplicateKeyboardShortcutsWithinScope() throws {
        let store = YAMLConfigurationStore(
            path: try temporaryDirectory().appendingPathComponent("settings.yaml"))

        let configuration = try store.validate(
            text: """
                keyboardShortcuts:
                  selectFilesRightPanelMode:
                    key: "7"
                    modifiers: [command]
                  selectGitRightPanelMode:
                    key: "7"
                    modifiers: [command]
                """
        )

        XCTAssertEqual(
            configuration.keyboardShortcuts.duplicateActions(),
            [.selectFilesRightPanelMode, .selectGitRightPanelMode]
        )
    }

    func testDefaultKeyboardShortcutsDoNotConflict() {
        XCTAssertTrue(YAAWConfiguration().keyboardShortcuts.duplicateActions().isEmpty)
    }

    func testYAMLConfigurationDetectsDuplicateKeyboardShortcutsAcrossCommandScopes() throws {
        let store = YAMLConfigurationStore(
            path: try temporaryDirectory().appendingPathComponent("settings.yaml"))

        let configuration = try store.validate(
            text: """
                keyboardShortcuts:
                  reloadSettings:
                    key: "r"
                    modifiers: [command]
                """
        )

        XCTAssertEqual(
            configuration.keyboardShortcuts.duplicateActions(),
            [.refreshFiles, .reloadSettings]
        )
    }

    func testYAMLConfigurationMergesMissingDefaults() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            fileIndexing:
              ignoreRules:
                - .git
                - node_modules
            """.utf8
        ).write(to: path)
        let store = YAMLConfigurationStore(path: path)

        let reloaded = store.load()

        XCTAssertEqual(reloaded.defaultAgentCLI, .codex)
        XCTAssertEqual(reloaded.tools.editors.preferred, ["nvim", "vim", "vi"])
        XCTAssertEqual(reloaded.tools.externalOpen.defaultToolID, .zed)
        XCTAssertEqual(
            reloaded.tools.externalOpen.preferredToolIDs, ExternalOpenSettings.defaultPreferred)
        XCTAssertTrue(reloaded.ignoreRules.contains(".git"))
        XCTAssertTrue(reloaded.ignoreRules.contains("node_modules"))
        XCTAssertTrue(reloaded.ignoreRules.contains("Music"))
        XCTAssertTrue(reloaded.ignoreRules.contains("Movies"))
        XCTAssertTrue(reloaded.ignoreRules.contains("Pictures"))
        XCTAssertTrue(reloaded.ignoreRules.contains("Photos Library.photoslibrary"))
    }

    func testYAMLConfigurationClampsFontSizesAndFallbacksBlankFamilies() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            fonts:
              interfaceFamily: " "
              interfaceSize: 2
              editorFamily: ""
              editorSize: 40
              terminalFamily: "  "
              terminalSize: 999
            """.utf8
        ).write(to: path)
        let store = YAMLConfigurationStore(path: path)

        let reloaded = store.load()

        XCTAssertEqual(reloaded.fonts.interfaceFamily, "system")
        XCTAssertEqual(reloaded.fonts.interfaceSize, 9)
        XCTAssertEqual(reloaded.fonts.editorFamily, "system-monospace")
        XCTAssertEqual(reloaded.fonts.editorSize, 28)
        XCTAssertEqual(reloaded.fonts.terminalFamily, "")
        XCTAssertEqual(reloaded.fonts.terminalSize, 32)
    }

    func testYAMLConfigurationFallsBackForUnknownIconPackAndRecordsDiagnostic() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let recorder = RecordingDiagnosticEventRecorder()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            icons:
              fileBrowserPack: unsupported-icons
            """.utf8
        ).write(to: path)

        let reloaded = YAMLConfigurationStore(path: path, diagnosticRecorder: recorder).load()

        XCTAssertEqual(reloaded.fileIconPack, .material)
        XCTAssertEqual(reloaded.icons.fileBrowserPack, FileIconPack.material.rawValue)
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Configuration"
                    && $0.name == "unsupported_icon_pack"
                    && $0.metadata["requested"] == "unsupported-icons"
                    && $0.metadata["fallback"] == FileIconPack.material.rawValue
            }
        )
    }

    func testYAMLConfigurationFallsBackForUnknownThemeAndRecordsDiagnostic() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let recorder = RecordingDiagnosticEventRecorder()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            theme:
              active: unknown-theme
            """.utf8
        ).write(to: path)

        let reloaded = YAMLConfigurationStore(path: path, diagnosticRecorder: recorder).load()

        XCTAssertEqual(reloaded.themeName, ThemeCatalog.defaultID)
        XCTAssertEqual(reloaded.resolvedTheme.id, ThemeCatalog.defaultID)
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Configuration"
                    && $0.name == "unsupported_theme"
                    && $0.metadata["requested"] == "unknown-theme"
                    && $0.metadata["fallback"] == ThemeCatalog.defaultID
            }
        )
    }

    func testYAMLConfigurationRecoversMalformedFileAndRecordsDiagnostic() throws {
        let path = try temporaryDirectory().appendingPathComponent("settings.yaml")
        let recorder = RecordingDiagnosticEventRecorder()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: path)

        let recovered = YAMLConfigurationStore(path: path, diagnosticRecorder: recorder).load()

        XCTAssertEqual(recovered, YAAWConfiguration())
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Configuration"
                    && $0.name == "settings_yaml_recovered"
                    && $0.metadata["path"] == path.path
            }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sqliteUserVersion(path: URL) throws -> Int {
        try withSQLiteDatabase(path: path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func sqliteStringPragma(path: URL, name: String) throws -> String {
        try withSQLiteDatabase(path: path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return String(cString: sqlite3_column_text(statement, 0))
        }
    }

    private func sqliteTableColumns(path: URL, table: String) throws -> Set<String> {
        try withSQLiteDatabase(path: path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil),
                SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            var columns = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                columns.insert(String(cString: sqlite3_column_text(statement, 1)))
            }
            return columns
        }
    }

    private func sqliteSidebarProjectExpanded(path: URL, projectID: UUID) throws -> Bool? {
        try withSQLiteDatabase(path: path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    database,
                    "SELECT is_expanded FROM sidebar_project_state WHERE project_id = ?",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, projectID.uuidString, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    private func withSQLiteDatabase<T>(path: URL, _ work: (OpaquePointer?) throws -> T) throws -> T
    {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        return try work(database)
    }

    private func executeSQL(_ sql: String, database: OpaquePointer?) throws {
        var message: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        XCTAssertEqual(result, SQLITE_OK, message.map { String(cString: $0) } ?? "SQLite error")
    }
}

private final class RecordingDiagnosticEventRecorder: DiagnosticEventRecording, @unchecked Sendable
{
    private(set) var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        events.append(event)
    }
}
