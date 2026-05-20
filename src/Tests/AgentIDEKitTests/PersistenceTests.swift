import XCTest
import SQLite3
@testable import AgentIDEKit

final class PersistenceTests: XCTestCase {
    func testSQLiteMigrationInitializesCurrentSchema() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteAgentIDEStore(databasePath: path)

        let version = try sqliteUserVersion(path: path)

        XCTAssertEqual(version, SQLiteAgentIDEStore.schemaVersion)
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

        let store = try SQLiteAgentIDEStore(databasePath: path)
        let loaded = store.load()

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteAgentIDEStore.schemaVersion)
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

        _ = try SQLiteAgentIDEStore(databasePath: path)

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteAgentIDEStore.schemaVersion)
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

        XCTAssertThrowsError(try SQLiteAgentIDEStore(databasePath: path)) { error in
            XCTAssertEqual(
                error as? SQLiteStoreError,
                .executionFailed("Cannot migrate existing threads without explicit agent_cli choices")
            )
        }
    }

    func testSQLiteStorePersistsPlanOneSnapshot() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteAgentIDEStore(databasePath: path)
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/agent-ide", isDirectory: true)
        let createdAt = Date(timeIntervalSince1970: 42)
        let snapshot = AgentIDESnapshot(
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
                )
            ],
            selectedProjectID: projectID,
            selectedThreadID: secondThreadID,
            rightPanelModesByThreadID: [firstThreadID: .git, secondThreadID: .nvim],
            selectedRightPanelMode: .nvim,
            isGlobalTerminalExpanded: true
        )

        store.save(snapshot)
        let reloaded = try SQLiteAgentIDEStore(databasePath: path).load()

        XCTAssertEqual(reloaded.projects, snapshot.projects)
        XCTAssertEqual(reloaded.threads.map(\.id), snapshot.threads.map(\.id))
        XCTAssertEqual(reloaded.threads.map(\.isArchived), [true, false])
        XCTAssertEqual(reloaded.threads.map(\.agentCLI), [.codex, .claude])
        XCTAssertEqual(reloaded.threads.map(\.sessionIdentity), [nil, nil])
        XCTAssertEqual(reloaded.selectedProjectID, projectID)
        XCTAssertEqual(reloaded.selectedThreadID, secondThreadID)
        XCTAssertEqual(reloaded.rightPanelModesByThreadID[firstThreadID], .git)
        XCTAssertEqual(reloaded.rightPanelModesByThreadID[secondThreadID], .nvim)
        XCTAssertTrue(reloaded.isGlobalTerminalExpanded)
    }

    func testSQLiteLayoutStatePersistsThroughReload() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteAgentIDEStore(databasePath: path)
        var snapshot = store.load()
        let layoutState = LayoutState(
            sidebarWidth: 312,
            rightPanelWidth: 366,
            globalTerminalHeight: 188,
            isSidebarCollapsed: true,
            isRightPanelCollapsed: true,
            isGlobalTerminalExpanded: true
        )
        snapshot.layoutState = layoutState

        store.save(snapshot)
        let reloaded = try SQLiteAgentIDEStore(databasePath: path).load()

        XCTAssertEqual(reloaded.layoutState, layoutState)
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

        _ = try SQLiteAgentIDEStore(databasePath: path)
        let columns = try sqliteTableColumns(path: path, table: "threads")

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteAgentIDEStore.schemaVersion)
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

        _ = try SQLiteAgentIDEStore(databasePath: path)
        let columns = try sqliteTableColumns(path: path, table: "file_index_metadata")

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteAgentIDEStore.schemaVersion)
        XCTAssertTrue(columns.contains("thread_id"))
        XCTAssertTrue(columns.contains("root_path"))
        XCTAssertTrue(columns.contains("indexed_at"))
        XCTAssertTrue(columns.contains("file_count"))
        XCTAssertTrue(columns.contains("ignored_directory_count"))
    }

    func testSQLiteFileIndexMetadataPersistsThroughReload() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteAgentIDEStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/agent-ide", isDirectory: true)
        let metadata = FileIndexMetadata(
            threadID: threadID,
            rootPath: root.path,
            indexedAt: Date(timeIntervalSince1970: 456),
            fileCount: 12,
            ignoredDirectoryCount: 3
        )
        let snapshot = AgentIDESnapshot(
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
        let reloaded = try SQLiteAgentIDEStore(databasePath: path).load()

        XCTAssertEqual(reloaded.fileIndexMetadataByThreadID[threadID], metadata)
    }

    func testSQLiteLayoutStateMissingRowsUseDefaults() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteAgentIDEStore(databasePath: path)
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

        let reloaded = try SQLiteAgentIDEStore(databasePath: path).load()

        XCTAssertEqual(reloaded.layoutState.sidebarWidth, 333)
        XCTAssertEqual(reloaded.layoutState.rightPanelWidth, LayoutState.defaultRightPanelWidth)
        XCTAssertEqual(reloaded.layoutState.globalTerminalHeight, LayoutState.defaultGlobalTerminalHeight)
        XCTAssertFalse(reloaded.layoutState.isSidebarCollapsed)
        XCTAssertFalse(reloaded.layoutState.isRightPanelCollapsed)
        XCTAssertFalse(reloaded.layoutState.isGlobalTerminalExpanded)
    }

    func testSQLiteTransactionRejectsPartialInvalidThreadWrite() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteAgentIDEStore(databasePath: path)
        let projectID = UUID()
        let invalidThread = AgentThread(
            displayName: "Invalid",
            projectID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp/agent-ide", isDirectory: true)
        )
        let snapshot = AgentIDESnapshot(
            projects: [Project(id: projectID, displayName: "Project", rootDirectory: invalidThread.workingDirectory)],
            threads: [invalidThread],
            selectedProjectID: projectID,
            selectedThreadID: invalidThread.id,
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false
        )

        store.save(snapshot)
        let reloaded = try SQLiteAgentIDEStore(databasePath: path).load()

        XCTAssertNotEqual(reloaded.projects.map(\.id), [projectID])
        XCTAssertFalse(reloaded.threads.contains { $0.id == invalidThread.id })
    }

    func testSQLiteLoadFallsBackWhenPersistedUUIDIsInvalid() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteAgentIDEStore(databasePath: path)
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

        let reloaded = try SQLiteAgentIDEStore(databasePath: path).load()

        XCTAssertEqual(reloaded.projects.first?.displayName, "Global")
        XCTAssertEqual(reloaded.threads.first?.displayName, "Hello World")
    }

    func testJSONConfigurationSeedsDefaultsAndRoundTrips() throws {
        let path = try temporaryDirectory().appendingPathComponent("config.json")
        let store = JSONConfigurationStore(path: path)

        let seeded = store.load()
        try store.save(AgentIDEConfiguration(ignoreRules: seeded.ignoreRules + ["vendor"]))
        let reloaded = store.load()

        XCTAssertEqual(seeded.theme, "Dracula")
        XCTAssertTrue(seeded.ignoreRules.contains(".git"))
        XCTAssertTrue(seeded.ignoreRules.contains("node_modules"))
        XCTAssertTrue(reloaded.ignoreRules.contains("vendor"))
    }

    func testJSONConfigurationRecoversMalformedFile() throws {
        let path = try temporaryDirectory().appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: path)

        let recovered = JSONConfigurationStore(path: path).load()

        XCTAssertEqual(recovered, AgentIDEConfiguration())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentIDEKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sqliteUserVersion(path: URL) throws -> Int {
        try withSQLiteDatabase(path: path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func sqliteTableColumns(path: URL, table: String) throws -> Set<String> {
        try withSQLiteDatabase(path: path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            var columns = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                columns.insert(String(cString: sqlite3_column_text(statement, 1)))
            }
            return columns
        }
    }

    private func withSQLiteDatabase<T>(path: URL, _ work: (OpaquePointer?) throws -> T) throws -> T {
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
