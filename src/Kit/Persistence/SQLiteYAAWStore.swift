import Foundation
import SQLite3

public enum SQLiteStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)
    case missingDatabase
}

struct SidebarProjectStateSnapshot {
    var expandedProjectIDs: Set<UUID>
    var expandedArchivedProjectIDs: Set<UUID>
}

struct SidebarProjectStateRow {
    var isExpanded: Bool
    var isArchiveExpanded: Bool
}

/// Actor-isolated SQLite-backed `YAAWStore`.
///
/// The raw `sqlite3` connection handle and the prepared-statement cache are
/// actor-isolated stored properties: the actor — not a lock or an
/// `@unchecked Sendable` escape — is what serializes access to the
/// non-`Sendable` C pointers. Each method body is synchronous and isolated; an
/// actor's isolated synchronous method legally witnesses the `async` protocol
/// requirement, so external callers simply `await`.
public actor SQLiteYAAWStore: YAAWStore {
    public static let schemaVersion = 18

    let databasePath: URL
    let diagnosticRecorder: DiagnosticEventRecording

    /// Owns the SQLite handle and the prepared-statement cache, and finalizes +
    /// closes them in its own (ordinary class) `deinit` when the actor — its sole
    /// owner — is destroyed. The actor therefore needs NO deinit of its own,
    /// which avoids the `isolated deinit` that crashes the Swift 6.3 release
    /// optimizer (DECISIONS-LOG D-011), while keeping the non-Sendable handle and
    /// cache as actor-isolated state with no `@unchecked Sendable` escape hatch.
    private let connection: SQLiteConnection

    /// The live SQLite connection handle (set once at init).
    var database: OpaquePointer? { connection.handle }

    public init(
        databasePath: URL,
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared
    ) throws {
        self.databasePath = databasePath
        self.diagnosticRecorder = diagnosticRecorder
        // The SQLite layer is a set of `static` functions of an explicit handle.
        // Open on a local, hand it to the connection, then migrate: if migrate
        // throws, the throwing init releases `connection`, whose class deinit
        // closes the handle. The actor is not yet reachable here, so the
        // bootstrap is race-free.
        do {
            try FileManager.default.createDirectory(
                at: databasePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let handle = try Self.open(
                databasePath: databasePath, diagnosticRecorder: diagnosticRecorder)
            self.connection = SQLiteConnection(handle: handle)
            try Self.migrate(handle)
        } catch {
            Self.recordSQLiteError(
                databasePath: databasePath,
                diagnosticRecorder: diagnosticRecorder,
                name: "sqlite_open_or_migrate_failed",
                error: error
            )
            throw error
        }
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
}

// MARK: - SQLite primitives (`static`, handle-parameterized)
//
// The raw SQLite layer is a set of `static` functions of an explicit
// `OpaquePointer?` handle (and the passed statement / immutable values). They
// touch no instance state, so the synchronous actor `init` can open + migrate on
// a local handle before `self.database` is assigned, while the runtime isolated
// methods call the same functions with `self.database`. Statement reset/cache
// (the only mutable-state ops) stay isolated, in the conveniences below.
extension SQLiteYAAWStore {
    nonisolated static func recordSQLiteError(
        databasePath: URL,
        diagnosticRecorder: DiagnosticEventRecording,
        name: String,
        error: Error
    ) {
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

    nonisolated static func open(
        databasePath: URL,
        diagnosticRecorder: DiagnosticEventRecording
    ) throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open(databasePath.path, &database) == SQLITE_OK else {
            throw SQLiteStoreError.openFailed(errorMessage(database))
        }
        try execute(database, "PRAGMA journal_mode = WAL")
        try execute(database, "PRAGMA synchronous = NORMAL")
        // PRAGMA journal_mode returns the resulting mode and does NOT error when WAL is unsupported
        // (e.g. some network filesystems), so verify it actually took effect instead of silently
        // running on a rollback journal with the WAL performance assumptions unmet.
        let journalMode = (try? querySingleString(database, "PRAGMA journal_mode"))?.lowercased()
        if journalMode != "wal" {
            diagnosticRecorder.record(
                DiagnosticEvent(
                    category: "SQLite",
                    name: "sqlite_wal_not_enabled",
                    metadata: [
                        "database": databasePath.path,
                        "journal_mode": journalMode ?? "unknown",
                    ]
                )
            )
        }
        return database
    }

    nonisolated static func userVersion(_ database: OpaquePointer?) throws -> Int {
        try querySingleInt(database, "PRAGMA user_version") ?? 0
    }

    nonisolated static func transaction(_ database: OpaquePointer?, _ work: () throws -> Void)
        throws
    {
        try execute(database, "BEGIN IMMEDIATE TRANSACTION")
        do {
            try work()
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    nonisolated static func execute(_ database: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let error = message.map { String(cString: $0) } ?? errorMessage(database)
            sqlite3_free(message)
            throw SQLiteStoreError.executionFailed(error)
        }
    }

    /// Compiles a one-shot statement the caller is responsible for finalizing.
    /// Used by query helpers and migrations; hot row writes use `cachedPrepare`.
    nonisolated static func prepare(_ database: OpaquePointer?, _ sql: String) throws
        -> OpaquePointer?
    {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(errorMessage(database))
        }
        return statement
    }

    nonisolated static func querySingleInt(_ database: OpaquePointer?, _ sql: String) throws -> Int?
    {
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    nonisolated static func querySingleString(_ database: OpaquePointer?, _ sql: String) throws
        -> String?
    {
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: text)
    }

    // The interpolated table name here is NOT user input: every call site passes
    // a hardcoded literal from the migration ladder ("threads", "projects", …),
    // and SQLite does not support binding identifiers in a PRAGMA. This is the
    // single, documented exception to the no-interpolation rule.
    nonisolated static func tableColumns(_ database: OpaquePointer?, _ table: String) throws -> Set<
        String
    > {
        let statement = try prepare(database, "PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(text(at: 1, in: statement))
        }
        return columns
    }

    nonisolated static func errorMessage(_ database: OpaquePointer?) -> String {
        guard let database else { return "Missing SQLite database" }
        return String(cString: sqlite3_errmsg(database))
    }

    nonisolated static func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    nonisolated static func bindOptional(
        _ value: String?, at index: Int32, in statement: OpaquePointer?
    ) {
        if let value {
            bind(value, at: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    nonisolated static func text(at index: Int32, in statement: OpaquePointer?) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    nonisolated static func optionalText(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(at: index, in: statement)
    }

    nonisolated static func stepDone(_ database: OpaquePointer?, _ statement: OpaquePointer?) throws
    {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.executionFailed(errorMessage(database))
        }
    }

    nonisolated static func launchOptionsJSON(for thread: AgentThread) -> String? {
        let options = thread.launchOptions.validated(for: thread.agentCLI)
        guard !options.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(options) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func launchOptions(fromJSON value: String?, agentCLI: AgentCLIKind)
        -> AgentLaunchOptions
    {
        guard let value,
            let data = value.data(using: .utf8),
            let options = try? JSONDecoder().decode(AgentLaunchOptions.self, from: data)
        else {
            return AgentLaunchOptions()
        }
        return options.validated(for: agentCLI)
    }
}

// MARK: - Isolated runtime conveniences
//
// Thin wrappers the load/save/incremental paths use; they forward the isolated
// `database` handle to the `static` primitives and own the statement cache.
extension SQLiteYAAWStore {
    func recordSQLiteError(name: String, error: Error) {
        Self.recordSQLiteError(
            databasePath: databasePath, diagnosticRecorder: diagnosticRecorder, name: name,
            error: error)
    }

    func execute(_ sql: String) throws { try Self.execute(database, sql) }

    func prepare(_ sql: String) throws -> OpaquePointer? { try Self.prepare(database, sql) }

    func querySingleInt(_ sql: String) throws -> Int? { try Self.querySingleInt(database, sql) }

    func tableColumns(_ table: String) throws -> Set<String> {
        try Self.tableColumns(database, table)
    }

    func stepDone(_ statement: OpaquePointer?) throws { try Self.stepDone(database, statement) }

    var errorMessage: String { Self.errorMessage(database) }

    func transaction(_ work: () throws -> Void) throws { try Self.transaction(database, work) }

    // Pure binding/column helpers also exist as instance methods so the isolated
    // cached-statement writers can call them by bare name (the migration-side
    // statics call the static versions); both resolve to the same logic.
    func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        Self.bind(value, at: index, in: statement)
    }

    func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        Self.bindOptional(value, at: index, in: statement)
    }

    func text(at index: Int32, in statement: OpaquePointer?) -> String {
        Self.text(at: index, in: statement)
    }

    func optionalText(at index: Int32, in statement: OpaquePointer?) -> String? {
        Self.optionalText(at: index, in: statement)
    }

    func launchOptionsJSON(for thread: AgentThread) -> String? {
        Self.launchOptionsJSON(for: thread)
    }

    func launchOptions(fromJSON value: String?, agentCLI: AgentCLIKind) -> AgentLaunchOptions {
        Self.launchOptions(fromJSON: value, agentCLI: agentCLI)
    }

    /// Compiles `sql` once and reuses the statement on subsequent calls. Callers
    /// MUST `resetStatement(_:)` after stepping so the next reuse starts clean;
    /// the cache owns the statement, so callers MUST NOT `sqlite3_finalize` it.
    func cachedPrepare(_ sql: String) throws -> OpaquePointer? {
        if let cached = connection.statementCache[sql] {
            return cached
        }
        let statement = try Self.prepare(database, sql)
        connection.statementCache[sql] = statement
        return statement
    }

    /// Rewinds a cached statement to its initial state and drops its bindings so
    /// it can be re-bound and re-stepped on the next operation.
    func resetStatement(_ statement: OpaquePointer?) throws {
        guard sqlite3_reset(statement) == SQLITE_OK else {
            throw SQLiteStoreError.executionFailed(errorMessage)
        }
        sqlite3_clear_bindings(statement)
    }

    /// Runs a single-row mutation inside its own IMMEDIATE transaction. Errors
    /// are recorded as diagnostics and swallowed: these are fire-and-forget UI
    /// state writes, and the next full `save` reconciles any dropped change.
    func runIncremental(name: String, _ work: () throws -> Void) {
        do {
            try transaction(work)
        } catch {
            recordSQLiteError(name: "sqlite_\(name)_failed", error: error)
        }
    }
}

// MARK: - Test introspection

extension SQLiteYAAWStore {
    /// Number of distinct SQL strings currently held in the prepared-statement
    /// cache. Exposed so tests can assert that repeating the same operation
    /// reuses a cached statement instead of growing the cache (cache-hit proof).
    var preparedStatementCacheCount: Int { connection.statementCache.count }
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Owns a SQLite connection handle plus the prepared-statement cache compiled
/// against it. Held privately by `SQLiteYAAWStore` as actor-isolated state, so
/// all mutation is serialized by the actor. Its ordinary class `deinit` (which,
/// unlike an actor's `isolated deinit`, the optimizer handles fine) finalizes
/// every cached statement and closes the connection when the owning actor is
/// destroyed.
final class SQLiteConnection {
    let handle: OpaquePointer?
    var statementCache: [String: OpaquePointer?] = [:]

    init(handle: OpaquePointer?) {
        self.handle = handle
    }

    deinit {
        for (_, statement) in statementCache {
            sqlite3_finalize(statement)
        }
        sqlite3_close(handle)
    }
}
