import XCTest
@testable import AgentIDEKit

final class AppModelTests: XCTestCase {
    func testGlobalTerminalStartsCollapsed() {
        let model = AppModel()

        XCTAssertFalse(model.isGlobalTerminalExpanded)
    }

    func testToggleGlobalTerminalChangesVisibleState() {
        let model = AppModel()

        model.toggleGlobalTerminal()

        XCTAssertTrue(model.isGlobalTerminalExpanded)
    }

    func testRightPanelModeSelectionIsPublicBehavior() {
        let model = AppModel()

        model.selectRightPanelMode(.git)

        XCTAssertEqual(model.selectedRightPanelMode, .git)
    }

    func testSelectionPushesGlobalNavigationHistory() {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.selectThread(id: fixture.secondThreadID)
        XCTAssertEqual(model.selectedThreadID, fixture.secondThreadID)

        model.navigateBack()
        XCTAssertEqual(model.selectedThreadID, fixture.firstThreadID)

        model.navigateForward()
        XCTAssertEqual(model.selectedThreadID, fixture.secondThreadID)
    }

    func testRightPanelModeIsScopedToSelectedThread() {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.selectRightPanelMode(.git)
        model.selectThread(id: fixture.secondThreadID)

        XCTAssertEqual(model.selectedRightPanelMode, .files)

        model.selectThread(id: fixture.firstThreadID)

        XCTAssertEqual(model.selectedRightPanelMode, .git)
    }

    func testArchiveRetainsThreadAndMovesSelection() {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.archiveThread(id: fixture.firstThreadID)

        XCTAssertEqual(model.selectedThreadID, fixture.secondThreadID)
        XCTAssertEqual(model.threads.first { $0.id == fixture.firstThreadID }?.agentCLI, .codex)
        XCTAssertEqual(model.threads.first { $0.id == fixture.firstThreadID }?.isArchived, true)
    }

    func testSnapshotSelectedModeSeedsSelectedThreadMode() {
        let fixture = AppModelFixture()
        let model = AppModel(
            store: InMemoryAgentIDEStore(
                snapshot: AgentIDESnapshot(
                    projects: [Project(id: fixture.projectID, displayName: "Project", rootDirectory: fixture.root)],
                    threads: [
                        AgentThread(
                            id: fixture.firstThreadID,
                            displayName: "First",
                            projectID: fixture.projectID,
                            workingDirectory: fixture.root,
                            agentCLI: .codex
                        )
                    ],
                    selectedProjectID: fixture.projectID,
                    selectedThreadID: fixture.firstThreadID,
                    rightPanelModesByThreadID: [:],
                    selectedRightPanelMode: .git,
                    isGlobalTerminalExpanded: false
                )
            )
        )

        XCTAssertEqual(model.selectedRightPanelMode, .git)
    }

    func testThreadListsAreScopedToSelectedProject() {
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let archivedThreadID = UUID()
        let root = URL(fileURLWithPath: "/tmp/agent-ide", isDirectory: true)
        let model = AppModel(
            store: InMemoryAgentIDEStore(
                snapshot: AgentIDESnapshot(
                    projects: [
                        Project(id: firstProjectID, displayName: "First", rootDirectory: root),
                        Project(id: secondProjectID, displayName: "Second", rootDirectory: root)
                    ],
                    threads: [
                        AgentThread(id: firstThreadID, displayName: "First", projectID: firstProjectID, workingDirectory: root),
                        AgentThread(id: secondThreadID, displayName: "Second", projectID: secondProjectID, workingDirectory: root),
                        AgentThread(
                            id: archivedThreadID,
                            displayName: "Archived",
                            projectID: secondProjectID,
                            workingDirectory: root,
                            isArchived: true
                        )
                    ],
                    selectedProjectID: secondProjectID,
                    selectedThreadID: secondThreadID,
                    selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false
                )
            )
        )

        XCTAssertEqual(model.activeThreadsForSelectedProject.map(\.id), [secondThreadID])
        XCTAssertEqual(model.archivedThreadsForSelectedProject.map(\.id), [archivedThreadID])
    }

    func testReselectingCurrentProjectPreservesSelectedThread() {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.selectThread(id: fixture.secondThreadID)
        model.selectProject(id: fixture.projectID)

        XCTAssertEqual(model.selectedThreadID, fixture.secondThreadID)
        XCTAssertEqual(model.navigationHistory.entries.count, 2)
    }

    func testCreateProjectSelectsExistingDirectory() throws {
        let model = AppModel()
        let root = try temporaryDirectory()

        let projectID = try model.createProject(displayName: "  Worktree  ", rootDirectory: root)

        XCTAssertEqual(model.selectedProjectID, projectID)
        XCTAssertEqual(model.selectedProject?.displayName, "Worktree")
        XCTAssertEqual(model.selectedProject?.rootDirectory, root)
        XCTAssertNil(model.selectedThreadID)
    }

    func testCreateProjectRejectsMissingDirectory() {
        let model = AppModel()
        let missing = URL(fileURLWithPath: "/tmp/agent-ide-missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try model.createProject(displayName: "Missing", rootDirectory: missing)) { error in
            XCTAssertEqual(error as? AppModelError, .missingProjectDirectory(missing.path))
        }
    }

    func testCreateThreadRequiresExplicitAgentCLIChoice() {
        let model = AppModel()

        XCTAssertThrowsError(try model.createThread(agentCLI: nil)) { error in
            XCTAssertEqual(error as? AppModelError, .missingAgentCLI)
        }
    }

    func testCreateThreadDefaultsNameAndWorkingDirectory() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        let threadID = try model.createThread(agentCLI: .claude, now: Date(timeIntervalSince1970: 123))
        let thread = try XCTUnwrap(model.threads.first { $0.id == threadID })

        XCTAssertEqual(thread.displayName, "New claude thread")
        XCTAssertEqual(thread.agentCLI, .claude)
        XCTAssertEqual(thread.workingDirectory, fixture.root)
        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(model.selectedRightPanelMode, .files)
    }

    func testAgentCLIChoiceCannotChangeAfterCreate() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        XCTAssertThrowsError(try model.changeAgentCLI(for: fixture.firstThreadID, to: .claude)) { error in
            XCTAssertEqual(error as? AppModelError, .agentCLIChangeNotAllowed)
        }
    }

    func testArchiveKeepsClaudeThreadMetadata() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.archiveThread(id: fixture.secondThreadID)

        let archivedThread = try XCTUnwrap(model.archivedThreadsForSelectedProject.first { $0.id == fixture.secondThreadID })
        XCTAssertEqual(archivedThread.agentCLI, .claude)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentIDEKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct AppModelFixture {
    let projectID = UUID()
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let root = FileManager.default.temporaryDirectory

    var store: InMemoryAgentIDEStore {
        InMemoryAgentIDEStore(
            snapshot: AgentIDESnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: firstThreadID,
                        displayName: "First",
                        projectID: projectID,
                        workingDirectory: root,
                        agentCLI: .codex
                    ),
                    AgentThread(
                        id: secondThreadID,
                        displayName: "Second",
                        projectID: projectID,
                        workingDirectory: root,
                        agentCLI: .claude
                    )
                ],
                selectedProjectID: projectID,
                selectedThreadID: firstThreadID,
                rightPanelModesByThreadID: [firstThreadID: .files, secondThreadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
    }
}
