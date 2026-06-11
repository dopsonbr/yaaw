import SQLite3
import XCTest

@testable import YAAWKit

final class SchemaInitializationTests: PersistenceTestCase {
    func testSQLiteMigrationInitializesCurrentSchema() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteYAAWStore(databasePath: path)

        let version = try sqliteUserVersion(path: path)

        XCTAssertEqual(version, SQLiteYAAWStore.schemaVersion)
        XCTAssertTrue(
            try sqliteTableColumns(path: path, table: "threads").contains(
                "pending_session_rename"))
        XCTAssertTrue(
            try sqliteTableColumns(path: path, table: "threads").contains("launch_options_json"))
    }

    func testSQLiteStoreUsesWALJournalMode() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteYAAWStore(databasePath: path)

        XCTAssertEqual(try sqliteStringPragma(path: path, name: "journal_mode"), "wal")
    }

    func testSQLiteStoreDoesNotReportWALFailureOnSupportedFilesystem() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let recorder = RecordingDiagnosticEventRecorder()
        _ = try SQLiteYAAWStore(databasePath: path, diagnosticRecorder: recorder)

        XCTAssertFalse(
            recorder.events.contains { $0.name == "sqlite_wal_not_enabled" },
            "WAL readback should not report a failure on a supported filesystem"
        )
    }

    func testSQLiteMigrationSeedsRightPanelTabsFromVersionSevenModes() async throws {
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

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

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
}
