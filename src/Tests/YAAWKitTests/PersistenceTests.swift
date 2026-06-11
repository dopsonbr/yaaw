import XCTest

@testable import YAAWKit

final class PersistenceTests: PersistenceTestCase {
    func testSQLiteStorePersistsPlanOneSnapshot() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let createdAt = Date(timeIntervalSince1970: 42)
        let snapshot = YAAWSnapshot(
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
                    launchOptions: AgentLaunchOptions(
                        executableName: "claude-dev",
                        permissionModeID: "claude-plan",
                        additionalArguments: ["--model", "sonnet"]
                    ),
                    createdAt: createdAt,
                    lastOpenedAt: createdAt
                ),
            ],
            selectedProjectID: projectID,
            selectedThreadID: secondThreadID,
            rightPanelModesByThreadID: [firstThreadID: .git, secondThreadID: .nvim],
            selectedRightPanelMode: .nvim,
            isGlobalTerminalExpanded: true
        )

        await store.save(snapshot)
        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.projects, snapshot.projects)
        XCTAssertEqual(reloaded.threads.map(\.id), snapshot.threads.map(\.id))
        XCTAssertEqual(reloaded.threads.map(\.isArchived), [true, false])
        XCTAssertEqual(reloaded.threads.map(\.agentCLI), [.codex, .claude])
        XCTAssertEqual(reloaded.threads[0].launchOptions, AgentLaunchOptions())
        XCTAssertEqual(
            reloaded.threads[1].launchOptions,
            AgentLaunchOptions(
                executableName: "claude-dev",
                permissionModeID: "claude-plan",
                additionalArguments: ["--model", "sonnet"]
            )
        )
        XCTAssertEqual(reloaded.threads.map(\.sessionIdentity), [nil, nil])
        XCTAssertEqual(reloaded.threads.map(\.pendingSessionRename), [nil, nil])
        XCTAssertEqual(reloaded.selectedProjectID, projectID)
        XCTAssertEqual(reloaded.selectedThreadID, secondThreadID)
        XCTAssertEqual(reloaded.rightPanelModesByThreadID[firstThreadID], .git)
        XCTAssertEqual(reloaded.rightPanelModesByThreadID[secondThreadID], .nvim)
        XCTAssertEqual(
            reloaded.rightPanelStatesByThreadID[firstThreadID]?.selectedTabID, RightPanelTab.gitID)
        XCTAssertEqual(
            reloaded.rightPanelStatesByThreadID[secondThreadID]?.selectedTabID,
            RightPanelTab.defaultNvimID)
        XCTAssertTrue(reloaded.isGlobalTerminalExpanded)
    }

    func testSQLiteStorePersistsSelectionChangeInBatch() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let createdAt = Date(timeIntervalSince1970: 42)
        let oldOpenedAt = Date(timeIntervalSince1970: 100)
        let newOpenedAt = Date(timeIntervalSince1970: 200)
        let firstProject = Project(
            id: firstProjectID,
            displayName: "First Project",
            rootDirectory: root,
            createdAt: createdAt,
            lastOpenedAt: oldOpenedAt
        )
        var secondProject = Project(
            id: secondProjectID,
            displayName: "Second Project",
            rootDirectory: root,
            createdAt: createdAt,
            lastOpenedAt: oldOpenedAt
        )
        let firstThread = AgentThread(
            id: firstThreadID,
            displayName: "First",
            projectID: firstProjectID,
            workingDirectory: root,
            createdAt: createdAt,
            lastOpenedAt: oldOpenedAt
        )
        var secondThread = AgentThread(
            id: secondThreadID,
            displayName: "Second",
            projectID: secondProjectID,
            workingDirectory: root,
            createdAt: createdAt,
            lastOpenedAt: oldOpenedAt
        )
        await store.save(
            YAAWSnapshot(
                projects: [firstProject, secondProject],
                threads: [firstThread, secondThread],
                selectedProjectID: firstProjectID,
                selectedThreadID: firstThreadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        secondProject.lastOpenedAt = newOpenedAt
        secondThread.lastOpenedAt = newOpenedAt

        await store.persistSelectionChange(
            selectedProjectID: secondProjectID,
            selectedThreadID: secondThreadID,
            touchedProject: secondProject,
            touchedThread: secondThread,
            expandedProjectID: secondProjectID
        )

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()
        XCTAssertEqual(reloaded.selectedProjectID, secondProjectID)
        XCTAssertEqual(reloaded.selectedThreadID, secondThreadID)
        XCTAssertEqual(
            reloaded.projects.first { $0.id == secondProjectID }?.lastOpenedAt,
            newOpenedAt
        )
        XCTAssertEqual(
            reloaded.threads.first { $0.id == secondThreadID }?.lastOpenedAt,
            newOpenedAt
        )
        XCTAssertTrue(reloaded.expandedProjectIDs.contains(secondProjectID))
    }

    func testPersistSelectionChangeMatchesAcrossStores() async throws {
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let firstProject = Project(
            id: firstProjectID, displayName: "First Project", rootDirectory: root)
        var secondProject = Project(
            id: secondProjectID, displayName: "Second Project", rootDirectory: root)
        let firstThread = AgentThread(
            id: firstThreadID, displayName: "First", projectID: firstProjectID,
            workingDirectory: root)
        var secondThread = AgentThread(
            id: secondThreadID, displayName: "Second", projectID: secondProjectID,
            workingDirectory: root)
        secondProject.lastOpenedAt = Date(timeIntervalSince1970: 200)
        secondThread.lastOpenedAt = Date(timeIntervalSince1970: 200)

        func seededSnapshot() -> YAAWSnapshot {
            YAAWSnapshot(
                projects: [firstProject, secondProject],
                threads: [firstThread, secondThread],
                selectedProjectID: firstProjectID,
                selectedThreadID: firstThreadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        }

        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let sqliteStore = try SQLiteYAAWStore(databasePath: path)
        await sqliteStore.save(seededSnapshot())
        let inMemoryStore = InMemoryYAAWStore(snapshot: seededSnapshot())

        for store in [sqliteStore as YAAWStore, inMemoryStore as YAAWStore] {
            await store.persistSelectionChange(
                selectedProjectID: secondProjectID,
                selectedThreadID: secondThreadID,
                touchedProject: secondProject,
                touchedThread: secondThread,
                expandedProjectID: secondProjectID
            )
        }

        let fromSQLite = try await SQLiteYAAWStore(databasePath: path).load()
        let fromMemory = await inMemoryStore.load()
        XCTAssertEqual(fromSQLite.selectedProjectID, fromMemory.selectedProjectID)
        XCTAssertEqual(fromSQLite.selectedThreadID, fromMemory.selectedThreadID)
        XCTAssertEqual(fromSQLite.selectedProjectID, secondProjectID)
        XCTAssertEqual(fromSQLite.selectedThreadID, secondThreadID)
        XCTAssertEqual(
            fromSQLite.expandedProjectIDs.contains(secondProjectID),
            fromMemory.expandedProjectIDs.contains(secondProjectID)
        )
        XCTAssertTrue(fromSQLite.expandedProjectIDs.contains(secondProjectID))
    }

    func testSQLitePersistsPendingThreadRename() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)

        await store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID,
                        displayName: "Thread",
                        projectID: projectID,
                        workingDirectory: root,
                        agentCLI: .codex,
                        sessionIdentity: "codex-1",
                        canonicalSessionName: "Thread",
                        pendingSessionRename: "Renamed Thread"
                    )
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.threads.first?.pendingSessionRename, "Renamed Thread")
        XCTAssertEqual(reloaded.threads.first?.sessionIdentity, "codex-1")
    }

    func testSQLiteAcceptsAllSupportedAgentCLIKinds() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let threads = AgentCLIKind.allCases.map { kind in
            AgentThread(
                displayName: kind.displayName,
                projectID: projectID,
                workingDirectory: root,
                agentCLI: kind
            )
        }

        await store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: threads,
                selectedProjectID: projectID,
                selectedThreadID: threads.first?.id,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(Set(reloaded.threads.map(\.agentCLI)), Set(AgentCLIKind.allCases))
    }

    func testSQLiteTransactionRejectsPartialInvalidThreadWrite() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let invalidThread = AgentThread(
            displayName: "Invalid",
            projectID: UUID(),
            workingDirectory: URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        )
        let snapshot = YAAWSnapshot(
            projects: [
                Project(
                    id: projectID, displayName: "Project",
                    rootDirectory: invalidThread.workingDirectory)
            ],
            threads: [invalidThread],
            selectedProjectID: projectID,
            selectedThreadID: invalidThread.id,
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false
        )

        await store.save(snapshot)
        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertNotEqual(reloaded.projects.map(\.id), [projectID])
        XCTAssertFalse(reloaded.threads.contains { $0.id == invalidThread.id })
    }

    func testSQLiteLoadFallsBackWhenPersistedUUIDIsInvalid() async throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        _ = try SQLiteYAAWStore(databasePath: path)
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

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()

        XCTAssertEqual(reloaded.projects.first?.displayName, "Global")
        XCTAssertEqual(reloaded.threads.first?.displayName, "Hello World")
    }
}
