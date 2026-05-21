import XCTest
@testable import YAAWKit

final class AppModelTests: XCTestCase {
    func testBottomTerminalStartsCollapsed() {
        let model = AppModel()

        XCTAssertFalse(model.isBottomTerminalExpanded)
    }

    func testToggleBottomTerminalChangesSelectedThreadVisibleState() {
        let model = AppModel()

        model.toggleBottomTerminal()

        XCTAssertTrue(model.isBottomTerminalExpanded)
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
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
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
        let root = URL(fileURLWithPath: "/tmp/yaaw", isDirectory: true)
        let model = AppModel(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
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
        let missing = URL(fileURLWithPath: "/tmp/yaaw-missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try model.createProject(displayName: "Missing", rootDirectory: missing)) { error in
            XCTAssertEqual(error as? AppModelError, .missingProjectDirectory(missing.path))
        }
    }

    func testMissingSelectedThreadDirectoryReportsStateAndBlocksTerminals() throws {
        let recorder = RecordingDiagnosticEventRecorder()
        let root = try temporaryDirectory()
        try FileManager.default.removeItem(at: root)
        let projectID = UUID()
        let threadID = UUID()
        let model = AppModel(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [Project(id: projectID, displayName: "Missing", rootDirectory: root)],
                    threads: [
                        AgentThread(
                            id: threadID,
                            displayName: "Missing Thread",
                            projectID: projectID,
                            workingDirectory: root
                        )
                    ],
                    selectedProjectID: projectID,
                    selectedThreadID: threadID,
                    rightPanelModesByThreadID: [threadID: .files],
                    selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false
                )
            ),
            diagnosticRecorder: recorder
        )

        XCTAssertEqual(model.selectedProjectDirectoryState, .missing(path: root.path))
        XCTAssertEqual(model.selectedThreadWorkingDirectoryState, .missing(path: root.path))
        XCTAssertNil(model.terminalLaunchRequest(for: .project(threadID: threadID)))

        model.refreshSelectedFileBrowser()

        XCTAssertEqual(model.fileBrowserState.rootPath, root.path)
        XCTAssertEqual(model.fileBrowserState.errorMessage, "Missing working directory: \(root.path)")
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Terminal"
                    && $0.name == "terminal_launch_failed"
                    && $0.metadata["reason"] == "missing_working_directory"
            }
        )
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Indexing"
                    && $0.name == "file_index_failed"
                    && $0.metadata["reason"] == "missing_root"
            }
        )
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

    func testDiagnosticEventsDoNotRecordTerminalOutput() throws {
        let fixture = AppModelFixture()
        let recorder = RecordingDiagnosticEventRecorder()
        let secretOutput = "session id: codex-secret\nSESSION_TOKEN=do-not-log\n"
        let model = AppModel(store: fixture.store, diagnosticRecorder: recorder)

        model.recordAgentCLIOutput(threadID: fixture.firstThreadID, output: secretOutput)
        _ = model.activateSelectedProjectTerminal()

        let renderedDiagnostics = recorder.events
            .flatMap { event in [event.category, event.name] + event.metadata.flatMap { [$0.key, $0.value] } }
            .joined(separator: "\n")
        XCTAssertFalse(renderedDiagnostics.contains("SESSION_TOKEN=do-not-log"))
        XCTAssertFalse(renderedDiagnostics.contains(secretOutput))
    }

    func testBottomTerminalSessionIsScopedToSelectedThread() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        let firstActivation = try XCTUnwrap(model.activateSelectedBottomTerminal())
        model.selectThread(id: fixture.secondThreadID)
        let secondActivation = try XCTUnwrap(model.activateSelectedBottomTerminal())

        XCTAssertNotEqual(firstActivation.id, secondActivation.id)
        XCTAssertEqual(firstActivation.request.role, .bottom(threadID: fixture.firstThreadID))
        XCTAssertEqual(secondActivation.request.role, .bottom(threadID: fixture.secondThreadID))
        XCTAssertEqual(firstActivation.request.workingDirectory, fixture.root)
        XCTAssertEqual(secondActivation.request.workingDirectory, fixture.root)
    }

    func testBottomTerminalToggleDoesNotMutateSidebarOrSelection() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)
        let sidebarWidth = model.layoutState.sidebarWidth
        let projectID = model.selectedProjectID
        let threadID = model.selectedThreadID

        model.toggleBottomTerminal()

        XCTAssertEqual(model.layoutState.sidebarWidth, sidebarWidth)
        XCTAssertFalse(model.layoutState.isSidebarCollapsed)
        XCTAssertEqual(model.selectedProjectID, projectID)
        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertTrue(model.isBottomTerminalExpanded)
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
        XCTAssertEqual(gitRequest.command, ["git", "diff"])
    }

    func testEditorFallbackUsesVimThenViWhenNvimMissing() throws {
        let fixture = AppModelFixture()
        let vimModel = AppModel(
            store: fixture.store,
            externalToolResolver: StaticAppModelExecutableResolver(paths: ["vim": "/usr/bin/vim"]),
            environment: [:]
        )
        vimModel.openFileInNvim(relativePath: "README.md")
        let vimRequest = try XCTUnwrap(vimModel.terminalLaunchRequest(for: .nvim(threadID: fixture.firstThreadID)))
        XCTAssertEqual(vimRequest.command, ["/usr/bin/vim", "README.md"])

        let viModel = AppModel(
            store: fixture.store,
            externalToolResolver: StaticAppModelExecutableResolver(paths: ["vi": "/usr/bin/vi"]),
            environment: [:]
        )
        viModel.openFileInNvim(relativePath: "README.md")
        let viRequest = try XCTUnwrap(viModel.terminalLaunchRequest(for: .nvim(threadID: fixture.firstThreadID)))
        XCTAssertEqual(viRequest.command, ["/usr/bin/vi", "README.md"])
    }

    func testGitFallbackUsesGitDiffWhenLazygitMissing() throws {
        let fixture = AppModelFixture()
        let model = AppModel(
            store: fixture.store,
            externalToolResolver: StaticAppModelExecutableResolver(paths: ["git": "/usr/bin/git"]),
            environment: [:]
        )

        model.selectRightPanelMode(.git)
        let request = try XCTUnwrap(model.terminalLaunchRequest(for: .lazygit(threadID: fixture.firstThreadID)))

        XCTAssertEqual(request.command, ["/usr/bin/git", "diff"])
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
            .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
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

private final class RecordingDiagnosticEventRecorder: DiagnosticEventRecording, @unchecked Sendable {
    private(set) var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        events.append(event)
    }
}

private struct AppModelFixture {
    let projectID = UUID()
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let root = FileManager.default.temporaryDirectory

    var store: InMemoryYAAWStore {
        InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
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
