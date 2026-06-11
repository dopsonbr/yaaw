import Foundation
import SQLite3

// The migration ladder runs once, during the synchronous actor `init`, on a
// local connection handle before the actor can escape. Every method here is
// therefore `nonisolated` and takes the `OpaquePointer?` explicitly; none touch
// the statement cache (migrations compile one-shot statements). The v1→v16
// ladder is preserved verbatim from the pre-rewrite store; v17 is new.
extension SQLiteYAAWStore {
    /// Walks the schema from its current `user_version` up to `schemaVersion`,
    /// one transactional step at a time. The ladder is table-driven: each step
    /// declares the version it produces and the work that produces it, and the
    /// loop runs every step whose version exceeds the current one (each in its
    /// own transaction, stamping `user_version` on success). Steps are
    /// forward-only. The v1→v16 sequence is preserved verbatim from the
    /// pre-rewrite store; v17 is new.
    nonisolated static func migrate(_ database: OpaquePointer?) throws {
        try execute(database, "PRAGMA foreign_keys = ON")
        let currentVersion = try userVersion(database)
        guard currentVersion <= Self.schemaVersion else {
            throw SQLiteStoreError.executionFailed("Unsupported schema version \(currentVersion)")
        }
        for step in migrationLadder where currentVersion < step.version {
            try transaction(database) {
                try step.work(database)
                try execute(database, "PRAGMA user_version = \(step.version)")
            }
        }
    }

    /// One forward migration: the `user_version` it yields and the work that
    /// transforms the schema into that version.
    private struct MigrationStep {
        let version: Int
        let work: (OpaquePointer?) throws -> Void
    }

    /// The ordered v1→v17 migration ladder. A fresh database starts at
    /// `user_version` 0 and runs every step; an existing one runs only the steps
    /// past its current version.
    private static var migrationLadder: [MigrationStep] {
        [
            MigrationStep(version: 1) { try createVersionOneSchema($0) },
            MigrationStep(version: 2) { try migrateToVersionTwo($0) },
            MigrationStep(version: 3) {
                try createLayoutStateSchema($0)
                try seedLayoutStateFromLegacyAppState($0)
            },
            MigrationStep(version: 4) { try migrateToVersionFour($0) },
            MigrationStep(version: 5) { try createFileIndexMetadataSchema($0) },
            MigrationStep(version: 6) { try migrateToVersionSixAgentCLIValues($0) },
            MigrationStep(version: 7) {
                try createBottomTerminalStateSchema($0)
                try seedBottomTerminalStateFromLegacyLayout($0)
            },
            MigrationStep(version: 8) {
                try createRightPanelTabStateSchema($0)
                try seedRightPanelTabStateFromLegacyModes($0)
            },
            MigrationStep(version: 9) { try migrateToVersionNine($0) },
            MigrationStep(version: 10) { try migrateToVersionTen($0) },
            MigrationStep(version: 11) { try migrateToVersionEleven($0) },
            MigrationStep(version: 12) { try createThreadActivityStateSchema($0) },
            MigrationStep(version: 13) { try migrateToVersionThirteen($0) },
            MigrationStep(version: 14) { try migrateToVersionFourteen($0) },
            MigrationStep(version: 15) { try migrateToVersionFifteen($0) },
            MigrationStep(version: 16) { try migrateToVersionSixteen($0) },
            MigrationStep(version: 17) { try migrateToVersionSeventeen($0) },
        ]
    }

