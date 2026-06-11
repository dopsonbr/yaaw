import XCTest

@testable import YAAWKit

/// Schema v18: the per-thread file-browser UI state (expanded folders, selected
/// file, nvim path) is now persisted, fixing the pre-rewrite unpersisted-dictionary
/// asymmetry. Round-trips through both the SQLite store and the live stores.
final class RightPanelUIStatePersistenceTests: XCTestCase {
    @MainActor
    func testRightPanelUIStateRoundTripsThroughSQLite() async throws {
        let directory = try storeTemporaryDirectory()
        let databasePath = directory.appendingPathComponent("state.sqlite")
        let threadID = UUID()
        let projectID = UUID()
        let root = directory

        let store = try SQLiteYAAWStore(databasePath: databasePath)
        await store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID, displayName: "Thread", projectID: projectID,
                        workingDirectory: root)
                ],
                selectedProjectID: projectID, selectedThreadID: threadID,
                selectedRightPanelMode: .files, isGlobalTerminalExpanded: false))

        var state = RightPanelState.defaultState(selectedMode: .nvim)
        state.expandedFolders = ["src", "src/App", "docs/plans"]
        state.selectedFilePath = "src/App/RootView.swift"
        state.nvimPath = "src/App/RootView.swift"
        await store.setRightPanelState(threadID: threadID, state: state)

        let reloaded = try await SQLiteYAAWStore(databasePath: databasePath).load()
        let restored = try XCTUnwrap(reloaded.rightPanelStatesByThreadID[threadID])
        XCTAssertEqual(restored.expandedFolders, ["src", "src/App", "docs/plans"])
        XCTAssertEqual(restored.selectedFilePath, "src/App/RootView.swift")
        XCTAssertEqual(restored.nvimPath, "src/App/RootView.swift")
        XCTAssertEqual(restored.selectedMode, .nvim)
    }

    @MainActor
    func testStoresPersistAndRestorePerThreadUIStateAcrossReload() async throws {
        let directory = try storeTemporaryDirectory()
        let databasePath = directory.appendingPathComponent("state.sqlite")
        let projectID = UUID()
        let threadID = UUID()
        let root = directory
        try "readme\n".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let snapshot = YAAWSnapshot(
            projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
            threads: [
                AgentThread(
                    id: threadID, displayName: "Thread", projectID: projectID,
                    workingDirectory: root)
            ],
            selectedProjectID: projectID, selectedThreadID: threadID,
            rightPanelModesByThreadID: [threadID: .files], selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false)

        // First session: open a file in nvim, expand folders, select a file.
        let firstStore = try SQLiteYAAWStore(databasePath: databasePath)
        await firstStore.save(snapshot)
        let firstEnvironment = AppEnvironment(
            persistenceStore: firstStore,
            fileIndexActor: FileIndexActor(
                store: firstStore, fileIndexer: ImmediateTestFileIndexer()),
            externalToolResolver: StaticExecutableResolver(paths: ["nvim": "/tools/nvim"]),
            environment: [:],
            requiresSessionLinkForLoadedUnboundThreads: false)
        let firstStores = await AppStores.make(environment: firstEnvironment)
        firstStores.rightPanel.openFileInNvim(relativePath: "README.md")
        firstStores.rightPanel.setExpandedFolders(["src", "docs"], forThreadID: threadID)
        await firstStores.rightPanel.flushPersistence()

        // Second session: reload from the same database.
        let secondStore = try SQLiteYAAWStore(databasePath: databasePath)
        let secondEnvironment = AppEnvironment(
            persistenceStore: secondStore,
            fileIndexActor: FileIndexActor(
                store: secondStore, fileIndexer: ImmediateTestFileIndexer()),
            externalToolResolver: StaticExecutableResolver(paths: ["nvim": "/tools/nvim"]),
            environment: [:],
            requiresSessionLinkForLoadedUnboundThreads: false)
        let secondStores = await AppStores.make(environment: secondEnvironment)

        XCTAssertEqual(
            secondStores.rightPanel.expandedFolders(forThreadID: threadID), ["src", "docs"])
        XCTAssertEqual(secondStores.rightPanel.nvimPath(forThreadID: threadID), "README.md")
        XCTAssertEqual(secondStores.rightPanel.selectedFileRelativePath, "README.md")
    }

    func testSchemaVersionIsEighteen() {
        XCTAssertEqual(SQLiteYAAWStore.schemaVersion, 18)
    }
}
