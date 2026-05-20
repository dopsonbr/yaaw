import XCTest
import SQLite3
@testable import AgentIDEKit

final class PersistenceTests: XCTestCase {
    func testSQLiteMigrationInitializesVersionOneSchema() throws {
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
        XCTAssertEqual(reloaded.selectedProjectID, projectID)
        XCTAssertEqual(reloaded.selectedThreadID, secondThreadID)
        XCTAssertEqual(reloaded.rightPanelModesByThreadID[firstThreadID], .git)
        XCTAssertEqual(reloaded.rightPanelModesByThreadID[secondThreadID], .nvim)
        XCTAssertTrue(reloaded.isGlobalTerminalExpanded)
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
