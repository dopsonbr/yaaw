import XCTest

@testable import YAAWKit

/// Workspace selection / archive / pin / reorder / sorting / navigation / create
/// parity, re-pointed from `AppModelTests` onto `WorkspaceStore`.
final class WorkspaceStoreTests: XCTestCase {
    @MainActor
    private func projectArchivingHarness(
        firstProjectID: UUID, secondProjectID: UUID, globalProjectID: UUID
    ) async -> StoreHarness {
        let root = FileManager.default.temporaryDirectory
        return await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(id: firstProjectID, displayName: "First", rootDirectory: root),
                        Project(id: secondProjectID, displayName: "Second", rootDirectory: root),
                        Project(id: globalProjectID, displayName: "Global", rootDirectory: root),
                    ],
                    threads: [],
                    selectedProjectID: firstProjectID, selectedThreadID: nil,
                    selectedRightPanelMode: .files, isGlobalTerminalExpanded: false)))
    }

    @MainActor
    func testSelectionPushesGlobalNavigationHistory() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        harness.workspace.selectThread(id: fixture.secondThreadID)
        XCTAssertEqual(harness.workspace.selectedThreadID, fixture.secondThreadID)
        harness.workspace.navigateBack()
        XCTAssertEqual(harness.workspace.selectedThreadID, fixture.firstThreadID)
        harness.workspace.navigateForward()
        XCTAssertEqual(harness.workspace.selectedThreadID, fixture.secondThreadID)
    }

    @MainActor
    func testReselectingCurrentProjectPreservesSelectedThread() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        harness.workspace.selectThread(id: fixture.secondThreadID)
        harness.workspace.selectProject(id: fixture.projectID)
        XCTAssertEqual(harness.workspace.selectedThreadID, fixture.secondThreadID)
        XCTAssertEqual(harness.workspace.navigationHistory.entries.count, 2)
    }

    @MainActor
    func testArchiveRetainsThreadAndMovesSelection() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        XCTAssertFalse(harness.workspace.hasArchivedThreadsForSelectedProject)
        harness.workspace.archiveThread(id: fixture.firstThreadID)
        XCTAssertEqual(harness.workspace.selectedThreadID, fixture.secondThreadID)
        XCTAssertEqual(
            harness.workspace.threads.first { $0.id == fixture.firstThreadID }?.agentCLI, .codex)
        XCTAssertEqual(
            harness.workspace.threads.first { $0.id == fixture.firstThreadID }?.isArchived, true)
        XCTAssertTrue(harness.workspace.hasArchivedThreadsForSelectedProject)
    }

    @MainActor
    func testArchiveProjectHidesItAndMovesSelection() async {
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let harness = await projectArchivingHarness(
            firstProjectID: firstProjectID, secondProjectID: secondProjectID,
            globalProjectID: UUID())
        harness.workspace.archiveProject(id: firstProjectID)
        XCTAssertFalse(harness.workspace.activeProjects.contains { $0.id == firstProjectID })
        XCTAssertEqual(harness.workspace.archivedProjects.map(\.id), [firstProjectID])
        XCTAssertEqual(harness.workspace.selectedProjectID, secondProjectID)
    }

    @MainActor
    func testUnarchiveProjectRestoresAndSelectsIt() async {
        let firstProjectID = UUID()
        let harness = await projectArchivingHarness(
            firstProjectID: firstProjectID, secondProjectID: UUID(), globalProjectID: UUID())
        harness.workspace.archiveProject(id: firstProjectID)
        harness.workspace.unarchiveProject(id: firstProjectID)
        XCTAssertTrue(harness.workspace.activeProjects.contains { $0.id == firstProjectID })
        XCTAssertTrue(harness.workspace.archivedProjects.isEmpty)
        XCTAssertEqual(harness.workspace.selectedProjectID, firstProjectID)
    }

    @MainActor
    func testGlobalProjectCannotBeArchived() async {
        let globalProjectID = UUID()
        let harness = await projectArchivingHarness(
            firstProjectID: UUID(), secondProjectID: UUID(), globalProjectID: globalProjectID)
        XCTAssertFalse(harness.workspace.canArchiveProject(id: globalProjectID))
        harness.workspace.archiveProject(id: globalProjectID)
        XCTAssertTrue(harness.workspace.archivedProjects.isEmpty)
        XCTAssertTrue(harness.workspace.activeProjects.contains { $0.id == globalProjectID })
    }

    @MainActor
    func testThreadListsAreScopedToSelectedProject() async {
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let archivedThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let harness = await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(id: firstProjectID, displayName: "First", rootDirectory: root),
                        Project(id: secondProjectID, displayName: "Second", rootDirectory: root),
                    ],
                    threads: [
                        AgentThread(
                            id: firstThreadID, displayName: "First", projectID: firstProjectID,
                            workingDirectory: root),
                        AgentThread(
                            id: secondThreadID, displayName: "Second", projectID: secondProjectID,
                            workingDirectory: root),
                        AgentThread(
                            id: archivedThreadID, displayName: "Archived",
                            projectID: secondProjectID, workingDirectory: root, isArchived: true),
                    ],
                    selectedProjectID: secondProjectID, selectedThreadID: secondThreadID,
                    selectedRightPanelMode: .files, isGlobalTerminalExpanded: false)))

        XCTAssertEqual(
            harness.workspace.activeThreadsForSelectedProject.map(\.id), [secondThreadID])
        XCTAssertEqual(
            harness.workspace.archivedThreadsForSelectedProject.map(\.id), [archivedThreadID])
        XCTAssertEqual(harness.workspace.archivedThreads.map(\.id), [archivedThreadID])
        XCTAssertEqual(harness.workspace.projectDisplayName(for: secondProjectID), "Second")
    }

    @MainActor
    func testCreateProjectSelectsExistingDirectory() async throws {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        let root = try storeTemporaryDirectory()
        let projectID = try harness.workspace.createProject(
            displayName: "  Worktree  ", rootDirectory: root)
        XCTAssertEqual(harness.workspace.selectedProjectID, projectID)
        XCTAssertEqual(harness.workspace.selectedProject?.displayName, "Worktree")
        XCTAssertEqual(harness.workspace.selectedProject?.rootDirectory, root)
        XCTAssertNil(harness.workspace.selectedThreadID)
    }

    @MainActor
    func testCreateProjectDefaultsBlankNameToDirectoryName() async throws {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        let root = try storeTemporaryDirectory()
        let projectID = try harness.workspace.createProject(displayName: "  ", rootDirectory: root)
        XCTAssertEqual(harness.workspace.selectedProjectID, projectID)
        XCTAssertEqual(harness.workspace.selectedProject?.displayName, root.lastPathComponent)
    }

    @MainActor
    func testCreateProjectRejectsMissingDirectory() async {
        let harness = await StoreHarnessBuilder.make(store: .helloWorld())
        let missing = URL(
            fileURLWithPath: "/tmp/yaaw-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(
            try harness.workspace.createProject(displayName: "Missing", rootDirectory: missing)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceStoreError, .missingProjectDirectory(missing.path))
        }
    }

    @MainActor
    func testThreadHistorySortsPinnedThenRecentlyOpened() async {
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = FileManager.default.temporaryDirectory
        let harness = await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                    threads: [
                        AgentThread(
                            id: firstThreadID, displayName: "Older", projectID: projectID,
                            workingDirectory: root, lastOpenedAt: Date(timeIntervalSince1970: 10)),
                        AgentThread(
                            id: secondThreadID, displayName: "Newer", projectID: projectID,
                            workingDirectory: root, lastOpenedAt: Date(timeIntervalSince1970: 20)),
                    ],
                    selectedProjectID: projectID, selectedThreadID: secondThreadID,
                    selectedRightPanelMode: .files, isGlobalTerminalExpanded: false)))

        XCTAssertEqual(
            harness.workspace.activeThreads(for: projectID).map(\.id),
            [secondThreadID, firstThreadID])
        harness.workspace.selectThread(id: firstThreadID)
        XCTAssertEqual(
            harness.workspace.activeThreads(for: projectID).map(\.id),
            [firstThreadID, secondThreadID])
        harness.workspace.toggleThreadPinned(id: secondThreadID)
        XCTAssertEqual(
            harness.workspace.activeThreads(for: projectID).map(\.id),
            [secondThreadID, firstThreadID])
    }

    @MainActor
    func testArchiveAndUnarchiveMoveThreadsBetweenOrderedCaches() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        harness.workspace.archiveThread(id: fixture.firstThreadID)
        XCTAssertEqual(
            harness.workspace.activeThreads(for: fixture.projectID).map(\.id),
            [fixture.secondThreadID])
        XCTAssertEqual(
            harness.workspace.archivedThreads(for: fixture.projectID).map(\.id),
            [fixture.firstThreadID])

        harness.workspace.unarchiveThread(id: fixture.firstThreadID)
        XCTAssertEqual(
            harness.workspace.activeThreads(for: fixture.projectID).map(\.id).first,
            fixture.firstThreadID)
        XCTAssertTrue(harness.workspace.archivedThreads(for: fixture.projectID).isEmpty)
    }

    @MainActor
    func testProjectPinningAndManualReorderUsePinnedFirstGroups() async {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let root = FileManager.default.temporaryDirectory
        let harness = await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(
                            id: firstID, displayName: "First", rootDirectory: root, sortOrder: 0),
                        Project(
                            id: secondID, displayName: "Second", rootDirectory: root, sortOrder: 1),
                        Project(
                            id: thirdID, displayName: "Third", rootDirectory: root, sortOrder: 2),
                    ],
                    threads: [], selectedProjectID: firstID, selectedThreadID: nil,
                    selectedRightPanelMode: .files, isGlobalTerminalExpanded: false)))

        harness.workspace.toggleProjectPinned(id: thirdID)
        XCTAssertEqual(harness.workspace.projects.map(\.id), [thirdID, firstID, secondID])
        harness.workspace.moveProject(id: secondID, direction: .up)
        XCTAssertEqual(harness.workspace.projects.map(\.id), [thirdID, secondID, firstID])
        harness.workspace.moveProject(id: firstID, direction: .up)
        XCTAssertEqual(harness.workspace.projects.map(\.id), [thirdID, firstID, secondID])
    }

    @MainActor
    func testProjectDragReorderUsesPinnedFirstGroups() async {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let root = FileManager.default.temporaryDirectory
        let harness = await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(
                            id: firstID, displayName: "First", rootDirectory: root, sortOrder: 0),
                        Project(
                            id: secondID, displayName: "Second", rootDirectory: root, sortOrder: 1),
                        Project(
                            id: thirdID, displayName: "Third", rootDirectory: root, isPinned: true,
                            sortOrder: 0),
                    ],
                    threads: [], selectedProjectID: firstID, selectedThreadID: nil,
                    selectedRightPanelMode: .files, isGlobalTerminalExpanded: false)))

        harness.workspace.reorderProject(id: secondID, before: firstID)
        XCTAssertEqual(harness.workspace.projects.map(\.id), [thirdID, secondID, firstID])
        XCTAssertEqual(harness.workspace.projects.filter { !$0.isPinned }.map(\.sortOrder), [0, 1])
        harness.workspace.reorderProject(id: firstID, before: thirdID)
        XCTAssertEqual(harness.workspace.projects.map(\.id), [thirdID, secondID, firstID])
    }

    @MainActor
    func testGlobalProjectSortsLastAndDoesNotSelectThreadOnLoad() async throws {
        let workID = UUID()
        let workThreadID = UUID()
        let globalID = UUID()
        let globalThreadID = UUID()
        let homeRoot = try storeTemporaryDirectory()
        let workRoot = try storeTemporaryDirectory()
        let globalChatsRoot = homeRoot.appendingPathComponent("yaaw", isDirectory: true)
        let harness = await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(
                            id: globalID, displayName: "Global", rootDirectory: homeRoot,
                            isPinned: true, sortOrder: 0),
                        Project(
                            id: workID, displayName: "Work", rootDirectory: workRoot, sortOrder: 1),
                    ],
                    threads: [
                        AgentThread(
                            id: globalThreadID, displayName: "Global Thread", projectID: globalID,
                            workingDirectory: homeRoot),
                        AgentThread(
                            id: workThreadID, displayName: "Work Thread", projectID: workID,
                            workingDirectory: workRoot),
                    ],
                    selectedProjectID: globalID, selectedThreadID: globalThreadID,
                    selectedRightPanelMode: .files, isGlobalTerminalExpanded: false)),
            homeDirectory: homeRoot)

        XCTAssertEqual(harness.workspace.projects.map(\.id), [workID, globalID])
        XCTAssertEqual(harness.workspace.projects.last?.rootDirectory, globalChatsRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalChatsRoot.path))
        XCTAssertEqual(harness.workspace.selectedProjectID, globalID)
        XCTAssertNil(harness.workspace.selectedThreadID)
    }

    @MainActor
    func testImplicitThreadCreationRequiresARealProjectWhenGlobalIsSelected() async throws {
        let globalID = UUID()
        let homeRoot = try storeTemporaryDirectory()
        let harness = await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(id: globalID, displayName: "Global", rootDirectory: homeRoot)
                    ],
                    threads: [], selectedProjectID: globalID, selectedThreadID: nil,
                    selectedRightPanelMode: .files, isGlobalTerminalExpanded: false)),
            homeDirectory: homeRoot)

        XCTAssertThrowsError(try harness.workspace.createThread(agentCLI: .codex)) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .projectRequiredForThreadCreation)
        }
    }

    @MainActor
    func testCreateThreadDefaultsNameAndWorkingDirectory() async throws {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        let threadID = try harness.workspace.createThread(
            agentCLI: .claude, now: Date(timeIntervalSince1970: 123))
        let thread = try XCTUnwrap(harness.workspace.threads.first { $0.id == threadID })

        XCTAssertEqual(thread.displayName, "Starting Claude...")
        XCTAssertEqual(thread.agentCLI, .claude)
        XCTAssertEqual(thread.workingDirectory, fixture.root)
        XCTAssertEqual(harness.workspace.selectedThreadID, threadID)
        XCTAssertEqual(harness.rightPanel.selectedRightPanelMode, .files)
        XCTAssertEqual(harness.activity.threadActivity(for: threadID).status, .inactive)
    }

    @MainActor
    func testCreateThreadUsesConfiguredDefaultAgentCLIWhenChoiceIsNotExplicit() async throws {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(),
            configuration: YAAWConfiguration(agent: AgentSettings(default: .claude)))
        let threadID = try harness.workspace.createThread(agentCLI: nil)
        let thread = try XCTUnwrap(harness.workspace.threads.first { $0.id == threadID })
        XCTAssertEqual(thread.agentCLI, .claude)
        XCTAssertEqual(thread.displayName, "Starting Claude...")
    }

    @MainActor
    func testAgentCLIChoiceCannotChangeAfterCreate() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        XCTAssertThrowsError(
            try harness.workspace.changeAgentCLI(for: fixture.firstThreadID, to: .claude)
        ) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .agentCLIChangeNotAllowed)
        }
    }

    @MainActor
    func testSelectedContextProjectAndThreadCommandsUpdateCurrentSelection() async throws {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        harness.workspace.toggleSelectedProjectPinned()
        harness.workspace.toggleSelectedThreadPinned()
        harness.workspace.archiveSelectedThread()

        XCTAssertTrue(
            try XCTUnwrap(harness.workspace.projects.first { $0.id == fixture.projectID }).isPinned)
        XCTAssertTrue(
            try XCTUnwrap(harness.workspace.threads.first { $0.id == fixture.firstThreadID })
                .isPinned)
        XCTAssertTrue(
            try XCTUnwrap(harness.workspace.threads.first { $0.id == fixture.firstThreadID })
                .isArchived)
        XCTAssertEqual(harness.workspace.selectedThreadID, fixture.secondThreadID)
    }
}
