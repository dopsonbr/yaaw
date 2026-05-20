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
}

private struct AppModelFixture {
    let projectID = UUID()
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let root = URL(fileURLWithPath: "/tmp/agent-ide", isDirectory: true)

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