    /// v16 → v17: index `right_panel_tabs(thread_id, tab_order)` so reload-time
    /// ordering is served from the index. Combined with `tab_order` being
    /// written contiguously on every save (`writeRightPanelState`), this makes
    /// tab order stable across save→load cycles (the regression this migration
    /// fixes). No data rewrite is needed; the index alone is sufficient.
    nonisolated static func migrateToVersionSeventeen(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE INDEX IF NOT EXISTS idx_right_panel_tabs_order
                ON right_panel_tabs(thread_id, tab_order)
            """
        )
    }

    nonisolated static func migrateToVersionSixteen(_ database: OpaquePointer?) throws {
        let projectColumns = try tableColumns(database, "projects")
        if !projectColumns.contains("is_archived") {
            try execute(
                database, "ALTER TABLE projects ADD COLUMN is_archived INTEGER NOT NULL DEFAULT 0")
        }
    }

    nonisolated static func migrateToVersionNine(_ database: OpaquePointer?) throws {
        try execute(
            database,
            "CREATE INDEX IF NOT EXISTS idx_threads_project_archived ON threads(project_id, is_archived)"
        )
        try execute(
            database,
            "CREATE INDEX IF NOT EXISTS idx_threads_last_opened ON threads(last_opened_at)"
        )
    }

    nonisolated static func migrateToVersionTen(_ database: OpaquePointer?) throws {
        let columns = try tableColumns(database, "file_index_metadata")
        if !columns.contains("cache_key") {
            try execute(database, "ALTER TABLE file_index_metadata ADD COLUMN cache_key TEXT")
        }
        if !columns.contains("git_identity") {
            try execute(
                database,
                "ALTER TABLE file_index_metadata ADD COLUMN git_identity TEXT NOT NULL DEFAULT 'nogit'"
            )
        }
        if !columns.contains("ignore_rules_fingerprint") {
            try execute(
                database,
                "ALTER TABLE file_index_metadata ADD COLUMN ignore_rules_fingerprint TEXT NOT NULL DEFAULT ''"
            )
        }
        if !columns.contains("schema_version") {
            // The interpolated value is the integer literal
            // FileIndexMetadata.currentSchemaVersion, not user input.
            try execute(
                database,
                "ALTER TABLE file_index_metadata ADD COLUMN schema_version INTEGER NOT NULL DEFAULT \(FileIndexMetadata.currentSchemaVersion)"
            )
        }
        try createFileIndexCacheSchema(database)
    }

    nonisolated static func migrateToVersionEleven(_ database: OpaquePointer?) throws {
        let projectColumns = try tableColumns(database, "projects")
        if !projectColumns.contains("is_pinned") {
            try execute(
                database, "ALTER TABLE projects ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
        }
        if !projectColumns.contains("sort_order") {
            try execute(
                database, "ALTER TABLE projects ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0")
            try seedProjectSortOrder(database)
        }

        let threadColumns = try tableColumns(database, "threads")
        if !threadColumns.contains("is_pinned") {
            try execute(
                database, "ALTER TABLE threads ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
        }

        try createSidebarProjectStateSchema(database)
        if let selectedProjectID = try loadUUID(database, key: "selected_project_id") {
            try insertSidebarProjectState(
                database,
                projectID: selectedProjectID,
                isExpanded: true,
                isArchiveExpanded: false
            )
        }
    }

    nonisolated static func migrateToVersionThirteen(_ database: OpaquePointer?) throws {
        if try tableColumns(database, "right_panel_modes").isEmpty {
            try execute(
                database,
                """
                CREATE TABLE IF NOT EXISTS right_panel_modes (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'browser', 'nvim', 'git'))
                )
                """
            )
        } else {
            try execute(
                database,
                """
                CREATE TABLE right_panel_modes_v13 (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'browser', 'nvim', 'git'))
                )
                """
            )
            try execute(
                database,
                """
                INSERT INTO right_panel_modes_v13 (thread_id, mode)
                SELECT thread_id, mode FROM right_panel_modes
                WHERE mode IN ('files', 'browser', 'nvim', 'git')
                """
            )
            try execute(database, "DROP TABLE right_panel_modes")
            try execute(database, "ALTER TABLE right_panel_modes_v13 RENAME TO right_panel_modes")
        }

        let tabColumns = try tableColumns(database, "right_panel_tabs")
        guard !tabColumns.isEmpty else {
            try createRightPanelTabStateSchema(database)
            return
        }
        let urlSelect = tabColumns.contains("url_string") ? "url_string" : "NULL"
        try execute(
            database,
            """
            CREATE TABLE right_panel_tabs_v13 (
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                tab_id TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('files', 'browser', 'git', 'nvim')),
                title TEXT NOT NULL,
                relative_path TEXT,
                url_string TEXT,
                tab_order INTEGER NOT NULL,
                PRIMARY KEY (thread_id, tab_id)
            )
            """
        )
        try execute(
            database,
            """
            INSERT INTO right_panel_tabs_v13 (
                thread_id, tab_id, kind, title, relative_path, url_string, tab_order
            )
            SELECT thread_id, tab_id, kind, title, relative_path, \(urlSelect), tab_order
            FROM right_panel_tabs
            WHERE kind IN ('files', 'browser', 'git', 'nvim')
            """
        )
        try execute(database, "DROP TABLE right_panel_tabs")
        try execute(database, "ALTER TABLE right_panel_tabs_v13 RENAME TO right_panel_tabs")
    }

    nonisolated static func migrateToVersionFourteen(_ database: OpaquePointer?) throws {
        let threadColumns = try tableColumns(database, "threads")
        if !threadColumns.contains("pending_session_rename") {
            try execute(database, "ALTER TABLE threads ADD COLUMN pending_session_rename TEXT")
        }
    }

    nonisolated static func migrateToVersionFifteen(_ database: OpaquePointer?) throws {
        let threadColumns = try tableColumns(database, "threads")
        if !threadColumns.contains("launch_options_json") {
            try execute(database, "ALTER TABLE threads ADD COLUMN launch_options_json TEXT")
        }
    }

    nonisolated static func migrateToVersionTwo(_ database: OpaquePointer?) throws {
        let columns = try tableColumns(database, "threads")
        guard !columns.contains("agent_cli") else { return }
        let existingThreadCount = try querySingleInt(database, "SELECT COUNT(*) FROM threads") ?? 0
        guard existingThreadCount == 0 else {
            throw SQLiteStoreError.executionFailed(
                "Cannot migrate existing threads without explicit agent_cli choices"
            )
        }
        try execute(
            database,
            """
            CREATE TABLE threads_v2 (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                working_directory TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_opened_at REAL NOT NULL,
                is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                agent_cli TEXT NOT NULL CHECK (agent_cli IN ('codex', 'claude'))
            )
            """
        )
        try execute(database, "DROP TABLE threads")
        try execute(database, "ALTER TABLE threads_v2 RENAME TO threads")
    }

    nonisolated static func migrateToVersionFour(_ database: OpaquePointer?) throws {
        let columns = try tableColumns(database, "threads")
        if !columns.contains("session_identity") {
            try execute(database, "ALTER TABLE threads ADD COLUMN session_identity TEXT")
        }
        if !columns.contains("canonical_session_name") {
            try execute(database, "ALTER TABLE threads ADD COLUMN canonical_session_name TEXT")
        }
    }

    nonisolated static func migrateToVersionSixAgentCLIValues(_ database: OpaquePointer?) throws {
        try execute(database, "PRAGMA defer_foreign_keys = ON")
        try execute(
            database,
            """
            CREATE TABLE threads_v6 (
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
            )
            """
        )
        try execute(
            database,
            """
            INSERT INTO threads_v6 (
                id,
                display_name,
                project_id,
                working_directory,
                created_at,
                last_opened_at,
                is_archived,
                agent_cli,
                session_identity,
                canonical_session_name
            )
            SELECT
                id,
                display_name,
                project_id,
                working_directory,
                created_at,
                last_opened_at,
                is_archived,
                agent_cli,
                session_identity,
                canonical_session_name
            FROM threads
            """
        )
        try execute(database, "DROP TABLE threads")
        try execute(database, "ALTER TABLE threads_v6 RENAME TO threads")
    }

    nonisolated static func seedProjectSortOrder(_ database: OpaquePointer?) throws {
        let statement = try prepare(
            database, "SELECT id FROM projects ORDER BY created_at, display_name"
        )
        defer { sqlite3_finalize(statement) }
        var projectIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            projectIDs.append(text(at: 0, in: statement))
        }
        for (index, projectID) in projectIDs.enumerated() {
            let updateStatement = try prepare(
                database, "UPDATE projects SET sort_order = ? WHERE id = ?")
            defer { sqlite3_finalize(updateStatement) }
            sqlite3_bind_int(updateStatement, 1, Int32(index))
            bind(projectID, at: 2, in: updateStatement)
            try stepDone(database, updateStatement)
        }
    }

    nonisolated static func seedBottomTerminalStateFromLegacyLayout(_ database: OpaquePointer?)
        throws
    {
        let isExpanded =
            try loadLayoutBool(database, key: "global_terminal_expanded")
            ?? (try loadBool(database, key: "is_global_terminal_expanded") ?? false)
        guard isExpanded,
            let selectedThreadID = try loadUUID(database, key: "selected_thread_id")
        else {
            return
        }
        try insertBottomTerminalState(database, threadID: selectedThreadID, isExpanded: true)
    }

    nonisolated static func seedRightPanelTabStateFromLegacyModes(_ database: OpaquePointer?) throws
    {
        let modes = try loadRightPanelModes(database)
        let statement = try prepare(database, "SELECT id FROM threads")
        defer { sqlite3_finalize(statement) }
        var threadIDs: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let threadID = UUID(uuidString: text(at: 0, in: statement)) {
                threadIDs.append(threadID)
            }
        }
        for threadID in threadIDs {
            try insertRightPanelState(
                database,
                threadID: threadID,
                state: RightPanelState.defaultState(selectedMode: modes[threadID] ?? .files)
            )
        }
    }

    nonisolated static func seedLayoutStateFromLegacyAppState(_ database: OpaquePointer?) throws {
        let isExpanded = try loadBool(database, key: "is_global_terminal_expanded") ?? false
        try insertLayoutState(database, LayoutState(isGlobalTerminalExpanded: isExpanded))
    }
}

extension SQLiteYAAWStore {
    nonisolated static func createVersionOneSchema(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                root_directory TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_opened_at REAL NOT NULL
            )
            """
        )
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS threads (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                working_directory TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_opened_at REAL NOT NULL,
                is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1))
            )
            """
        )
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS app_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS right_panel_modes (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                mode TEXT NOT NULL CHECK (mode IN ('files', 'browser', 'nvim', 'git'))
            )
            """
        )
    }

    nonisolated static func createLayoutStateSchema(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS layout_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
    }

    nonisolated static func createFileIndexMetadataSchema(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS file_index_metadata (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                cache_key TEXT,
                root_path TEXT NOT NULL,
                git_identity TEXT NOT NULL DEFAULT 'nogit',
                ignore_rules_fingerprint TEXT NOT NULL DEFAULT '',
                schema_version INTEGER NOT NULL DEFAULT 1,
                indexed_at REAL NOT NULL,
                file_count INTEGER NOT NULL,
                ignored_directory_count INTEGER NOT NULL
            )
            """
        )
    }

    nonisolated static func createFileIndexCacheSchema(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS file_index_cache_metadata (
                cache_key TEXT PRIMARY KEY NOT NULL,
                root_path TEXT NOT NULL,
                git_identity TEXT NOT NULL,
                ignore_rules_fingerprint TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                indexed_at REAL NOT NULL,
                file_count INTEGER NOT NULL,
                ignored_directory_count INTEGER NOT NULL
            )
            """
        )
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS file_index_cache_entries (
                cache_key TEXT NOT NULL REFERENCES file_index_cache_metadata(cache_key) ON DELETE CASCADE,
                relative_path TEXT NOT NULL,
                is_directory INTEGER NOT NULL CHECK (is_directory IN (0, 1)),
                entry_order INTEGER NOT NULL,
                PRIMARY KEY (cache_key, relative_path)
            )
            """
        )
        try execute(
            database,
            "CREATE INDEX IF NOT EXISTS idx_file_index_cache_entries_order ON file_index_cache_entries(cache_key, entry_order)"
        )
    }

    nonisolated static func createBottomTerminalStateSchema(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS bottom_terminal_state (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                is_expanded INTEGER NOT NULL CHECK (is_expanded IN (0, 1))
            )
            """
        )
    }

    nonisolated static func createRightPanelTabStateSchema(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS right_panel_tabs (
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                tab_id TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('files', 'browser', 'git', 'nvim')),
                title TEXT NOT NULL,
                relative_path TEXT,
                url_string TEXT,
                tab_order INTEGER NOT NULL,
                PRIMARY KEY (thread_id, tab_id)
            )
            """
        )
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS right_panel_tab_state (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                selected_tab_id TEXT NOT NULL
            )
            """
        )
    }

    nonisolated static func createSidebarProjectStateSchema(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS sidebar_project_state (
                project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                is_expanded INTEGER NOT NULL CHECK (is_expanded IN (0, 1)),
                is_archive_expanded INTEGER NOT NULL CHECK (is_archive_expanded IN (0, 1))
            )
            """
        )
    }

    nonisolated static func createThreadActivityStateSchema(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS thread_activity_state (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                status TEXT NOT NULL CHECK (status IN ('working', 'needsInput', 'complete', 'inactive')),
                preview TEXT,
                is_unread INTEGER NOT NULL CHECK (is_unread IN (0, 1)),
                title TEXT,
                body TEXT,
                source TEXT NOT NULL CHECK (source IN ('helper', 'terminalNotification', 'terminalLifecycle')),
                updated_at REAL NOT NULL
            )
            """
        )
    }
}
