import SQLite3
import XCTest

@testable import YAAWKit

final class PersistenceMigrationTests: PersistenceTestCase {
    func testSQLiteMigrationRecoversPartialVersionZeroSchema() async throws {
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
        let loaded = await store.load()

        XCTAssertEqual(try sqliteUserVersion(path: path), SQLiteYAAWStore.schemaVersion)
        XCTAssertFalse(loaded.projects.isEmpty)
        XCTAssertFalse(loaded.threads.isEmpty)
    }

    func testSQLiteMigrationAddsAgentCLIToVersionOneThreads() async throws {
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

    func testSQLiteMigrationRejectsVersionOneThreadsWithoutExplicitAgentCLI() async throws {
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

    func testSQLiteMigrationFailureRecordsDiagnosticEvent() async throws {
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

    func testSQLiteMigrationAddsAgentCLISessionColumnsToVersionThreeThreads() async throws {
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

    func testSQLiteMigrationAddsFileIndexMetadataTableToVersionFourDatabase() async throws {
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

    func testSQLiteMigrationAddsSharedFileIndexCacheTables() async throws {
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

    func testSQLiteMigrationAddsPinnedOrderAndSidebarStateToVersionTenDatabase() async throws {
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
}
