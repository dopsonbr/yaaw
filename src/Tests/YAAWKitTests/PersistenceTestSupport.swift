import SQLite3
import Synchronization
import XCTest

@testable import YAAWKit

let persistenceTestsSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Shared base for the SQLite persistence test suites: provides a scratch
// directory plus the raw-SQLite probes the tests use to seed legacy schema
// versions and read back PRAGMAs/columns directly (bypassing the store).
class PersistenceTestCase: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func sqliteUserVersion(path: URL) throws -> Int {
        try withSQLiteDatabase(path: path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    func sqliteStringPragma(path: URL, name: String) throws -> String {
        try withSQLiteDatabase(path: path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return String(cString: sqlite3_column_text(statement, 0))
        }
    }

    func sqliteTableColumns(path: URL, table: String) throws -> Set<String> {
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

    func sqliteSidebarProjectExpanded(path: URL, projectID: UUID) throws -> Bool? {
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
            sqlite3_bind_text(
                statement, 1, projectID.uuidString, -1, persistenceTestsSQLiteTransient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    func withSQLiteDatabase<T>(path: URL, _ work: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        return try work(database)
    }

    func executeSQL(_ sql: String, database: OpaquePointer?) throws {
        var message: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        XCTAssertEqual(result, SQLITE_OK, message.map { String(cString: $0) } ?? "SQLite error")
    }
}

final class RecordingDiagnosticEventRecorder: DiagnosticEventRecording {
    private let storage = Mutex<[DiagnosticEvent]>([])

    var events: [DiagnosticEvent] { storage.withLock { $0 } }

    func record(_ event: DiagnosticEvent) {
        storage.withLock { $0.append(event) }
    }
}
