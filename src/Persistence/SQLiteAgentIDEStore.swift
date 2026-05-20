import Foundation
import SQLite3

public enum SQLiteStoreError: Error, Equatable {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)
    case missingDatabase
}

public final class SQLiteAgentIDEStore: AgentIDEStore {
    public static let schemaVersion = 1

    private let databasePath: URL
    private var database: OpaquePointer?

    public init(databasePath: URL) throws {
        self.databasePath = databasePath
        try FileManager.default.createDirectory(
            at: databasePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try open()
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    public static func defaultStore() -> AgentIDEStore {
        do {
            return try SQLiteAgentIDEStore(databasePath: defaultDatabasePath())
        } catch {
            return InMemoryAgentIDEStore.helloWorld()
        }
    }

    public static func defaultDatabasePath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AgentIDE", isDirectory: true)
            .appendingPathComponent("AgentIDE.sqlite")
    }

    public func load() -> AgentIDESnapshot {
        do {
            let projects = try loadProjects()
            if projects.isEmpty {
                let seed = InMemoryAgentIDEStore.helloWorld().load()
                save(seed)
                return seed
            }

            let threads = try loadThreads()
            let selectedProjectID = try loadUUID(key: "selected_project_id") ?? projects[0].id
            let selectedThreadID = try loadUUID(key: "selected_thread_id")
                ?? threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
            let modes = try loadRightPanelModes()
            let selectedMode = selectedThreadID.flatMap { modes[$0] } ?? .files
            let isGlobalTerminalExpanded = try loadBool(key: "is_global_terminal_expanded") ?? false

            return AgentIDESnapshot(
                projects: projects,
                threads: threads,
                selectedProjectID: selectedProjectID,
                selectedThreadID: selectedThreadID,
                rightPanelModesByThreadID: modes,
                selectedRightPanelMode: selectedMode,
                isGlobalTerminalExpanded: isGlobalTerminalExpanded
            )
        } catch {
            return InMemoryAgentIDEStore.helloWorld().load()
        }
    }

    public func save(_ snapshot: AgentIDESnapshot) {
        do {
            try transaction {
                try execute("DELETE FROM right_panel_modes")
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
                try insertAppState(key: "selected_project_id", value: snapshot.selectedProjectID.uuidString)
                if let selectedThreadID = snapshot.selectedThreadID {
                    try insertAppState(key: "selected_thread_id", value: selectedThreadID.uuidString)
                }
                try insertAppState(
                    key: "is_global_terminal_expanded",
                    value: snapshot.isGlobalTerminalExpanded ? "true" : "false"
                )
            }
        } catch {}
    }
}

private extension SQLiteAgentIDEStore {
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
                try execute("PRAGMA user_version = \(Self.schemaVersion)")
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
            INSERT INTO threads (id, display_name, project_id, working_directory, created_at, last_opened_at, is_archived)
            VALUES (?, ?, ?, ?, ?, ?, ?)
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

    func insertAppState(key: String, value: String) throws {
        let statement = try prepare("INSERT INTO app_state (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
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
            SELECT id, display_name, project_id, working_directory, created_at, last_opened_at, is_archived
            FROM threads
            ORDER BY created_at, display_name
            """
        )
        defer { sqlite3_finalize(statement) }
        var threads: [AgentThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, in: statement)),
                  let projectID = UUID(uuidString: text(at: 2, in: statement)) else {
                throw SQLiteStoreError.executionFailed("Invalid thread id")
            }
            threads.append(
                AgentThread(
                    id: id,
                    displayName: text(at: 1, in: statement),
                    projectID: projectID,
                    workingDirectory: URL(fileURLWithPath: text(at: 3, in: statement), isDirectory: true),
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

    func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    func text(at index: Int32, in statement: OpaquePointer?) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.executionFailed(errorMessage)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
