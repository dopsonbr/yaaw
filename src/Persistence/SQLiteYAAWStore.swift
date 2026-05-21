import Foundation
import SQLite3

public enum SQLiteStoreError: Error, Equatable {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)
    case missingDatabase
}

public final class SQLiteYAAWStore: YAAWStore {
    public static let schemaVersion = 8

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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
            let selectedThreadID = try loadUUID(key: "selected_thread_id")
                ?? threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
            let modes = try loadRightPanelModes()
            let rightPanelStates = try loadRightPanelStates(fallbackModes: modes)
            let selectedMode = selectedThreadID.map { rightPanelStates[$0]?.selectedMode ?? modes[$0] ?? .files } ?? .files
            let fallbackGlobalTerminalExpanded = try loadBool(key: "is_global_terminal_expanded") ?? false
            let layoutState = try loadLayoutState(
                fallbackGlobalTerminalExpanded: fallbackGlobalTerminalExpanded
            )
            let fileIndexMetadata = try loadFileIndexMetadata()
            let bottomTerminalExpandedThreadIDs = try loadBottomTerminalExpandedThreadIDs()

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
                fileIndexMetadataByThreadID: fileIndexMetadata
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
                    let state = snapshot.rightPanelStatesByThreadID[thread.id]
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
                try insertAppState(key: "selected_project_id", value: snapshot.selectedProjectID.uuidString)
                if let selectedThreadID = snapshot.selectedThreadID {
                    try insertAppState(key: "selected_thread_id", value: selectedThreadID.uuidString)
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
}

private extension SQLiteYAAWStore {
    func recordSQLiteError(name: String, error: Error) {
        diagnosticRecorder.record(
            DiagnosticEvent(
                category: "SQLite",
                name: name,
                metadata: [
                    "database": databasePath.path,
                    "error": String(describing: error)
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                ]
            )
        )
    }

    func open() throws {
        guard sqlite3_open(databasePath.path, &database) == SQLITE_OK else {
            throw SQLiteStoreError.openFailed(errorMessage)
        }
    }

    func migrate() throws {
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
    }

