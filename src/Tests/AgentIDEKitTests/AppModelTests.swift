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

    func testPanelCollapseActionsUpdateLayoutState() {
        let model = AppModel()

        model.toggleSidebarCollapsed()
        model.toggleRightPanelCollapsed()

        XCTAssertTrue(model.layoutState.isSidebarCollapsed)
        XCTAssertTrue(model.layoutState.isRightPanelCollapsed)
    }

    func testPanelResizeActionsClampLayoutState() {
        let model = AppModel()

        model.setSidebarWidth(10)
        model.setRightPanelWidth(10)
        model.setGlobalTerminalHeight(1_000)

        XCTAssertEqual(model.layoutState.sidebarWidth, LayoutState.minimumSidebarWidth)
        XCTAssertEqual(model.layoutState.rightPanelWidth, LayoutState.minimumRightPanelWidth)
        XCTAssertEqual(model.layoutState.globalTerminalHeight, LayoutState.maximumGlobalTerminalHeight)
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

        XCTAssertFalse(model.hasArchivedThreadsForSelectedProject)

        model.archiveThread(id: fixture.firstThreadID)

        XCTAssertEqual(model.selectedThreadID, fixture.secondThreadID)
        XCTAssertEqual(model.threads.first { $0.id == fixture.firstThreadID }?.agentCLI, .codex)
        XCTAssertEqual(model.threads.first { $0.id == fixture.firstThreadID }?.isArchived, true)
        XCTAssertTrue(model.hasArchivedThreadsForSelectedProject)
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

    func testProjectTerminalSessionIsScopedToSelectedActiveThread() throws {
        let fixture = AppModelFixture()
        let manager = PlaceholderTerminalSessionManager()
        let service = AgentCLISessionBindingService(
            resolver: StaticAppModelExecutableResolver(
                paths: [
                    "codex": "/tmp/bin/codex",
                    "claude": "/tmp/bin/claude"
                ]
            ),
            captureDirectory: nil
        )
        let model = AppModel(store: fixture.store, terminalManager: manager, agentCLIBindings: service)

        let firstActivation = try XCTUnwrap(model.activateSelectedProjectTerminal())
        let secondActivation = try XCTUnwrap(model.activateSelectedProjectTerminal())

        XCTAssertEqual(firstActivation.id, secondActivation.id)
        XCTAssertEqual(firstActivation.request.role, .project(threadID: fixture.firstThreadID))

        model.selectThread(id: fixture.secondThreadID)
        let thirdActivation = try XCTUnwrap(model.activateSelectedProjectTerminal())

        XCTAssertNotEqual(firstActivation.id, thirdActivation.id)
        XCTAssertEqual(thirdActivation.request.role, .project(threadID: fixture.secondThreadID))
        XCTAssertEqual(firstActivation.request.command, ["/tmp/bin/codex"])
        XCTAssertEqual(thirdActivation.request.command, ["/tmp/bin/claude"])
        XCTAssertEqual(manager.lifecycleEvents.count, 5)
    }

    func testAgentCLIMetadataDoesNotRebuildActiveProjectTerminalCommand() throws {
        let fixture = AppModelFixture()
        let service = AgentCLISessionBindingService(
            resolver: StaticAppModelExecutableResolver(paths: ["codex": "/tmp/bin/codex"]),
            captureDirectory: nil
        )
        let model = AppModel(store: fixture.store, agentCLIBindings: service)

        let initial = try XCTUnwrap(model.terminalLaunchRequest(for: .project(threadID: fixture.firstThreadID)))
        model.recordAgentCLIOutput(
            threadID: fixture.firstThreadID,
            output: """
            session id: codex-session-789
            session name: Captured Session
            """
        )
        let active = try XCTUnwrap(model.terminalLaunchRequest(for: .project(threadID: fixture.firstThreadID)))

        XCTAssertEqual(initial.command, ["/tmp/bin/codex"])
        XCTAssertEqual(active.command, initial.command)
        XCTAssertEqual(model.selectedThread?.sessionIdentity, "codex-session-789")
    }

    func testTransientTerminalTitleDoesNotOverwriteCapturedCanonicalName() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.recordAgentCLIOutput(
            threadID: fixture.firstThreadID,
            output: """
            session id: codex-session-789
            session name: Captured Session
            """
        )
        model.recordAgentCLITerminalTitle(threadID: fixture.firstThreadID, title: "~/project")

        XCTAssertEqual(model.selectedThread?.canonicalSessionName, "Captured Session")
        XCTAssertEqual(model.selectedThread?.displayName, "Captured Session")
    }

    func testEarlyTerminalTitleBecomesFallbackWhenOutputOnlyReportsIdentity() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.recordAgentCLITerminalTitle(threadID: fixture.firstThreadID, title: "CLI Title")
        model.recordAgentCLIOutput(threadID: fixture.firstThreadID, output: "session id: codex-session-789")

        XCTAssertEqual(model.selectedThread?.sessionIdentity, "codex-session-789")
        XCTAssertEqual(model.selectedThread?.canonicalSessionName, "CLI Title")
        XCTAssertEqual(model.selectedThread?.displayName, "CLI Title")
    }

    func testProjectTerminalRelaunchResetsCaptureOffset() throws {
        let fixture = AppModelFixture()
        let captureDirectory = try temporaryDirectory()
        let service = AgentCLISessionBindingService(captureDirectory: captureDirectory)
        let model = AppModel(store: fixture.store, agentCLIBindings: service)
        let thread = try XCTUnwrap(model.selectedThread)
        let captureLogURL = try XCTUnwrap(service.captureLogURL(for: thread))
        try "session id: first-session\n".write(to: captureLogURL, atomically: true, encoding: .utf8)
        model.pollSelectedAgentCLICaptureLog()

        model.terminateTerminal(role: .project(threadID: fixture.firstThreadID))
        try "session id: second-session\n".write(to: captureLogURL, atomically: true, encoding: .utf8)
        model.pollSelectedAgentCLICaptureLog()

        XCTAssertEqual(model.selectedThread?.sessionIdentity, "second-session")
    }

    func testGlobalTerminalSessionIsSharedAppWide() throws {
        let fixture = AppModelFixture()
        let homeDirectory = URL(fileURLWithPath: "/tmp/agent-ide-home", isDirectory: true)
        let model = AppModel(store: fixture.store, homeDirectory: homeDirectory)

        let firstActivation = try XCTUnwrap(model.activateGlobalTerminal())
        model.selectThread(id: fixture.secondThreadID)
        let secondActivation = try XCTUnwrap(model.activateGlobalTerminal())

        XCTAssertEqual(firstActivation.id, secondActivation.id)
        XCTAssertEqual(firstActivation.request.role, .global)
        XCTAssertEqual(firstActivation.request.workingDirectory, homeDirectory)
    }

    func testRightPanelTerminalRequestsUseSelectedThreadWorkingDirectory() throws {
        let fixture = AppModelFixture()
        let resolver = StaticAppModelExecutableResolver(
            paths: [
                "nvim": "/opt/homebrew/bin/nvim",
                "lazygit": "/opt/homebrew/bin/lazygit"
            ]
        )
        let model = AppModel(store: fixture.store, externalToolResolver: resolver, environment: [:])

        model.selectRightPanelMode(.nvim)
        let nvimSession = try XCTUnwrap(model.activateSelectedRightPanelTerminal())
        XCTAssertEqual(nvimSession.request.role, .nvim(threadID: fixture.firstThreadID))
        XCTAssertEqual(nvimSession.request.workingDirectory, fixture.root)
        XCTAssertEqual(nvimSession.request.command, ["/opt/homebrew/bin/nvim"])

        model.selectRightPanelMode(.git)
        let gitSession = try XCTUnwrap(model.activateSelectedRightPanelTerminal())
        XCTAssertEqual(gitSession.request.role, .lazygit(threadID: fixture.firstThreadID))
        XCTAssertEqual(gitSession.request.workingDirectory, fixture.root)
        XCTAssertEqual(gitSession.request.command, ["/opt/homebrew/bin/lazygit"])
    }

    func testOpeningFileSwitchesToNvimAndUsesRelativePath() throws {
        let fixture = AppModelFixture()
        let resolver = StaticAppModelExecutableResolver(paths: ["nvim": "/tools/nvim"])
        let model = AppModel(store: fixture.store, externalToolResolver: resolver, environment: [:])

        model.openFileInNvim(relativePath: "src/App/RootView.swift")

        let request = try XCTUnwrap(model.terminalLaunchRequest(for: .nvim(threadID: fixture.firstThreadID)))
        XCTAssertEqual(model.selectedRightPanelMode, .nvim)
        XCTAssertEqual(request.workingDirectory, fixture.root)
        XCTAssertEqual(request.command, ["/tools/nvim", "src/App/RootView.swift"])
    }

    func testMissingRightPanelToolFallsBackToRawCommandName() throws {
        let fixture = AppModelFixture()
        let model = AppModel(
            store: fixture.store,
            externalToolResolver: StaticAppModelExecutableResolver(paths: [:]),
            environment: [:]
        )

        model.openFileInNvim(relativePath: "README.md")
        let nvimRequest = try XCTUnwrap(model.terminalLaunchRequest(for: .nvim(threadID: fixture.firstThreadID)))
        model.selectRightPanelMode(.git)
        let gitRequest = try XCTUnwrap(model.terminalLaunchRequest(for: .lazygit(threadID: fixture.firstThreadID)))

        XCTAssertEqual(nvimRequest.command, ["nvim", "README.md"])
        XCTAssertEqual(gitRequest.command, ["lazygit"])
    }

    func testOpeningDifferentFilesReplacesNvimTerminalSessionRequest() throws {
        let fixture = AppModelFixture()
        let manager = PlaceholderTerminalSessionManager()
        let resolver = StaticAppModelExecutableResolver(paths: ["nvim": "/tools/nvim"])
        let model = AppModel(store: fixture.store, terminalManager: manager, externalToolResolver: resolver, environment: [:])

        model.openFileInNvim(relativePath: "README.md")
        let firstSession = try XCTUnwrap(model.activateSelectedRightPanelTerminal())
        model.selectRightPanelMode(.files)
        model.openFileInNvim(relativePath: "src/App/RootView.swift")
        let secondSession = try XCTUnwrap(model.activateSelectedRightPanelTerminal())

        XCTAssertNotEqual(firstSession.id, secondSession.id)
        XCTAssertEqual(firstSession.request.command, ["/tools/nvim", "README.md"])
        XCTAssertEqual(secondSession.request.command, ["/tools/nvim", "src/App/RootView.swift"])
    }

    func testOpeningSameFileReplacesNvimTerminalSessionRequest() throws {
        let fixture = AppModelFixture()
        let manager = PlaceholderTerminalSessionManager()
        let resolver = StaticAppModelExecutableResolver(paths: ["nvim": "/tools/nvim"])
        let model = AppModel(store: fixture.store, terminalManager: manager, externalToolResolver: resolver, environment: [:])

        model.openFileInNvim(relativePath: "README.md")
        let firstSession = try XCTUnwrap(model.activateSelectedRightPanelTerminal())
        model.selectRightPanelMode(.files)
        model.openFileInNvim(relativePath: "README.md")
        let secondSession = try XCTUnwrap(model.activateSelectedRightPanelTerminal())

        XCTAssertNotEqual(firstSession.id, secondSession.id)
        XCTAssertNotEqual(firstSession.request, secondSession.request)
        XCTAssertEqual(firstSession.request.command, ["/tools/nvim", "README.md"])
        XCTAssertEqual(secondSession.request.command, ["/tools/nvim", "README.md"])
    }

    func testReplacingActiveTerminalSessionRecordsTerminatedState() throws {
        let manager = PlaceholderTerminalSessionManager()
        let workingDirectory = try temporaryDirectory()
        let firstRequest = TerminalLaunchRequest(
            role: .nvim(threadID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            title: "nvim",
            workingDirectory: workingDirectory,
            command: ["/tools/nvim", "README.md"]
        )
        let secondRequest = TerminalLaunchRequest(
            role: firstRequest.role,
            title: "nvim",
            workingDirectory: workingDirectory,
            command: ["/tools/nvim", "Package.swift"]
        )

        let firstSession = manager.activate(firstRequest)
        _ = manager.activate(secondRequest)

        let terminatedEvent = manager.lifecycleEvents.compactMap { event -> TerminalSessionRecord? in
            if case .terminated(let record) = event {
                return record
            }
            return nil
        }.last
        let terminatedRecord = try XCTUnwrap(terminatedEvent)
        XCTAssertEqual(terminatedRecord.id, firstSession.id)
        XCTAssertEqual(terminatedRecord.state, .terminated)
    }

    func testTerminalRuntimeStateIsNotPersisted() throws {
        let fixture = AppModelFixture()
        let store = fixture.store
        let model = AppModel(store: store)

        let session = try XCTUnwrap(model.activateSelectedProjectTerminal())
        XCTAssertEqual(model.terminalSession(for: .project(threadID: fixture.firstThreadID))?.id, session.id)

        let reloadedModel = AppModel(store: store)

        XCTAssertNil(reloadedModel.terminalSession(for: .project(threadID: fixture.firstThreadID)))
        XCTAssertTrue(reloadedModel.terminalLifecycleEvents.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentIDEKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct StaticAppModelExecutableResolver: AgentCLIExecutableResolving {
    let paths: [String: String]

    func executablePath(named executableName: String, environment: [String: String]) -> String? {
        paths[executableName]
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
