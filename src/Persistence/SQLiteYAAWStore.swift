import Foundation
import SQLite3

public enum SQLiteStoreError: Error, Equatable {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)
    case missingDatabase
}

private struct SidebarProjectStateSnapshot {
    var expandedProjectIDs: Set<UUID>
    var expandedArchivedProjectIDs: Set<UUID>
}

private struct SidebarProjectStateRow {
    var isExpanded: Bool
    var isArchiveExpanded: Bool
}

public final class SQLiteYAAWStore: YAAWStore {
    public static let schemaVersion = 14

    private let databasePath: URL
    private let diagnosticRecorder: DiagnosticEventRecording
    private var database: OpaquePointer?

    public init(
        databasePath: URL,
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared
    ) throws {
        self.databasePath = databasePath
        self.diagnosticRecorder = diagnosticRecorder
        do {
            try FileManager.default.createDirectory(
                at: databasePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try open()
            try migrate()
        } catch {
            recordSQLiteError(name: "sqlite_open_or_migrate_failed", error: error)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    public static func defaultStore() throws -> YAAWStore {
        try SQLiteYAAWStore(databasePath: defaultDatabasePath())
    }

    public static func defaultDatabasePath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("YAAW.sqlite")
    }

    public func load() -> YAAWSnapshot {
        do {
            let projects = try loadProjects()
            if projects.isEmpty {
                let seed = InMemoryYAAWStore.helloWorld().load()
                save(seed)
                return seed
            }

            let threads = try loadThreads()
            let selectedProjectID = try loadUUID(key: "selected_project_id") ?? projects[0].id
            let selectedThreadID =
                try loadUUID(key: "selected_thread_id")
                ?? threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
            let modes = try loadRightPanelModes()
            let rightPanelStates = try loadRightPanelStates(fallbackModes: modes)
            let selectedMode =
                selectedThreadID.map { rightPanelStates[$0]?.selectedMode ?? modes[$0] ?? .files }
                ?? .files
            let fallbackGlobalTerminalExpanded =
                try loadBool(key: "is_global_terminal_expanded") ?? false
            let layoutState = try loadLayoutState(
                fallbackGlobalTerminalExpanded: fallbackGlobalTerminalExpanded
            )
            let fileIndexMetadata = try loadFileIndexMetadata()
            let threadActivity = try loadThreadActivity()
            let bottomTerminalExpandedThreadIDs = try loadBottomTerminalExpandedThreadIDs()
            let sidebarProjectState = try loadSidebarProjectState()

            return YAAWSnapshot(
                projects: projects,
                threads: threads,
                selectedProjectID: selectedProjectID,
                selectedThreadID: selectedThreadID,
                rightPanelModesByThreadID: modes,
                rightPanelStatesByThreadID: rightPanelStates,
                selectedRightPanelMode: selectedMode,
                bottomTerminalExpandedThreadIDs: bottomTerminalExpandedThreadIDs,
                isGlobalTerminalExpanded: layoutState.isGlobalTerminalExpanded,
                layoutState: layoutState,
                fileIndexMetadataByThreadID: fileIndexMetadata,
                threadActivityByThreadID: threadActivity,
                expandedProjectIDs: sidebarProjectState.expandedProjectIDs,
                expandedArchivedProjectIDs: sidebarProjectState.expandedArchivedProjectIDs
            )
        } catch {
            recordSQLiteError(name: "sqlite_load_failed", error: error)
            return InMemoryYAAWStore.helloWorld().load()
        }
    }

    public func save(_ snapshot: YAAWSnapshot) {
        do {
            try transaction {
                try execute("DELETE FROM right_panel_modes")
                try execute("DELETE FROM right_panel_tab_state")
                try execute("DELETE FROM right_panel_tabs")
                try execute("DELETE FROM bottom_terminal_state")
                try execute("DELETE FROM file_index_metadata")
                try execute("DELETE FROM thread_activity_state")
                try execute("DELETE FROM sidebar_project_state")
                try execute("DELETE FROM layout_state")
                try execute("DELETE FROM app_state")
                try execute("DELETE FROM threads")
                try execute("DELETE FROM projects")

                for project in snapshot.projects {
                    try insertProject(project)
                }
                for thread in snapshot.threads {
                    try insertThread(thread)
                }
                for (threadID, mode) in snapshot.rightPanelModesByThreadID {
                    try insertRightPanelMode(threadID: threadID, mode: mode)
                }
                for thread in snapshot.threads {
                    let state =
                        snapshot.rightPanelStatesByThreadID[thread.id]
                        ?? RightPanelState.defaultState(
                            selectedMode: snapshot.rightPanelModesByThreadID[thread.id] ?? .files
                        )
                    try insertRightPanelState(threadID: thread.id, state: state)
                }
                for threadID in snapshot.bottomTerminalExpandedThreadIDs {
                    try insertBottomTerminalState(threadID: threadID, isExpanded: true)
                }
                for metadata in snapshot.fileIndexMetadataByThreadID.values {
                    try insertFileIndexMetadata(metadata)
                }
                for activity in snapshot.threadActivityByThreadID.values {
                    try insertThreadActivity(activity)
                }
                for project in snapshot.projects {
                    try insertSidebarProjectState(
                        projectID: project.id,
                        isExpanded: snapshot.expandedProjectIDs.contains(project.id),
                        isArchiveExpanded: snapshot.expandedArchivedProjectIDs.contains(project.id)
                    )
                }
                try insertAppState(
                    key: "selected_project_id", value: snapshot.selectedProjectID.uuidString)
                if let selectedThreadID = snapshot.selectedThreadID {
                    try insertAppState(
                        key: "selected_thread_id", value: selectedThreadID.uuidString)
                }
                try insertAppState(
                    key: "is_global_terminal_expanded",
                    value: snapshot.isGlobalTerminalExpanded ? "true" : "false"
                )
                try insertLayoutState(snapshot.layoutState)
            }
        } catch {
            recordSQLiteError(name: "sqlite_save_failed", error: error)
        }
    }

    public func upsertProject(_ project: Project) {
        runIncremental(name: "upsert_project") {
            try upsertProjectStatement(project)
        }
    }

    public func upsertThread(_ thread: AgentThread) {
        runIncremental(name: "upsert_thread") {
            try upsertThreadStatement(thread)
        }
    }

    public func deleteThread(id: UUID) {
        runIncremental(name: "delete_thread") {
            let statement = try prepare("DELETE FROM threads WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    public func setRightPanelMode(threadID: UUID, mode: RightPanelMode) {
        runIncremental(name: "set_right_panel_mode") {
            let statement = try prepare(
                """
                INSERT INTO right_panel_modes (thread_id, mode) VALUES (?, ?)
                ON CONFLICT(thread_id) DO UPDATE SET mode = excluded.mode
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(threadID.uuidString, at: 1, in: statement)
            bind(mode.rawValue, at: 2, in: statement)
            try stepDone(statement)
        }
    }

    public func setRightPanelState(threadID: UUID, state: RightPanelState) {
        runIncremental(name: "set_right_panel_state") {
            let deleteStatement = try prepare("DELETE FROM right_panel_tabs WHERE thread_id = ?")
            bind(threadID.uuidString, at: 1, in: deleteStatement)
            try stepDone(deleteStatement)
            sqlite3_finalize(deleteStatement)

            let persistedState = state.persistenceSnapshot
            let tabs = RightPanelState.normalizedTabs(persistedState.tabs)
            for (index, tab) in tabs.enumerated() {
                let insertStatement = try prepare(
                    """
                    INSERT INTO right_panel_tabs (
                        thread_id, tab_id, kind, title, relative_path, url_string, tab_order
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(insertStatement) }
                bind(threadID.uuidString, at: 1, in: insertStatement)
                bind(tab.id, at: 2, in: insertStatement)
                bind(tab.kind.rawValue, at: 3, in: insertStatement)
                bind(tab.title, at: 4, in: insertStatement)
                bindOptional(tab.relativePath, at: 5, in: insertStatement)
                bindOptional(tab.urlString, at: 6, in: insertStatement)
                sqlite3_bind_int(insertStatement, 7, Int32(index))
                try stepDone(insertStatement)
            }

            let stateStatement = try prepare(
                """
                INSERT INTO right_panel_tab_state (thread_id, selected_tab_id) VALUES (?, ?)
                ON CONFLICT(thread_id) DO UPDATE SET selected_tab_id = excluded.selected_tab_id
                """
            )
            defer { sqlite3_finalize(stateStatement) }
            bind(threadID.uuidString, at: 1, in: stateStatement)
            bind(persistedState.selectedTabID, at: 2, in: stateStatement)
            try stepDone(stateStatement)
        }
    }

    public func setBottomTerminalExpanded(threadID: UUID, isExpanded: Bool) {
        runIncremental(name: "set_bottom_terminal_expanded") {
            if isExpanded {
                let statement = try prepare(
                    """
                    INSERT INTO bottom_terminal_state (thread_id, is_expanded) VALUES (?, 1)
                    ON CONFLICT(thread_id) DO UPDATE SET is_expanded = 1
                    """
                )
                defer { sqlite3_finalize(statement) }
                bind(threadID.uuidString, at: 1, in: statement)
                try stepDone(statement)
            } else {
                let statement = try prepare("DELETE FROM bottom_terminal_state WHERE thread_id = ?")
                defer { sqlite3_finalize(statement) }
                bind(threadID.uuidString, at: 1, in: statement)
                try stepDone(statement)
            }
        }
    }

    public func setSelectedProject(_ projectID: UUID) {
        runIncremental(name: "set_selected_project") {
            try upsertAppStateStatement(key: "selected_project_id", value: projectID.uuidString)
        }
    }

    public func setSelectedThread(_ threadID: UUID?) {
        runIncremental(name: "set_selected_thread") {
            if let threadID {
                try upsertAppStateStatement(key: "selected_thread_id", value: threadID.uuidString)
            } else {
                let statement = try prepare("DELETE FROM app_state WHERE key = ?")
                defer { sqlite3_finalize(statement) }
                bind("selected_thread_id", at: 1, in: statement)
                try stepDone(statement)
            }
        }
    }

    public func setLayoutState(_ state: LayoutState) {
        runIncremental(name: "set_layout_state") {
            try upsertLayoutStateValue(key: "sidebar_width", value: "\(state.sidebarWidth)")
            try upsertLayoutStateValue(key: "right_panel_width", value: "\(state.rightPanelWidth)")
            try upsertLayoutStateValue(
                key: "global_terminal_height", value: "\(state.globalTerminalHeight)")
            try upsertLayoutStateValue(
                key: "sidebar_collapsed", value: state.isSidebarCollapsed ? "true" : "false")
            try upsertLayoutStateValue(
                key: "right_panel_collapsed",
                value: state.isRightPanelCollapsed ? "true" : "false"
            )
            try upsertLayoutStateValue(
                key: "global_terminal_expanded",
                value: state.isGlobalTerminalExpanded ? "true" : "false"
            )
            try upsertLayoutStateValue(
                key: "workspace_swapped",
                value: state.isWorkspaceSwapped ? "true" : "false"
            )
        }
    }

    public func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        runIncremental(name: "set_project_expanded") {
            let currentArchiveState =
                try loadSidebarProjectState(projectID: projectID)?.isArchiveExpanded ?? false
            try upsertSidebarProjectState(
                projectID: projectID,
                isExpanded: isExpanded,
                isArchiveExpanded: currentArchiveState
            )
        }
    }

    public func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool) {
        runIncremental(name: "set_project_archive_expanded") {
            let currentExpandedState =
                try loadSidebarProjectState(projectID: projectID)?.isExpanded ?? false
            try upsertSidebarProjectState(
                projectID: projectID,
                isExpanded: currentExpandedState,
                isArchiveExpanded: isExpanded
            )
        }
    }

    public func upsertFileIndexMetadata(_ metadata: FileIndexMetadata) {
        runIncremental(name: "upsert_file_index_metadata") {
            let statement = try prepare(
                """
                INSERT INTO file_index_metadata (
                    thread_id,
                    cache_key,
                    root_path,
                    git_identity,
                    ignore_rules_fingerprint,
                    schema_version,
                    indexed_at,
                    file_count,
                    ignored_directory_count
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(thread_id) DO UPDATE SET
                    cache_key = excluded.cache_key,
                    root_path = excluded.root_path,
                    git_identity = excluded.git_identity,
                    ignore_rules_fingerprint = excluded.ignore_rules_fingerprint,
                    schema_version = excluded.schema_version,
                    indexed_at = excluded.indexed_at,
                    file_count = excluded.file_count,
                    ignored_directory_count = excluded.ignored_directory_count
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(metadata.threadID.uuidString, at: 1, in: statement)
            bindOptional(metadata.cacheKey, at: 2, in: statement)
            bind(metadata.rootPath, at: 3, in: statement)
            bind(metadata.gitIdentity, at: 4, in: statement)
            bind(metadata.ignoreRulesFingerprint, at: 5, in: statement)
            sqlite3_bind_int(statement, 6, Int32(metadata.schemaVersion))
            sqlite3_bind_double(statement, 7, metadata.indexedAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 8, Int32(metadata.fileCount))
            sqlite3_bind_int(statement, 9, Int32(metadata.ignoredDirectoryCount))
            try stepDone(statement)
        }
    }

    public func upsertThreadActivity(_ activity: ThreadActivityState) {
        runIncremental(name: "upsert_thread_activity") {
            try upsertThreadActivityStatement(activity)
        }
    }

    public func cachedFileIndex(cacheKey: String) -> CachedFileIndex? {
        do {
            return try loadCachedFileIndex(cacheKey: cacheKey)
        } catch {
            recordSQLiteError(name: "sqlite_load_cached_file_index_failed", error: error)
            return nil
        }
    }

    public func upsertCachedFileIndex(_ index: CachedFileIndex) {
        runIncremental(name: "upsert_cached_file_index") {
            guard let cacheKey = index.metadata.cacheKey else { return }
            try deleteCachedFileIndexEntries(cacheKey: cacheKey)
            try upsertCachedFileIndexMetadata(index.metadata)
            for (entryOrder, entry) in index.entries.enumerated() {
                try insertCachedFileIndexEntry(
                    cacheKey: cacheKey, entry: entry, entryOrder: entryOrder)
            }
        }
    }
}

extension SQLiteYAAWStore {
    fileprivate func recordSQLiteError(name: String, error: Error) {
        diagnosticRecorder.record(
            DiagnosticEvent(
                category: "SQLite",
                name: name,
                metadata: [
                    "database": databasePath.path,
                    "error": String(describing: error)
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " "),
                ]
            )
        )
    }

    fileprivate func open() throws {
        guard sqlite3_open(databasePath.path, &database) == SQLITE_OK else {
            throw SQLiteStoreError.openFailed(errorMessage)
        }
    }

    fileprivate func migrate() throws {
        try execute("PRAGMA foreign_keys = ON")
        let currentVersion = try userVersion()
        guard currentVersion <= Self.schemaVersion else {
            throw SQLiteStoreError.executionFailed("Unsupported schema version \(currentVersion)")
        }
        if currentVersion == 0 {
            try transaction {
                try createVersionOneSchema()
                try execute("PRAGMA user_version = 1")
            }
        }
        if currentVersion < 2 {
            try transaction {
                try migrateToVersionTwo()
                try execute("PRAGMA user_version = 2")
            }
        }
        if currentVersion < 3 {
            try transaction {
                try createLayoutStateSchema()
                try seedLayoutStateFromLegacyAppState()
                try execute("PRAGMA user_version = 3")
            }
        }
        if currentVersion < 4 {
            try transaction {
                try migrateToVersionFour()
                try execute("PRAGMA user_version = 4")
            }
        }
        if currentVersion < 5 {
            try transaction {
                try createFileIndexMetadataSchema()
                try execute("PRAGMA user_version = 5")
            }
        }
        if currentVersion < 6 {
            try transaction {
                try migrateToVersionSixAgentCLIValues()
                try execute("PRAGMA user_version = 6")
            }
        }
        if currentVersion < 7 {
            try transaction {
                try createBottomTerminalStateSchema()
                try seedBottomTerminalStateFromLegacyLayout()
                try execute("PRAGMA user_version = 7")
            }
        }
        if currentVersion < 8 {
            try transaction {
                try createRightPanelTabStateSchema()
                try seedRightPanelTabStateFromLegacyModes()
                try execute("PRAGMA user_version = 8")
            }
        }
        if currentVersion < 9 {
            try transaction {
                try migrateToVersionNine()
                try execute("PRAGMA user_version = 9")
            }
        }
        if currentVersion < 10 {
            try transaction {
                try migrateToVersionTen()
                try execute("PRAGMA user_version = 10")
            }
        }
        if currentVersion < 11 {
            try transaction {
                try migrateToVersionEleven()
                try execute("PRAGMA user_version = 11")
            }
        }
        if currentVersion < 12 {
            try transaction {
                try createThreadActivityStateSchema()
                try execute("PRAGMA user_version = 12")
            }
        }
        if currentVersion < 13 {
            try transaction {
                try migrateToVersionThirteen()
                try execute("PRAGMA user_version = 13")
            }
        }
        if currentVersion < 14 {
            try transaction {
                try migrateToVersionFourteen()
                try execute("PRAGMA user_version = 14")
            }
        }
    }

    fileprivate func migrateToVersionNine() throws {
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_threads_project_archived ON threads(project_id, is_archived)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_threads_last_opened ON threads(last_opened_at)"
        )
    }

    fileprivate func migrateToVersionTen() throws {
        let columns = try tableColumns("file_index_metadata")
        if !columns.contains("cache_key") {
            try execute("ALTER TABLE file_index_metadata ADD COLUMN cache_key TEXT")
        }
        if !columns.contains("git_identity") {
            try execute(
                "ALTER TABLE file_index_metadata ADD COLUMN git_identity TEXT NOT NULL DEFAULT 'nogit'"
            )
        }
        if !columns.contains("ignore_rules_fingerprint") {
            try execute(
                "ALTER TABLE file_index_metadata ADD COLUMN ignore_rules_fingerprint TEXT NOT NULL DEFAULT ''"
            )
        }
        if !columns.contains("schema_version") {
            try execute(
                "ALTER TABLE file_index_metadata ADD COLUMN schema_version INTEGER NOT NULL DEFAULT \(FileIndexMetadata.currentSchemaVersion)"
            )
        }
        try createFileIndexCacheSchema()
    }

    fileprivate func migrateToVersionEleven() throws {
        let projectColumns = try tableColumns("projects")
        if !projectColumns.contains("is_pinned") {
            try execute("ALTER TABLE projects ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
        }
        if !projectColumns.contains("sort_order") {
            try execute("ALTER TABLE projects ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0")
            try seedProjectSortOrder()
        }

        let threadColumns = try tableColumns("threads")
        if !threadColumns.contains("is_pinned") {
            try execute("ALTER TABLE threads ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
        }

        try createSidebarProjectStateSchema()
        if let selectedProjectID = try loadUUID(key: "selected_project_id") {
            try insertSidebarProjectState(
                projectID: selectedProjectID,
                isExpanded: true,
                isArchiveExpanded: false
            )
        }
    }

    fileprivate func migrateToVersionThirteen() throws {
        if try tableColumns("right_panel_modes").isEmpty {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS right_panel_modes (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'browser', 'nvim', 'git'))
                )
                """
            )
        } else {
            try execute(
                """
                CREATE TABLE right_panel_modes_v13 (
                    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    mode TEXT NOT NULL CHECK (mode IN ('files', 'browser', 'nvim', 'git'))
                )
                """
            )
            try execute(
                """
                INSERT INTO right_panel_modes_v13 (thread_id, mode)
                SELECT thread_id, mode FROM right_panel_modes
                WHERE mode IN ('files', 'browser', 'nvim', 'git')
                """
            )
            try execute("DROP TABLE right_panel_modes")
            try execute("ALTER TABLE right_panel_modes_v13 RENAME TO right_panel_modes")
        }

        let tabColumns = try tableColumns("right_panel_tabs")
        guard !tabColumns.isEmpty else {
            try createRightPanelTabStateSchema()
            return
        }
        let urlSelect = tabColumns.contains("url_string") ? "url_string" : "NULL"
        try execute(
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
            """
            INSERT INTO right_panel_tabs_v13 (
                thread_id, tab_id, kind, title, relative_path, url_string, tab_order
            )
            SELECT thread_id, tab_id, kind, title, relative_path, \(urlSelect), tab_order
            FROM right_panel_tabs
            WHERE kind IN ('files', 'browser', 'git', 'nvim')
            """
        )
        try execute("DROP TABLE right_panel_tabs")
        try execute("ALTER TABLE right_panel_tabs_v13 RENAME TO right_panel_tabs")
    }

    fileprivate func migrateToVersionFourteen() throws {
        let threadColumns = try tableColumns("threads")
        if !threadColumns.contains("pending_session_rename") {
            try execute("ALTER TABLE threads ADD COLUMN pending_session_rename TEXT")
        }
    }

    fileprivate func createThreadActivityStateSchema() throws {
        try execute(
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

    fileprivate func createVersionOneSchema() throws {
        try execute(
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
            """
            CREATE TABLE IF NOT EXISTS app_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS right_panel_modes (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                mode TEXT NOT NULL CHECK (mode IN ('files', 'browser', 'nvim', 'git'))
            )
            """
        )
    }

    fileprivate func migrateToVersionTwo() throws {
        let columns = try tableColumns("threads")
        guard !columns.contains("agent_cli") else { return }
        let existingThreadCount = try querySingleInt("SELECT COUNT(*) FROM threads") ?? 0
        guard existingThreadCount == 0 else {
            throw SQLiteStoreError.executionFailed(
                "Cannot migrate existing threads without explicit agent_cli choices"
            )
        }
        try execute(
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
        try execute("DROP TABLE threads")
        try execute("ALTER TABLE threads_v2 RENAME TO threads")
    }

    fileprivate func createLayoutStateSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS layout_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
    }

    fileprivate func seedLayoutStateFromLegacyAppState() throws {
        let isExpanded = try loadBool(key: "is_global_terminal_expanded") ?? false
        try insertLayoutState(LayoutState(isGlobalTerminalExpanded: isExpanded))
    }

    fileprivate func migrateToVersionFour() throws {
        let columns = try tableColumns("threads")
        if !columns.contains("session_identity") {
            try execute("ALTER TABLE threads ADD COLUMN session_identity TEXT")
        }
        if !columns.contains("canonical_session_name") {
            try execute("ALTER TABLE threads ADD COLUMN canonical_session_name TEXT")
        }
    }

    fileprivate func createFileIndexMetadataSchema() throws {
        try execute(
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

    fileprivate func createFileIndexCacheSchema() throws {
        try execute(
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
            "CREATE INDEX IF NOT EXISTS idx_file_index_cache_entries_order ON file_index_cache_entries(cache_key, entry_order)"
        )
    }

    fileprivate func migrateToVersionSixAgentCLIValues() throws {
        try execute("PRAGMA defer_foreign_keys = ON")
        try execute(
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
        try execute("DROP TABLE threads")
        try execute("ALTER TABLE threads_v6 RENAME TO threads")
    }

    fileprivate func createBottomTerminalStateSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS bottom_terminal_state (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                is_expanded INTEGER NOT NULL CHECK (is_expanded IN (0, 1))
            )
            """
        )
    }

    fileprivate func createRightPanelTabStateSchema() throws {
        try execute(
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
            """
            CREATE TABLE IF NOT EXISTS right_panel_tab_state (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                selected_tab_id TEXT NOT NULL
            )
            """
        )
    }

    fileprivate func createSidebarProjectStateSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sidebar_project_state (
                project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                is_expanded INTEGER NOT NULL CHECK (is_expanded IN (0, 1)),
                is_archive_expanded INTEGER NOT NULL CHECK (is_archive_expanded IN (0, 1))
            )
            """
        )
    }

    fileprivate func seedProjectSortOrder() throws {
        let statement = try prepare(
            "SELECT id FROM projects ORDER BY created_at, display_name"
        )
        defer { sqlite3_finalize(statement) }
        var projectIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            projectIDs.append(text(at: 0, in: statement))
        }
        for (index, projectID) in projectIDs.enumerated() {
            let updateStatement = try prepare("UPDATE projects SET sort_order = ? WHERE id = ?")
            defer { sqlite3_finalize(updateStatement) }
            sqlite3_bind_int(updateStatement, 1, Int32(index))
            bind(projectID, at: 2, in: updateStatement)
            try stepDone(updateStatement)
        }
    }

    fileprivate func seedBottomTerminalStateFromLegacyLayout() throws {
        let isExpanded =
            try loadLayoutBool(key: "global_terminal_expanded")
            ?? (try loadBool(key: "is_global_terminal_expanded") ?? false)
        guard isExpanded,
            let selectedThreadID = try loadUUID(key: "selected_thread_id")
        else {
            return
        }
        try insertBottomTerminalState(threadID: selectedThreadID, isExpanded: true)
    }

    fileprivate func seedRightPanelTabStateFromLegacyModes() throws {
        let modes = try loadRightPanelModes()
        let statement = try prepare("SELECT id FROM threads")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: statement)) else { continue }
            try insertRightPanelState(
                threadID: threadID,
                state: RightPanelState.defaultState(selectedMode: modes[threadID] ?? .files)
            )
        }
    }

    fileprivate func userVersion() throws -> Int {
        try querySingleInt("PRAGMA user_version") ?? 0
    }

    fileprivate func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    fileprivate func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(message)
            throw SQLiteStoreError.executionFailed(error)
        }
    }

    fileprivate func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(errorMessage)
        }
        return statement
    }

    fileprivate func querySingleInt(_ sql: String) throws -> Int? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    fileprivate func tableColumns(_ table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(at: 1, in: statement))
        }
        return columns
    }

    fileprivate var errorMessage: String {
        guard let database else { return "Missing SQLite database" }
        return String(cString: sqlite3_errmsg(database))
    }

    fileprivate func runIncremental(name: String, _ work: () throws -> Void) {
        do {
            try transaction(work)
        } catch {
            recordSQLiteError(name: "sqlite_\(name)_failed", error: error)
        }
    }

    fileprivate func upsertProjectStatement(_ project: Project) throws {
        let statement = try prepare(
            """
            INSERT INTO projects (
                id,
                display_name,
                root_directory,
                created_at,
                last_opened_at,
                is_pinned,
                sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                root_directory = excluded.root_directory,
                created_at = excluded.created_at,
                last_opened_at = excluded.last_opened_at,
                is_pinned = excluded.is_pinned,
                sort_order = excluded.sort_order
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(project.id.uuidString, at: 1, in: statement)
        bind(project.displayName, at: 2, in: statement)
        bind(project.rootDirectory.path, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, project.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, project.lastOpenedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 6, project.isPinned ? 1 : 0)
        sqlite3_bind_int(statement, 7, Int32(project.sortOrder))
        try stepDone(statement)
    }

    fileprivate func upsertThreadStatement(_ thread: AgentThread) throws {
        let statement = try prepare(
            """
            INSERT INTO threads (
                id,
                display_name,
                project_id,
                working_directory,
                created_at,
                last_opened_at,
                is_archived,
                agent_cli,
                session_identity,
                canonical_session_name,
                pending_session_rename,
                is_pinned
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                project_id = excluded.project_id,
                working_directory = excluded.working_directory,
                created_at = excluded.created_at,
                last_opened_at = excluded.last_opened_at,
                is_archived = excluded.is_archived,
                agent_cli = excluded.agent_cli,
                session_identity = excluded.session_identity,
                canonical_session_name = excluded.canonical_session_name,
                pending_session_rename = excluded.pending_session_rename,
                is_pinned = excluded.is_pinned
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(thread.id.uuidString, at: 1, in: statement)
        bind(thread.displayName, at: 2, in: statement)
        bind(thread.projectID.uuidString, at: 3, in: statement)
        bind(thread.workingDirectory.path, at: 4, in: statement)
        sqlite3_bind_double(statement, 5, thread.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, thread.lastOpenedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 7, thread.isArchived ? 1 : 0)
        bind(thread.agentCLI.rawValue, at: 8, in: statement)
        bindOptional(thread.sessionIdentity, at: 9, in: statement)
        bindOptional(thread.canonicalSessionName, at: 10, in: statement)
        bindOptional(thread.pendingSessionRename, at: 11, in: statement)
        sqlite3_bind_int(statement, 12, thread.isPinned ? 1 : 0)
        try stepDone(statement)
    }

    fileprivate func upsertAppStateStatement(key: String, value: String) throws {
        let statement = try prepare(
            """
            INSERT INTO app_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    fileprivate func upsertLayoutStateValue(key: String, value: String) throws {
        let statement = try prepare(
            """
            INSERT INTO layout_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    fileprivate func insertProject(_ project: Project) throws {
        let statement = try prepare(
            """
            INSERT INTO projects (
                id,
                display_name,
                root_directory,
                created_at,
                last_opened_at,
                is_pinned,
                sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(project.id.uuidString, at: 1, in: statement)
        bind(project.displayName, at: 2, in: statement)
        bind(project.rootDirectory.path, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, project.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, project.lastOpenedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 6, project.isPinned ? 1 : 0)
        sqlite3_bind_int(statement, 7, Int32(project.sortOrder))
        try stepDone(statement)
    }

    fileprivate func insertThread(_ thread: AgentThread) throws {
        let statement = try prepare(
            """
            INSERT INTO threads (
                id,
                display_name,
                project_id,
                working_directory,
                created_at,
                last_opened_at,
                is_archived,
                agent_cli,
                session_identity,
                canonical_session_name,
                pending_session_rename,
                is_pinned
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(thread.id.uuidString, at: 1, in: statement)
        bind(thread.displayName, at: 2, in: statement)
        bind(thread.projectID.uuidString, at: 3, in: statement)
        bind(thread.workingDirectory.path, at: 4, in: statement)
        sqlite3_bind_double(statement, 5, thread.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, thread.lastOpenedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 7, thread.isArchived ? 1 : 0)
        bind(thread.agentCLI.rawValue, at: 8, in: statement)
        bindOptional(thread.sessionIdentity, at: 9, in: statement)
        bindOptional(thread.canonicalSessionName, at: 10, in: statement)
        bindOptional(thread.pendingSessionRename, at: 11, in: statement)
        sqlite3_bind_int(statement, 12, thread.isPinned ? 1 : 0)
        try stepDone(statement)
    }

    fileprivate func insertRightPanelMode(threadID: UUID, mode: RightPanelMode) throws {
        let statement = try prepare(
            "INSERT INTO right_panel_modes (thread_id, mode) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        bind(threadID.uuidString, at: 1, in: statement)
        bind(mode.rawValue, at: 2, in: statement)
        try stepDone(statement)
    }

    fileprivate func insertRightPanelState(threadID: UUID, state: RightPanelState) throws {
        let persistedState = state.persistenceSnapshot
        let tabs = RightPanelState.normalizedTabs(persistedState.tabs)
        for (index, tab) in tabs.enumerated() {
            let statement = try prepare(
                """
                INSERT INTO right_panel_tabs (
                    thread_id,
                    tab_id,
                    kind,
                    title,
                    relative_path,
                    url_string,
                    tab_order
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(threadID.uuidString, at: 1, in: statement)
            bind(tab.id, at: 2, in: statement)
            bind(tab.kind.rawValue, at: 3, in: statement)
            bind(tab.title, at: 4, in: statement)
            bindOptional(tab.relativePath, at: 5, in: statement)
            bindOptional(tab.urlString, at: 6, in: statement)
            sqlite3_bind_int(statement, 7, Int32(index))
            try stepDone(statement)
        }

        let stateStatement = try prepare(
            "INSERT INTO right_panel_tab_state (thread_id, selected_tab_id) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(stateStatement) }
        bind(threadID.uuidString, at: 1, in: stateStatement)
        bind(persistedState.selectedTabID, at: 2, in: stateStatement)
        try stepDone(stateStatement)
    }

    fileprivate func insertBottomTerminalState(threadID: UUID, isExpanded: Bool) throws {
        let statement = try prepare(
            "INSERT INTO bottom_terminal_state (thread_id, is_expanded) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        bind(threadID.uuidString, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, isExpanded ? 1 : 0)
        try stepDone(statement)
    }

    fileprivate func insertSidebarProjectState(
        projectID: UUID, isExpanded: Bool, isArchiveExpanded: Bool
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO sidebar_project_state (
                project_id,
                is_expanded,
                is_archive_expanded
            )
            VALUES (?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, isExpanded ? 1 : 0)
        sqlite3_bind_int(statement, 3, isArchiveExpanded ? 1 : 0)
        try stepDone(statement)
    }

    fileprivate func upsertSidebarProjectState(
        projectID: UUID, isExpanded: Bool, isArchiveExpanded: Bool
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO sidebar_project_state (
                project_id,
                is_expanded,
                is_archive_expanded
            )
            VALUES (?, ?, ?)
            ON CONFLICT(project_id) DO UPDATE SET
                is_expanded = excluded.is_expanded,
                is_archive_expanded = excluded.is_archive_expanded
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, isExpanded ? 1 : 0)
        sqlite3_bind_int(statement, 3, isArchiveExpanded ? 1 : 0)
        try stepDone(statement)
    }

    fileprivate func insertAppState(key: String, value: String) throws {
        let statement = try prepare("INSERT INTO app_state (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    fileprivate func insertLayoutState(_ layoutState: LayoutState) throws {
        try insertLayoutStateValue(key: "sidebar_width", value: "\(layoutState.sidebarWidth)")
        try insertLayoutStateValue(
            key: "right_panel_width", value: "\(layoutState.rightPanelWidth)")
        try insertLayoutStateValue(
            key: "global_terminal_height", value: "\(layoutState.globalTerminalHeight)")
        try insertLayoutStateValue(
            key: "sidebar_collapsed", value: layoutState.isSidebarCollapsed ? "true" : "false")
        try insertLayoutStateValue(
            key: "right_panel_collapsed",
            value: layoutState.isRightPanelCollapsed ? "true" : "false"
        )
        try insertLayoutStateValue(
            key: "global_terminal_expanded",
            value: layoutState.isGlobalTerminalExpanded ? "true" : "false"
        )
        try insertLayoutStateValue(
            key: "workspace_swapped",
            value: layoutState.isWorkspaceSwapped ? "true" : "false"
        )
    }

    fileprivate func insertLayoutStateValue(key: String, value: String) throws {
        let statement = try prepare("INSERT INTO layout_state (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    fileprivate func insertFileIndexMetadata(_ metadata: FileIndexMetadata) throws {
        let statement = try prepare(
            """
            INSERT INTO file_index_metadata (
                thread_id,
                cache_key,
                root_path,
                git_identity,
                ignore_rules_fingerprint,
                schema_version,
                indexed_at,
                file_count,
                ignored_directory_count
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(metadata.threadID.uuidString, at: 1, in: statement)
        bindOptional(metadata.cacheKey, at: 2, in: statement)
        bind(metadata.rootPath, at: 3, in: statement)
        bind(metadata.gitIdentity, at: 4, in: statement)
        bind(metadata.ignoreRulesFingerprint, at: 5, in: statement)
        sqlite3_bind_int(statement, 6, Int32(metadata.schemaVersion))
        sqlite3_bind_double(statement, 7, metadata.indexedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 8, Int32(metadata.fileCount))
        sqlite3_bind_int(statement, 9, Int32(metadata.ignoredDirectoryCount))
        try stepDone(statement)
    }

    fileprivate func insertThreadActivity(_ activity: ThreadActivityState) throws {
        let statement = try prepare(
            """
            INSERT INTO thread_activity_state (
                thread_id,
                status,
                preview,
                is_unread,
                title,
                body,
                source,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(activity.threadID.uuidString, at: 1, in: statement)
        bind(activity.status.rawValue, at: 2, in: statement)
        bindOptional(activity.preview, at: 3, in: statement)
        sqlite3_bind_int(statement, 4, activity.isUnread ? 1 : 0)
        bindOptional(activity.title, at: 5, in: statement)
        bindOptional(activity.body, at: 6, in: statement)
        bind(activity.source.rawValue, at: 7, in: statement)
        sqlite3_bind_double(statement, 8, activity.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    fileprivate func upsertThreadActivityStatement(_ activity: ThreadActivityState) throws {
        let statement = try prepare(
            """
            INSERT INTO thread_activity_state (
                thread_id,
                status,
                preview,
                is_unread,
                title,
                body,
                source,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
                status = excluded.status,
                preview = excluded.preview,
                is_unread = excluded.is_unread,
                title = excluded.title,
                body = excluded.body,
                source = excluded.source,
                updated_at = excluded.updated_at
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(activity.threadID.uuidString, at: 1, in: statement)
        bind(activity.status.rawValue, at: 2, in: statement)
        bindOptional(activity.preview, at: 3, in: statement)
        sqlite3_bind_int(statement, 4, activity.isUnread ? 1 : 0)
        bindOptional(activity.title, at: 5, in: statement)
        bindOptional(activity.body, at: 6, in: statement)
        bind(activity.source.rawValue, at: 7, in: statement)
        sqlite3_bind_double(statement, 8, activity.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    fileprivate func deleteCachedFileIndexEntries(cacheKey: String) throws {
        let statement = try prepare("DELETE FROM file_index_cache_entries WHERE cache_key = ?")
        defer { sqlite3_finalize(statement) }
        bind(cacheKey, at: 1, in: statement)
        try stepDone(statement)
    }

    fileprivate func upsertCachedFileIndexMetadata(_ metadata: FileIndexMetadata) throws {
        guard let cacheKey = metadata.cacheKey else { return }
        let statement = try prepare(
            """
            INSERT INTO file_index_cache_metadata (
                cache_key,
                root_path,
                git_identity,
                ignore_rules_fingerprint,
                schema_version,
                indexed_at,
                file_count,
                ignored_directory_count
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(cache_key) DO UPDATE SET
                root_path = excluded.root_path,
                git_identity = excluded.git_identity,
                ignore_rules_fingerprint = excluded.ignore_rules_fingerprint,
                schema_version = excluded.schema_version,
                indexed_at = excluded.indexed_at,
                file_count = excluded.file_count,
                ignored_directory_count = excluded.ignored_directory_count
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(cacheKey, at: 1, in: statement)
        bind(metadata.rootPath, at: 2, in: statement)
        bind(metadata.gitIdentity, at: 3, in: statement)
        bind(metadata.ignoreRulesFingerprint, at: 4, in: statement)
        sqlite3_bind_int(statement, 5, Int32(metadata.schemaVersion))
        sqlite3_bind_double(statement, 6, metadata.indexedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 7, Int32(metadata.fileCount))
        sqlite3_bind_int(statement, 8, Int32(metadata.ignoredDirectoryCount))
        try stepDone(statement)
    }

    fileprivate func insertCachedFileIndexEntry(
        cacheKey: String, entry: FileBrowserEntry, entryOrder: Int
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO file_index_cache_entries (
                cache_key,
                relative_path,
                is_directory,
                entry_order
            )
            VALUES (?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(cacheKey, at: 1, in: statement)
        bind(entry.relativePath, at: 2, in: statement)
        sqlite3_bind_int(statement, 3, entry.isDirectory ? 1 : 0)
        sqlite3_bind_int(statement, 4, Int32(entryOrder))
        try stepDone(statement)
    }

    fileprivate func loadBottomTerminalExpandedThreadIDs() throws -> Set<UUID> {
        let statement = try prepare(
            "SELECT thread_id FROM bottom_terminal_state WHERE is_expanded = 1"
        )
        defer { sqlite3_finalize(statement) }
        var threadIDs = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(at: 0, in: statement)) {
                threadIDs.insert(id)
            }
        }
        return threadIDs
    }

    fileprivate func loadSidebarProjectState() throws -> SidebarProjectStateSnapshot {
        let statement = try prepare(
            "SELECT project_id, is_expanded, is_archive_expanded FROM sidebar_project_state"
        )
        defer { sqlite3_finalize(statement) }
        var expandedProjectIDs = Set<UUID>()
        var expandedArchivedProjectIDs = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, in: statement)) else { continue }
            if sqlite3_column_int(statement, 1) == 1 {
                expandedProjectIDs.insert(id)
            }
            if sqlite3_column_int(statement, 2) == 1 {
                expandedArchivedProjectIDs.insert(id)
            }
        }
        return SidebarProjectStateSnapshot(
            expandedProjectIDs: expandedProjectIDs,
            expandedArchivedProjectIDs: expandedArchivedProjectIDs
        )
    }

    fileprivate func loadSidebarProjectState(projectID: UUID) throws -> SidebarProjectStateRow? {
        let statement = try prepare(
            "SELECT is_expanded, is_archive_expanded FROM sidebar_project_state WHERE project_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return SidebarProjectStateRow(
            isExpanded: sqlite3_column_int(statement, 0) == 1,
            isArchiveExpanded: sqlite3_column_int(statement, 1) == 1
        )
    }

    fileprivate func loadProjects() throws -> [Project] {
        let statement = try prepare(
            """
            SELECT
                id,
                display_name,
                root_directory,
                created_at,
                last_opened_at,
                is_pinned,
                sort_order
            FROM projects
            ORDER BY is_pinned DESC, sort_order, created_at, display_name
            """
        )
        defer { sqlite3_finalize(statement) }
        var projects: [Project] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, in: statement)) else {
                throw SQLiteStoreError.executionFailed("Invalid project id")
            }
            projects.append(
                Project(
                    id: id,
                    displayName: text(at: 1, in: statement),
                    rootDirectory: URL(
                        fileURLWithPath: text(at: 2, in: statement), isDirectory: true),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    isPinned: sqlite3_column_int(statement, 5) == 1,
                    sortOrder: Int(sqlite3_column_int(statement, 6))
                )
            )
        }
        return projects
    }

    fileprivate func loadThreads() throws -> [AgentThread] {
        let statement = try prepare(
            """
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
                canonical_session_name,
                pending_session_rename,
                is_pinned
            FROM threads
            ORDER BY created_at, display_name
            """
        )
        defer { sqlite3_finalize(statement) }
        var threads: [AgentThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, in: statement)),
                let projectID = UUID(uuidString: text(at: 2, in: statement)),
                let agentCLI = AgentCLIKind(rawValue: text(at: 7, in: statement))
            else {
                throw SQLiteStoreError.executionFailed("Invalid thread id")
            }
            threads.append(
                AgentThread(
                    id: id,
                    displayName: text(at: 1, in: statement),
                    projectID: projectID,
                    workingDirectory: URL(
                        fileURLWithPath: text(at: 3, in: statement), isDirectory: true),
                    agentCLI: agentCLI,
                    sessionIdentity: optionalText(at: 8, in: statement),
                    canonicalSessionName: optionalText(at: 9, in: statement),
                    pendingSessionRename: optionalText(at: 10, in: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    isArchived: sqlite3_column_int(statement, 6) == 1,
                    isPinned: sqlite3_column_int(statement, 11) == 1
                )
            )
        }
        return threads
    }

    fileprivate func loadUUID(key: String) throws -> UUID? {
        let statement = try prepare("SELECT value FROM app_state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return UUID(uuidString: text(at: 0, in: statement))
    }

    fileprivate func loadBool(key: String) throws -> Bool? {
        let statement = try prepare("SELECT value FROM app_state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        switch text(at: 0, in: statement) {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    fileprivate func loadLayoutState(fallbackGlobalTerminalExpanded: Bool) throws -> LayoutState {
        LayoutState(
            sidebarWidth: try loadLayoutDouble(key: "sidebar_width")
                ?? LayoutState.defaultSidebarWidth,
            rightPanelWidth: try loadLayoutDouble(key: "right_panel_width")
                ?? LayoutState.defaultRightPanelWidth,
            globalTerminalHeight: try loadLayoutDouble(key: "global_terminal_height")
                ?? LayoutState.defaultGlobalTerminalHeight,
            isSidebarCollapsed: try loadLayoutBool(key: "sidebar_collapsed") ?? false,
            isRightPanelCollapsed: try loadLayoutBool(key: "right_panel_collapsed") ?? false,
            isGlobalTerminalExpanded: try loadLayoutBool(key: "global_terminal_expanded")
                ?? fallbackGlobalTerminalExpanded,
            isWorkspaceSwapped: try loadLayoutBool(key: "workspace_swapped") ?? false
        )
    }

    fileprivate func loadLayoutDouble(key: String) throws -> Double? {
        guard let value = try loadLayoutValue(key: key) else { return nil }
        return Double(value)
    }

    fileprivate func loadLayoutBool(key: String) throws -> Bool? {
        guard let value = try loadLayoutValue(key: key) else { return nil }
        switch value {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    fileprivate func loadLayoutValue(key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM layout_state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(at: 0, in: statement)
    }

    fileprivate func loadRightPanelModes() throws -> [UUID: RightPanelMode] {
        let statement = try prepare("SELECT thread_id, mode FROM right_panel_modes")
        defer { sqlite3_finalize(statement) }
        var modes: [UUID: RightPanelMode] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let threadID = UUID(uuidString: text(at: 0, in: statement)),
                let mode = RightPanelMode(rawValue: text(at: 1, in: statement))
            {
                modes[threadID] = mode
            }
        }
        return modes
    }

    fileprivate func loadRightPanelStates(fallbackModes: [UUID: RightPanelMode]) throws -> [UUID:
        RightPanelState]
    {
        let tabsStatement = try prepare(
            """
            SELECT thread_id, tab_id, kind, title, relative_path, url_string
            FROM right_panel_tabs
            ORDER BY thread_id, tab_order, title
            """
        )
        defer { sqlite3_finalize(tabsStatement) }
        var tabsByThreadID: [UUID: [RightPanelTab]] = [:]
        while sqlite3_step(tabsStatement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: tabsStatement)),
                let kind = RightPanelTabKind(rawValue: text(at: 2, in: tabsStatement))
            else {
                continue
            }
            tabsByThreadID[threadID, default: []].append(
                RightPanelTab(
                    id: text(at: 1, in: tabsStatement),
                    kind: kind,
                    title: text(at: 3, in: tabsStatement),
                    relativePath: optionalText(at: 4, in: tabsStatement),
                    urlString: optionalText(at: 5, in: tabsStatement)
                )
            )
        }

        let stateStatement = try prepare(
            "SELECT thread_id, selected_tab_id FROM right_panel_tab_state")
        defer { sqlite3_finalize(stateStatement) }
        var selectedTabIDsByThreadID: [UUID: String] = [:]
        while sqlite3_step(stateStatement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: stateStatement)) else { continue }
            selectedTabIDsByThreadID[threadID] = text(at: 1, in: stateStatement)
        }

        var states: [UUID: RightPanelState] = [:]
        for thread in try loadThreads() {
            let tabs = tabsByThreadID[thread.id] ?? RightPanelState.defaultTabs
            let selectedTabID =
                selectedTabIDsByThreadID[thread.id]
                ?? fallbackModes[thread.id]?.defaultTabID
                ?? RightPanelTab.filesID
            states[thread.id] = RightPanelState.restoredState(
                tabs: tabs, selectedTabID: selectedTabID)
        }
        return states
    }

    fileprivate func loadFileIndexMetadata() throws -> [UUID: FileIndexMetadata] {
        let statement = try prepare(
            """
            SELECT
                thread_id,
                cache_key,
                root_path,
                git_identity,
                ignore_rules_fingerprint,
                schema_version,
                indexed_at,
                file_count,
                ignored_directory_count
            FROM file_index_metadata
            """
        )
        defer { sqlite3_finalize(statement) }
        var metadataByThreadID: [UUID: FileIndexMetadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: statement)) else {
                throw SQLiteStoreError.executionFailed("Invalid file index thread id")
            }
            metadataByThreadID[threadID] = FileIndexMetadata(
                threadID: threadID,
                cacheKey: optionalText(at: 1, in: statement),
                rootPath: text(at: 2, in: statement),
                gitIdentity: text(at: 3, in: statement),
                ignoreRulesFingerprint: text(at: 4, in: statement),
                schemaVersion: Int(sqlite3_column_int(statement, 5)),
                indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                fileCount: Int(sqlite3_column_int(statement, 7)),
                ignoredDirectoryCount: Int(sqlite3_column_int(statement, 8))
            )
        }
        return metadataByThreadID
    }

    fileprivate func loadThreadActivity() throws -> [UUID: ThreadActivityState] {
        let statement = try prepare(
            """
            SELECT
                thread_id,
                status,
                preview,
                is_unread,
                title,
                body,
                source,
                updated_at
            FROM thread_activity_state
            """
        )
        defer { sqlite3_finalize(statement) }
        var activityByThreadID: [UUID: ThreadActivityState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: statement)),
                let status = ThreadActivityStatus(rawValue: text(at: 1, in: statement)),
                let source = ThreadActivitySource(rawValue: text(at: 6, in: statement))
            else {
                throw SQLiteStoreError.executionFailed("Invalid thread activity state")
            }
            activityByThreadID[threadID] = ThreadActivityState(
                threadID: threadID,
                status: status,
                preview: optionalText(at: 2, in: statement),
                isUnread: sqlite3_column_int(statement, 3) == 1,
                title: optionalText(at: 4, in: statement),
                body: optionalText(at: 5, in: statement),
                source: source,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
        }
        return activityByThreadID
    }

    fileprivate func loadCachedFileIndex(cacheKey: String) throws -> CachedFileIndex? {
        let metadataStatement = try prepare(
            """
            SELECT
                root_path,
                git_identity,
                ignore_rules_fingerprint,
                schema_version,
                indexed_at,
                file_count,
                ignored_directory_count
            FROM file_index_cache_metadata
            WHERE cache_key = ?
            """
        )
        defer { sqlite3_finalize(metadataStatement) }
        bind(cacheKey, at: 1, in: metadataStatement)
        guard sqlite3_step(metadataStatement) == SQLITE_ROW else { return nil }
        let metadata = FileIndexMetadata(
            threadID: UUID(),
            cacheKey: cacheKey,
            rootPath: text(at: 0, in: metadataStatement),
            gitIdentity: text(at: 1, in: metadataStatement),
            ignoreRulesFingerprint: text(at: 2, in: metadataStatement),
            schemaVersion: Int(sqlite3_column_int(metadataStatement, 3)),
            indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(metadataStatement, 4)),
            fileCount: Int(sqlite3_column_int(metadataStatement, 5)),
            ignoredDirectoryCount: Int(sqlite3_column_int(metadataStatement, 6))
        )

        let entriesStatement = try prepare(
            """
            SELECT relative_path, is_directory
            FROM file_index_cache_entries
            WHERE cache_key = ?
            ORDER BY entry_order, relative_path
            """
        )
        defer { sqlite3_finalize(entriesStatement) }
        bind(cacheKey, at: 1, in: entriesStatement)
        var entries: [FileBrowserEntry] = []
        while sqlite3_step(entriesStatement) == SQLITE_ROW {
            entries.append(
                FileBrowserEntry(
                    relativePath: text(at: 0, in: entriesStatement),
                    isDirectory: sqlite3_column_int(entriesStatement, 1) == 1
                )
            )
        }
        return CachedFileIndex(metadata: metadata, entries: entries)
    }

    fileprivate func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    fileprivate func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            bind(value, at: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    fileprivate func text(at index: Int32, in statement: OpaquePointer?) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    fileprivate func optionalText(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(at: index, in: statement)
    }

    fileprivate func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.executionFailed(errorMessage)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