    func createVersionOneSchema() throws {
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
                mode TEXT NOT NULL CHECK (mode IN ('files', 'nvim', 'git'))
            )
            """
        )
    }

    func migrateToVersionTwo() throws {
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

    func createLayoutStateSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS layout_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
    }

    func seedLayoutStateFromLegacyAppState() throws {
        let isExpanded = try loadBool(key: "is_global_terminal_expanded") ?? false
        try insertLayoutState(LayoutState(isGlobalTerminalExpanded: isExpanded))
    }

    func migrateToVersionFour() throws {
        let columns = try tableColumns("threads")
        if !columns.contains("session_identity") {
            try execute("ALTER TABLE threads ADD COLUMN session_identity TEXT")
        }
        if !columns.contains("canonical_session_name") {
            try execute("ALTER TABLE threads ADD COLUMN canonical_session_name TEXT")
        }
    }

    func createFileIndexMetadataSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS file_index_metadata (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                root_path TEXT NOT NULL,
                indexed_at REAL NOT NULL,
                file_count INTEGER NOT NULL,
                ignored_directory_count INTEGER NOT NULL
            )
            """
        )
    }

    func migrateToVersionSixAgentCLIValues() throws {
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

    func createBottomTerminalStateSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS bottom_terminal_state (
                thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                is_expanded INTEGER NOT NULL CHECK (is_expanded IN (0, 1))
            )
            """
        )
    }

    func createRightPanelTabStateSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS right_panel_tabs (
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                tab_id TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('files', 'git', 'nvim')),
                title TEXT NOT NULL,
                relative_path TEXT,
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

    func seedBottomTerminalStateFromLegacyLayout() throws {
        let isExpanded = try loadLayoutBool(key: "global_terminal_expanded")
            ?? (try loadBool(key: "is_global_terminal_expanded") ?? false)
        guard isExpanded,
              let selectedThreadID = try loadUUID(key: "selected_thread_id") else {
            return
        }
        try insertBottomTerminalState(threadID: selectedThreadID, isExpanded: true)
    }

    func seedRightPanelTabStateFromLegacyModes() throws {
        let modes = try loadRightPanelModes()
        for thread in try loadThreads() {
            try insertRightPanelState(
                threadID: thread.id,
                state: RightPanelState.defaultState(selectedMode: modes[thread.id] ?? .files)
            )
        }
    }

    func userVersion() throws -> Int {
        try querySingleInt("PRAGMA user_version") ?? 0
    }

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(message)
            throw SQLiteStoreError.executionFailed(error)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(errorMessage)
        }
        return statement
    }

    func querySingleInt(_ sql: String) throws -> Int? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    func tableColumns(_ table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(at: 1, in: statement))
        }
        return columns
    }

    var errorMessage: String {
        guard let database else { return "Missing SQLite database" }
        return String(cString: sqlite3_errmsg(database))
    }

    func insertProject(_ project: Project) throws {
        let statement = try prepare(
            """
            INSERT INTO projects (id, display_name, root_directory, created_at, last_opened_at)
            VALUES (?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(project.id.uuidString, at: 1, in: statement)
        bind(project.displayName, at: 2, in: statement)
        bind(project.rootDirectory.path, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, project.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, project.lastOpenedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    func insertThread(_ thread: AgentThread) throws {
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
                canonical_session_name
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        try stepDone(statement)
    }

    func insertRightPanelMode(threadID: UUID, mode: RightPanelMode) throws {
        let statement = try prepare(
            "INSERT INTO right_panel_modes (thread_id, mode) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        bind(threadID.uuidString, at: 1, in: statement)
        bind(mode.rawValue, at: 2, in: statement)
        try stepDone(statement)
    }

    func insertRightPanelState(threadID: UUID, state: RightPanelState) throws {
        let tabs = RightPanelState.normalizedTabs(state.tabs)
        for (index, tab) in tabs.enumerated() {
            let statement = try prepare(
                """
                INSERT INTO right_panel_tabs (
                    thread_id,
                    tab_id,
                    kind,
                    title,
                    relative_path,
                    tab_order
                )
                VALUES (?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(threadID.uuidString, at: 1, in: statement)
            bind(tab.id, at: 2, in: statement)
            bind(tab.kind.rawValue, at: 3, in: statement)
            bind(tab.title, at: 4, in: statement)
            bindOptional(tab.relativePath, at: 5, in: statement)
            sqlite3_bind_int(statement, 6, Int32(index))
            try stepDone(statement)
        }

        let stateStatement = try prepare(
            "INSERT INTO right_panel_tab_state (thread_id, selected_tab_id) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(stateStatement) }
        bind(threadID.uuidString, at: 1, in: stateStatement)
        bind(state.selectedTabID, at: 2, in: stateStatement)
        try stepDone(stateStatement)
    }

    func insertBottomTerminalState(threadID: UUID, isExpanded: Bool) throws {
        let statement = try prepare(
            "INSERT INTO bottom_terminal_state (thread_id, is_expanded) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        bind(threadID.uuidString, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, isExpanded ? 1 : 0)
        try stepDone(statement)
    }

    func insertAppState(key: String, value: String) throws {
        let statement = try prepare("INSERT INTO app_state (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    func insertLayoutState(_ layoutState: LayoutState) throws {
        try insertLayoutStateValue(key: "sidebar_width", value: "\(layoutState.sidebarWidth)")
        try insertLayoutStateValue(key: "right_panel_width", value: "\(layoutState.rightPanelWidth)")
        try insertLayoutStateValue(key: "global_terminal_height", value: "\(layoutState.globalTerminalHeight)")
        try insertLayoutStateValue(key: "sidebar_collapsed", value: layoutState.isSidebarCollapsed ? "true" : "false")
        try insertLayoutStateValue(
            key: "right_panel_collapsed",
            value: layoutState.isRightPanelCollapsed ? "true" : "false"
        )
        try insertLayoutStateValue(
            key: "global_terminal_expanded",
            value: layoutState.isGlobalTerminalExpanded ? "true" : "false"
        )
    }

    func insertLayoutStateValue(key: String, value: String) throws {
        let statement = try prepare("INSERT INTO layout_state (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    func insertFileIndexMetadata(_ metadata: FileIndexMetadata) throws {
        let statement = try prepare(
            """
            INSERT INTO file_index_metadata (
                thread_id,
                root_path,
                indexed_at,
                file_count,
                ignored_directory_count
            )
            VALUES (?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(metadata.threadID.uuidString, at: 1, in: statement)
        bind(metadata.rootPath, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, metadata.indexedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Int32(metadata.fileCount))
        sqlite3_bind_int(statement, 5, Int32(metadata.ignoredDirectoryCount))
        try stepDone(statement)
    }

    func loadBottomTerminalExpandedThreadIDs() throws -> Set<UUID> {
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

    func loadProjects() throws -> [Project] {
        let statement = try prepare(
            "SELECT id, display_name, root_directory, created_at, last_opened_at FROM projects ORDER BY created_at, display_name"
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
                    rootDirectory: URL(fileURLWithPath: text(at: 2, in: statement), isDirectory: true),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                )
            )
        }
        return projects
    }

    func loadThreads() throws -> [AgentThread] {
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
                canonical_session_name
            FROM threads
            ORDER BY created_at, display_name
            """
        )
        defer { sqlite3_finalize(statement) }
        var threads: [AgentThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, in: statement)),
                  let projectID = UUID(uuidString: text(at: 2, in: statement)),
                  let agentCLI = AgentCLIKind(rawValue: text(at: 7, in: statement)) else {
                throw SQLiteStoreError.executionFailed("Invalid thread id")
            }
            threads.append(
                AgentThread(
                    id: id,
                    displayName: text(at: 1, in: statement),
                    projectID: projectID,
                    workingDirectory: URL(fileURLWithPath: text(at: 3, in: statement), isDirectory: true),
                    agentCLI: agentCLI,
                    sessionIdentity: optionalText(at: 8, in: statement),
                    canonicalSessionName: optionalText(at: 9, in: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    isArchived: sqlite3_column_int(statement, 6) == 1
                )
            )
        }
        return threads
    }

    func loadUUID(key: String) throws -> UUID? {
        let statement = try prepare("SELECT value FROM app_state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return UUID(uuidString: text(at: 0, in: statement))
    }

    func loadBool(key: String) throws -> Bool? {
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

    func loadLayoutState(fallbackGlobalTerminalExpanded: Bool) throws -> LayoutState {
        LayoutState(
            sidebarWidth: try loadLayoutDouble(key: "sidebar_width") ?? LayoutState.defaultSidebarWidth,
            rightPanelWidth: try loadLayoutDouble(key: "right_panel_width") ?? LayoutState.defaultRightPanelWidth,
            globalTerminalHeight: try loadLayoutDouble(key: "global_terminal_height")
                ?? LayoutState.defaultGlobalTerminalHeight,
            isSidebarCollapsed: try loadLayoutBool(key: "sidebar_collapsed") ?? false,
            isRightPanelCollapsed: try loadLayoutBool(key: "right_panel_collapsed") ?? false,
            isGlobalTerminalExpanded: try loadLayoutBool(key: "global_terminal_expanded")
                ?? fallbackGlobalTerminalExpanded
        )
    }

    func loadLayoutDouble(key: String) throws -> Double? {
        guard let value = try loadLayoutValue(key: key) else { return nil }
        return Double(value)
    }

    func loadLayoutBool(key: String) throws -> Bool? {
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

    func loadLayoutValue(key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM layout_state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(at: 0, in: statement)
    }

    func loadRightPanelModes() throws -> [UUID: RightPanelMode] {
        let statement = try prepare("SELECT thread_id, mode FROM right_panel_modes")
        defer { sqlite3_finalize(statement) }
        var modes: [UUID: RightPanelMode] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let threadID = UUID(uuidString: text(at: 0, in: statement)),
               let mode = RightPanelMode(rawValue: text(at: 1, in: statement)) {
                modes[threadID] = mode
            }
        }
        return modes
    }

    func loadRightPanelStates(fallbackModes: [UUID: RightPanelMode]) throws -> [UUID: RightPanelState] {
        let tabsStatement = try prepare(
            """
            SELECT thread_id, tab_id, kind, title, relative_path
            FROM right_panel_tabs
            ORDER BY thread_id, tab_order, title
            """
        )
        defer { sqlite3_finalize(tabsStatement) }
        var tabsByThreadID: [UUID: [RightPanelTab]] = [:]
        while sqlite3_step(tabsStatement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: tabsStatement)),
                  let kind = RightPanelTabKind(rawValue: text(at: 2, in: tabsStatement)) else {
                continue
            }
            tabsByThreadID[threadID, default: []].append(
                RightPanelTab(
                    id: text(at: 1, in: tabsStatement),
                    kind: kind,
                    title: text(at: 3, in: tabsStatement),
                    relativePath: optionalText(at: 4, in: tabsStatement)
                )
            )
        }

        let stateStatement = try prepare("SELECT thread_id, selected_tab_id FROM right_panel_tab_state")
        defer { sqlite3_finalize(stateStatement) }
        var selectedTabIDsByThreadID: [UUID: String] = [:]
        while sqlite3_step(stateStatement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: stateStatement)) else { continue }
            selectedTabIDsByThreadID[threadID] = text(at: 1, in: stateStatement)
        }

        var states: [UUID: RightPanelState] = [:]
        for thread in try loadThreads() {
            let tabs = tabsByThreadID[thread.id] ?? RightPanelState.defaultTabs
            let selectedTabID = selectedTabIDsByThreadID[thread.id]
                ?? fallbackModes[thread.id]?.defaultTabID
                ?? RightPanelTab.filesID
            states[thread.id] = RightPanelState(tabs: tabs, selectedTabID: selectedTabID)
        }
        return states
    }

    func loadFileIndexMetadata() throws -> [UUID: FileIndexMetadata] {
        let statement = try prepare(
            """
            SELECT thread_id, root_path, indexed_at, file_count, ignored_directory_count
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
                rootPath: text(at: 1, in: statement),
                indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                fileCount: Int(sqlite3_column_int(statement, 3)),
                ignoredDirectoryCount: Int(sqlite3_column_int(statement, 4))
            )
        }
        return metadataByThreadID
    }

    func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            bind(value, at: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func text(at index: Int32, in statement: OpaquePointer?) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    func optionalText(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(at: index, in: statement)
    }

    func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.executionFailed(errorMessage)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
