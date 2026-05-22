import XCTest
@testable import YAAWKit

final class AppModelTests: XCTestCase {
    func testThreadRelativeTimeFormatterUsesCompactElapsedUnits() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            ThreadRelativeTimeFormatter.shortElapsed(since: now.addingTimeInterval(-45), now: now),
            "1m"
        )
        XCTAssertEqual(
            ThreadRelativeTimeFormatter.shortElapsed(since: now.addingTimeInterval(-(59 * 60)), now: now),
            "59m"
        )
        XCTAssertEqual(
            ThreadRelativeTimeFormatter.shortElapsed(since: now.addingTimeInterval(-(60 * 60)), now: now),
            "1h"
        )
        XCTAssertEqual(
            ThreadRelativeTimeFormatter.shortElapsed(since: now.addingTimeInterval(-(26 * 60 * 60)), now: now),
            "1d"
        )
        XCTAssertEqual(
            ThreadRelativeTimeFormatter.shortElapsed(since: now.addingTimeInterval(-(8 * 24 * 60 * 60)), now: now),
            "1w"
        )
    }

    func testTerminalNotificationUpdatesThreadActivityAndDispatchesSystemNotification() {
        let fixture = AppModelFixture()
        let dispatcher = RecordingThreadActivityNotificationDispatcher()
        let badgeUpdater = RecordingThreadActivityBadgeUpdater()
        let model = AppModel(
            store: fixture.store,
            notificationDispatcher: dispatcher,
            badgeUpdater: badgeUpdater,
            isApplicationActive: { false }
        )

        model.recordAgentTerminalNotification(
            threadID: fixture.firstThreadID,
            title: "Agent waiting",
            body: "Agent needs input before continuing"
        )

        let activity = model.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .needsInput)
        XCTAssertEqual(activity.preview, "Agent needs input before continuing")
        XCTAssertTrue(activity.isUnread)
        XCTAssertEqual(model.unreadThreadActivityCount, 1)
        XCTAssertEqual(badgeUpdater.counts.last, 1)
        XCTAssertEqual(dispatcher.notifications.first?.title, "First")
        XCTAssertEqual(dispatcher.notifications.first?.body, "Agent needs input before continuing")
    }

    func testFocusedSelectedThreadSuppressesUnreadAndSystemNotification() {
        let fixture = AppModelFixture()
        let dispatcher = RecordingThreadActivityNotificationDispatcher()
        let model = AppModel(
            store: fixture.store,
            notificationDispatcher: dispatcher,
            isApplicationActive: { true }
        )

        model.recordAgentTerminalFocus(threadID: fixture.firstThreadID, focused: true)
        model.recordAgentTerminalNotification(
            threadID: fixture.firstThreadID,
            title: "Agent waiting",
            body: "Agent needs input"
        )

        let activity = model.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .needsInput)
        XCTAssertFalse(activity.isUnread)
        XCTAssertTrue(dispatcher.notifications.isEmpty)
    }

    func testGenericTerminalNotificationPreservesExistingStatus() {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store, isApplicationActive: { false })

        model.recordAgentTerminalNotification(
            threadID: fixture.firstThreadID,
            title: "Agent update",
            body: "Wrote a draft response"
        )

        let activity = model.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .inactive)
        XCTAssertEqual(activity.preview, "Wrote a draft response")
        XCTAssertTrue(activity.isUnread)
    }

    func testPersistedWorkingActivityDowngradesToInactiveOnLaunch() {
        let fixture = AppModelFixture()
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: fixture.projectID, displayName: "Project", rootDirectory: fixture.root)],
                threads: [
                    AgentThread(
                        id: fixture.firstThreadID,
                        displayName: "First",
                        projectID: fixture.projectID,
                        workingDirectory: fixture.root
                    )
                ],
                selectedProjectID: fixture.projectID,
                selectedThreadID: fixture.firstThreadID,
                rightPanelModesByThreadID: [fixture.firstThreadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false,
                threadActivityByThreadID: [
                    fixture.firstThreadID: ThreadActivityState(
                        threadID: fixture.firstThreadID,
                        status: .working,
                        preview: "Running",
                        isUnread: true,
                        title: "Running",
                        body: nil,
                        source: .helper
                    )
                ]
            )
        )

        let model = AppModel(store: store)

        XCTAssertEqual(model.threadActivity(for: fixture.firstThreadID).status, .inactive)
        XCTAssertFalse(model.threadActivity(for: fixture.firstThreadID).isUnread)
        XCTAssertEqual(store.load().threadActivityByThreadID[fixture.firstThreadID]?.status, .inactive)
    }

    func testPollingHelperActivityEventsUpdatesThreadActivity() throws {
        let fixture = AppModelFixture()
        let activityDirectory = try temporaryDirectory()
        let service = AgentCLISessionBindingService(activityDirectory: activityDirectory, helperBinDirectory: activityDirectory)
        let model = AppModel(store: fixture.store, agentCLIBindings: service)
        let thread = try XCTUnwrap(model.selectedThread)
        let logURL = try XCTUnwrap(service.activityLogURL(for: thread))
        try """
        {"thread_id":"\(thread.id.uuidString)","status":"complete","title":"Done","body":"Tests passed","source":"helper","created_at":42}

        """.write(to: logURL, atomically: true, encoding: .utf8)

        model.pollAgentCLIActivityLogs()

        let activity = model.threadActivity(for: thread.id)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.preview, "Tests passed")
        XCTAssertTrue(activity.isUnread)
    }

    func testPollingHelperActivityEventsSkipsUnlaunchedBackgroundThreads() throws {
        let fixture = AppModelFixture()
        let activityDirectory = try temporaryDirectory()
        let service = AgentCLISessionBindingService(
            captureDirectory: activityDirectory,
            activityDirectory: activityDirectory,
            helperBinDirectory: activityDirectory
        )
        let model = AppModel(store: fixture.store, agentCLIBindings: service)
        let backgroundThread = try XCTUnwrap(model.threads.first { $0.id == fixture.secondThreadID })
        let logURL = try XCTUnwrap(service.activityLogURL(for: backgroundThread))
        try """
        {"thread_id":"\(backgroundThread.id.uuidString)","status":"complete","title":"Done","body":"Background finished","source":"helper","created_at":42}

        """.write(to: logURL, atomically: true, encoding: .utf8)

        model.pollAgentCLIActivityLogs()

        XCTAssertEqual(model.threadActivity(for: backgroundThread.id).status, .inactive)

        _ = model.terminalLaunchRequest(for: .project(threadID: backgroundThread.id))
        model.pollAgentCLIActivityLogs()

        let activity = model.threadActivity(for: backgroundThread.id)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.preview, "Background finished")
    }

    func testPollingHelperActivityEventsBuffersSplitJSONLines() throws {
        let fixture = AppModelFixture()
        let activityDirectory = try temporaryDirectory()
        let service = AgentCLISessionBindingService(activityDirectory: activityDirectory, helperBinDirectory: activityDirectory)
        let model = AppModel(store: fixture.store, agentCLIBindings: service)
        let thread = try XCTUnwrap(model.selectedThread)
        let logURL = try XCTUnwrap(service.activityLogURL(for: thread))
        let prefix = #"{"thread_id":"\#(thread.id.uuidString)","status":"complete","title":"Done""#
        let suffix = #","body":"Buffered event","source":"helper","created_at":42}"# + "\n"
        try prefix.write(to: logURL, atomically: true, encoding: .utf8)

        model.pollAgentCLIActivityLogs()

        XCTAssertEqual(model.threadActivity(for: thread.id).status, .inactive)

        try FileHandle(forWritingTo: logURL).closeAfterAppending(suffix)
        model.pollAgentCLIActivityLogs()

        let activity = model.threadActivity(for: thread.id)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.preview, "Buffered event")
    }

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

    func testPanelResizeActionsUseExpandedPanelLimits() {
        let model = AppModel()

        model.setSidebarWidth(600)
        model.setRightPanelWidth(650)
        model.setGlobalTerminalHeight(400)

        XCTAssertEqual(model.layoutState.sidebarWidth, 520)
        XCTAssertEqual(model.layoutState.rightPanelWidth, 650)
        XCTAssertEqual(model.layoutState.globalTerminalHeight, 400)
    }

    func testBottomTerminalHeightClampsToWindowRatioWhenProvided() {
        let model = AppModel()

        model.setGlobalTerminalHeight(300, availableWindowHeight: 600)

        XCTAssertEqual(model.layoutState.globalTerminalHeight, 270)
    }

    func testPanelResizeCanUpdateLiveWithoutPersistingEveryDragTick() {
        let store = InMemoryYAAWStore.helloWorld()
        let model = AppModel(store: store)

        model.setSidebarWidth(300, persist: false)
        model.setRightPanelWidth(500, persist: false)
        model.setGlobalTerminalHeight(220, persist: false)

        XCTAssertEqual(store.layoutStateWriteCount, 0)
        XCTAssertEqual(model.layoutState.sidebarWidth, 300)
        XCTAssertEqual(model.layoutState.rightPanelWidth, 500)
        XCTAssertEqual(model.layoutState.globalTerminalHeight, 220)

        model.commitLayoutResize()

        XCTAssertEqual(store.layoutStateWriteCount, 1)
    }

    func testPanelSizeResetActionsPersistDefaults() {
        let store = InMemoryYAAWStore.helloWorld()
        let model = AppModel(store: store)
        model.setSidebarWidth(400)
        model.setRightPanelWidth(600)
        model.setGlobalTerminalHeight(260)
        let writesAfterResize = store.layoutStateWriteCount

        model.resetSidebarWidth()
        model.resetRightPanelWidth()
        model.resetGlobalTerminalHeight()

        XCTAssertEqual(model.layoutState.sidebarWidth, LayoutState.defaultSidebarWidth)
        XCTAssertEqual(model.layoutState.rightPanelWidth, LayoutState.defaultRightPanelWidth)
        XCTAssertEqual(model.layoutState.globalTerminalHeight, LayoutState.defaultGlobalTerminalHeight)
        XCTAssertEqual(store.layoutStateWriteCount, writesAfterResize + 3)
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
        XCTAssertEqual(model.archivedThreads.map(\.id), [archivedThreadID])
        XCTAssertEqual(model.projectDisplayName(for: secondProjectID), "Second")
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

    func testCreateProjectDefaultsBlankNameToDirectoryName() throws {
        let model = AppModel()
        let root = try temporaryDirectory()

        let projectID = try model.createProject(displayName: "  ", rootDirectory: root)

        XCTAssertEqual(model.selectedProjectID, projectID)
        XCTAssertEqual(model.selectedProject?.displayName, root.lastPathComponent)
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

    func testCreateThreadUsesConfiguredDefaultAgentCLIWhenChoiceIsNotExplicit() throws {
        let fixture = AppModelFixture()
        let model = AppModel(
            store: fixture.store,
            configuration: YAAWConfiguration(agent: AgentSettings(default: .claude))
        )

        let threadID = try model.createThread(agentCLI: nil)
        let thread = try XCTUnwrap(model.threads.first { $0.id == threadID })

        XCTAssertEqual(thread.agentCLI, .claude)
        XCTAssertEqual(thread.displayName, "Starting Claude...")
    }

    func testCreateThreadDefaultsNameAndWorkingDirectory() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        let threadID = try model.createThread(agentCLI: .claude, now: Date(timeIntervalSince1970: 123))
        let thread = try XCTUnwrap(model.threads.first { $0.id == threadID })
        let activity = model.threadActivity(for: threadID)

        XCTAssertEqual(thread.displayName, "Starting Claude...")
        XCTAssertEqual(thread.agentCLI, .claude)
        XCTAssertEqual(thread.workingDirectory, fixture.root)
        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(model.selectedRightPanelMode, .files)
        XCTAssertEqual(activity.status, .inactive)
        XCTAssertNil(activity.preview)
        XCTAssertNil(fixture.store.load().threadActivityByThreadID[threadID])
    }

    func testTerminalLifecycleEventsStillDriveThreadActivity() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.recordAgentCommandFinished(threadID: fixture.firstThreadID, exitCode: 0)

        var activity = model.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.preview, "Command exited with status 0")

        model.recordAgentTerminalClosed(threadID: fixture.firstThreadID)

        activity = model.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .inactive)
        XCTAssertEqual(activity.preview, "Terminal closed")
    }

    func testCreateThreadCanTargetNonSelectedProjectAndUseOptionalName() throws {
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let firstRoot = try temporaryDirectory()
        let secondRoot = try temporaryDirectory()
        let model = AppModel(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(id: firstProjectID, displayName: "First", rootDirectory: firstRoot, sortOrder: 0),
                        Project(id: secondProjectID, displayName: "Second", rootDirectory: secondRoot, sortOrder: 1)
                    ],
                    threads: [],
                    selectedProjectID: firstProjectID,
                    selectedThreadID: nil,
                    selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false
                )
            )
        )

        let threadID = try model.createThread(
            projectID: secondProjectID,
            agentCLI: .codex,
            displayName: "  Investigate Checkout  "
        )
        let thread = try XCTUnwrap(model.threads.first { $0.id == threadID })

        XCTAssertEqual(model.selectedProjectID, secondProjectID)
        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(thread.projectID, secondProjectID)
        XCTAssertEqual(thread.workingDirectory, secondRoot)
        XCTAssertEqual(thread.displayName, "Investigate Checkout")
        XCTAssertTrue(model.isProjectExpanded(secondProjectID))
    }

    func testCreateThreadBlankOptionalNameKeepsCLIPlaceholder() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        let threadID = try model.createThread(agentCLI: .opencode, displayName: "   ")
        let thread = try XCTUnwrap(model.threads.first { $0.id == threadID })

        XCTAssertEqual(thread.displayName, "Starting OpenCode...")
    }

    func testThreadHistorySortsPinnedThenRecentlyOpened() {
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = FileManager.default.temporaryDirectory
        let model = AppModel(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                    threads: [
                        AgentThread(
                            id: firstThreadID,
                            displayName: "Older",
                            projectID: projectID,
                            workingDirectory: root,
                            lastOpenedAt: Date(timeIntervalSince1970: 10)
                        ),
                        AgentThread(
                            id: secondThreadID,
                            displayName: "Newer",
                            projectID: projectID,
                            workingDirectory: root,
                            lastOpenedAt: Date(timeIntervalSince1970: 20)
                        )
                    ],
                    selectedProjectID: projectID,
                    selectedThreadID: secondThreadID,
                    selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false
                )
            )
        )

        XCTAssertEqual(model.activeThreads(for: projectID).map(\.id), [secondThreadID, firstThreadID])

        model.selectThread(id: firstThreadID)
        XCTAssertEqual(model.activeThreads(for: projectID).map(\.id), [firstThreadID, secondThreadID])

        model.toggleThreadPinned(id: secondThreadID)
        XCTAssertEqual(model.activeThreads(for: projectID).map(\.id), [secondThreadID, firstThreadID])
    }

    func testArchiveAndUnarchiveMoveThreadsBetweenOrderedCaches() {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.archiveThread(id: fixture.firstThreadID)

        XCTAssertEqual(model.activeThreads(for: fixture.projectID).map(\.id), [fixture.secondThreadID])
        XCTAssertEqual(model.archivedThreads(for: fixture.projectID).map(\.id), [fixture.firstThreadID])

        model.unarchiveThread(id: fixture.firstThreadID)

        XCTAssertEqual(model.activeThreads(for: fixture.projectID).map(\.id).first, fixture.firstThreadID)
        XCTAssertTrue(model.archivedThreads(for: fixture.projectID).isEmpty)
    }

    func testAgentCLIMetadataRenameReordersCachedThreads() {
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = FileManager.default.temporaryDirectory
        let timestamp = Date(timeIntervalSince1970: 10)
        let model = AppModel(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                    threads: [
                        AgentThread(
                            id: firstThreadID,
                            displayName: "Bravo",
                            projectID: projectID,
                            workingDirectory: root,
                            agentCLI: .codex,
                            createdAt: timestamp,
                            lastOpenedAt: timestamp
                        ),
                        AgentThread(
                            id: secondThreadID,
                            displayName: "Charlie",
                            projectID: projectID,
                            workingDirectory: root,
                            agentCLI: .codex,
                            createdAt: timestamp,
                            lastOpenedAt: timestamp
                        )
                    ],
                    selectedProjectID: projectID,
                    selectedThreadID: firstThreadID,
                    selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false
                )
            )
        )

        XCTAssertEqual(model.activeThreads(for: projectID).map(\.id), [firstThreadID, secondThreadID])

        model.recordAgentCLIOutput(
            threadID: secondThreadID,
            output: """
            session id: codex-session-222
            session name: Alpha
            """
        )

        XCTAssertEqual(model.activeThreads(for: projectID).map(\.id), [secondThreadID, firstThreadID])
    }

    func testThreadActivitySortsProjectThreadsByRecentInteraction() {
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = FileManager.default.temporaryDirectory
        let olderDate = Date(timeIntervalSince1970: 10)
        let newerDate = Date(timeIntervalSince1970: 20)
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: firstThreadID,
                        displayName: "Older",
                        projectID: projectID,
                        workingDirectory: root,
                        lastOpenedAt: olderDate
                    ),
                    AgentThread(
                        id: secondThreadID,
                        displayName: "Newer",
                        projectID: projectID,
                        workingDirectory: root,
                        lastOpenedAt: newerDate
                    )
                ],
                selectedProjectID: projectID,
                selectedThreadID: secondThreadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        let model = AppModel(store: store)

        XCTAssertEqual(model.activeThreads(for: projectID).map(\.id), [secondThreadID, firstThreadID])

        model.recordAgentCommandFinished(threadID: firstThreadID, exitCode: 0)

        XCTAssertEqual(model.activeThreads(for: projectID).map(\.id), [firstThreadID, secondThreadID])
        XCTAssertGreaterThan(
            store.load().threads.first { $0.id == firstThreadID }?.lastOpenedAt ?? olderDate,
            newerDate
        )
    }

    func testProjectPinningAndManualReorderUsePinnedFirstGroups() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let root = FileManager.default.temporaryDirectory
        let model = AppModel(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(id: firstID, displayName: "First", rootDirectory: root, sortOrder: 0),
                        Project(id: secondID, displayName: "Second", rootDirectory: root, sortOrder: 1),
                        Project(id: thirdID, displayName: "Third", rootDirectory: root, sortOrder: 2)
                    ],
                    threads: [],
                    selectedProjectID: firstID,
                    selectedThreadID: nil,
                    selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false
                )
            )
        )

        model.toggleProjectPinned(id: thirdID)
        XCTAssertEqual(model.projects.map(\.id), [thirdID, firstID, secondID])

        model.moveProject(id: secondID, direction: .up)
        XCTAssertEqual(model.projects.map(\.id), [thirdID, secondID, firstID])

        model.moveProject(id: firstID, direction: .up)
        XCTAssertEqual(model.projects.map(\.id), [thirdID, firstID, secondID])
    }

    func testProjectDragReorderUsesPinnedFirstGroups() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let root = FileManager.default.temporaryDirectory
        let model = AppModel(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [
                        Project(id: firstID, displayName: "First", rootDirectory: root, sortOrder: 0),
                        Project(id: secondID, displayName: "Second", rootDirectory: root, sortOrder: 1),
                        Project(id: thirdID, displayName: "Third", rootDirectory: root, isPinned: true, sortOrder: 0)
                    ],
                    threads: [],
                    selectedProjectID: firstID,
                    selectedThreadID: nil,
                    selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false
                )
            )
        )

        model.reorderProject(id: secondID, before: firstID)
        XCTAssertEqual(model.projects.map(\.id), [thirdID, secondID, firstID])
        XCTAssertEqual(model.projects.filter { !$0.isPinned }.map(\.sortOrder), [0, 1])

        model.reorderProject(id: firstID, before: thirdID)
        XCTAssertEqual(model.projects.map(\.id), [thirdID, secondID, firstID])
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

    func testConfiguredAgentExecutableNameIsUsedForProjectTerminal() throws {
        let fixture = AppModelFixture()
        let service = AgentCLISessionBindingService(
            resolver: StaticAppModelExecutableResolver(paths: ["codex-nightly": "/tools/codex-nightly"]),
            captureDirectory: nil
        )
        let model = AppModel(
            store: fixture.store,
            agentCLIBindings: service,
            configuration: YAAWConfiguration(
                tools: ToolSettings(agents: AgentToolSettings(codex: "codex-nightly"))
            )
        )

        let request = try XCTUnwrap(model.terminalLaunchRequest(for: .project(threadID: fixture.firstThreadID)))

        XCTAssertEqual(request.command, ["/tools/codex-nightly"])
    }

    func testReloadConfigurationAppliesThemeAndRecordsDiagnostic() throws {
        let fixture = AppModelFixture()
        let recorder = RecordingDiagnosticEventRecorder()
        let model = AppModel(store: fixture.store, diagnosticRecorder: recorder)

        model.reloadConfiguration(YAAWConfiguration(theme: ThemeSettings(active: "solarized-light")))

        XCTAssertEqual(model.configuration.themeName, "solarized-light")
        XCTAssertEqual(model.configuration.resolvedTheme.displayName, "Solarized Light")
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Configuration"
                    && $0.name == "settings_yaml_reloaded"
                    && $0.metadata["theme"] == "solarized-light"
            }
        )
    }

    func testConfiguredEditorAndGitToolsAreUsedForRightPanelTerminals() throws {
        let fixture = AppModelFixture()
        let resolver = StaticAppModelExecutableResolver(
            paths: [
                "zed": "/tools/zed",
                "tig": "/tools/tig"
            ]
        )
        let model = AppModel(
            store: fixture.store,
            externalToolResolver: resolver,
            configuration: YAAWConfiguration(
                tools: ToolSettings(
                    editors: EditorToolSettings(preferred: ["zed", "nvim"]),
                    git: GitToolSettings(preferred: "tig")
                )
            )
        )

        model.openFileInNvim(relativePath: "Package.swift")
        let editorRequest = try XCTUnwrap(model.terminalLaunchRequest(for: .nvim(threadID: fixture.firstThreadID)))
        let gitRequest = try XCTUnwrap(model.terminalLaunchRequest(for: .lazygit(threadID: fixture.firstThreadID)))

        XCTAssertEqual(editorRequest.command, ["/tools/zed", "Package.swift"])
        XCTAssertEqual(gitRequest.command, ["/tools/tig"])
    }

    func testConfiguredDiffFallbackIsUsedWhenGitToolIsMissing() throws {
        let fixture = AppModelFixture()
        let resolver = StaticAppModelExecutableResolver(paths: ["delta": "/tools/delta"])
        let model = AppModel(
            store: fixture.store,
            externalToolResolver: resolver,
            configuration: YAAWConfiguration(
                tools: ToolSettings(
                    git: GitToolSettings(preferred: "missing-lazygit"),
                    diff: DiffToolSettings(fallback: ["delta", "--diff"])
                )
            )
        )

        let gitRequest = try XCTUnwrap(model.terminalLaunchRequest(for: .lazygit(threadID: fixture.firstThreadID)))

        XCTAssertEqual(gitRequest.command, ["/tools/delta", "--diff"])
    }

    func testGitModeResolvesLazygitFromFallbackSearchPathWhenGUIPathOmitsHomebrew() throws {
        let fixture = AppModelFixture()
        let root = try temporaryDirectory()
        let homebrewBin = root.appendingPathComponent("homebrew-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homebrewBin, withIntermediateDirectories: true)
        let lazygit = homebrewBin.appendingPathComponent("lazygit")
        try writeExecutable(at: lazygit, contents: "#!/bin/sh\n")
        let model = AppModel(
            store: fixture.store,
            externalToolResolver: PATHAgentCLIExecutableResolver(fallbackSearchPaths: [homebrewBin.path]),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )

        model.selectRightPanelMode(.git)
        let request = try XCTUnwrap(model.terminalLaunchRequest(for: .lazygit(threadID: fixture.firstThreadID)))

        XCTAssertEqual(request.command, [lazygit.path])
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
        XCTAssertEqual(nvimSession.request.role, .nvimTab(threadID: fixture.firstThreadID, tabID: RightPanelTab.defaultNvimID))
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

        let tabID = RightPanelTab.nvimTabID(relativePath: "src/App/RootView.swift")
        let request = try XCTUnwrap(model.terminalLaunchRequest(for: .nvimTab(threadID: fixture.firstThreadID, tabID: tabID)))
        XCTAssertEqual(model.selectedRightPanelMode, .nvim)
        XCTAssertEqual(model.selectedRightPanelTab.id, tabID)
        XCTAssertEqual(request.workingDirectory, fixture.root)
        XCTAssertEqual(request.command, ["/tools/nvim", "src/App/RootView.swift"])
    }

    func testOpeningNewNestedFileInNvimAllowsProjectRelativePath() throws {
        let fixture = AppModelFixture()
        let resolver = StaticAppModelExecutableResolver(paths: ["nvim": "/tools/nvim"])
        let model = AppModel(store: fixture.store, externalToolResolver: resolver, environment: [:])

        model.openFileInNvim(relativePath: "docs/plans/new-note.md")

        let tabID = RightPanelTab.nvimTabID(relativePath: "docs/plans/new-note.md")
        let request = try XCTUnwrap(model.terminalLaunchRequest(for: .nvimTab(threadID: fixture.firstThreadID, tabID: tabID)))
        XCTAssertEqual(model.selectedFileRelativePath, "docs/plans/new-note.md")
        XCTAssertEqual(model.selectedRightPanelMode, .nvim)
        XCTAssertEqual(model.selectedRightPanelTab.id, tabID)
        XCTAssertEqual(request.workingDirectory, fixture.root)
        XCTAssertEqual(request.command, ["/tools/nvim", "docs/plans/new-note.md"])
    }

    func testOpeningEscapingFileInNvimDoesNotChangeRightPanelState() throws {
        let fixture = AppModelFixture()
        let resolver = StaticAppModelExecutableResolver(paths: ["nvim": "/tools/nvim"])
        let model = AppModel(store: fixture.store, externalToolResolver: resolver, environment: [:])
        let originalSelectedFile = model.selectedFileRelativePath
        let originalMode = model.selectedRightPanelMode
        let originalState = model.selectedRightPanelState

        model.openFileInNvim(relativePath: "../outside.swift")

        XCTAssertEqual(model.selectedFileRelativePath, originalSelectedFile)
        XCTAssertEqual(model.selectedRightPanelMode, originalMode)
        XCTAssertEqual(model.selectedRightPanelState, originalState)
        XCTAssertNil(model.terminalLaunchRequest(for: .nvimTab(
            threadID: fixture.firstThreadID,
            tabID: RightPanelTab.nvimTabID(relativePath: "outside.swift")
        )))
    }

    func testRightPanelTabOrderKeepsFilesGitNvimTabsThenPlusSlot() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.openFileInNvim(relativePath: "README.md")
        model.openFileInNvim(relativePath: "src/App/RootView.swift")

        XCTAssertEqual(
            model.selectedRightPanelState.tabs.map(\.id),
            [
                RightPanelTab.filesID,
                RightPanelTab.defaultBrowserID,
                RightPanelTab.gitID,
                RightPanelTab.defaultNvimID,
                RightPanelTab.nvimTabID(relativePath: "README.md"),
                RightPanelTab.nvimTabID(relativePath: "src/App/RootView.swift")
            ]
        )
    }

    func testOpeningSupportedFileInBrowserUsesFileURLAndStaysInWorkingDirectory() throws {
        let root = try temporaryDirectory()
        let preview = root.appendingPathComponent("index.html")
        try "<h1>Preview</h1>".write(to: preview, atomically: true, encoding: .utf8)
        let projectID = UUID()
        let threadID = UUID()
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(id: threadID, displayName: "Thread", projectID: projectID, workingDirectory: root)
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        let model = AppModel(store: store)

        XCTAssertTrue(model.openFileInBrowser(relativePath: "index.html"))

        XCTAssertEqual(model.selectedRightPanelMode, .browser)
        XCTAssertEqual(model.selectedRightPanelTab.id, RightPanelTab.browserTabID(urlString: nil, relativePath: "index.html"))
        XCTAssertEqual(model.selectedRightPanelTab.relativePath, "index.html")
        XCTAssertEqual(model.selectedRightPanelTab.urlString, preview.standardizedFileURL.absoluteString)
        XCTAssertNil(model.selectedBrowserUnavailableMessage)
    }

    func testOpeningMarkdownFileInBrowserUsesFileURLAndStaysInWorkingDirectory() throws {
        let root = try temporaryDirectory()
        let preview = root.appendingPathComponent("README.md")
        try """
        # Preview

        ```mermaid
        graph TD
          A[Start] --> B[Done]
        ```
        """.write(to: preview, atomically: true, encoding: .utf8)
        let projectID = UUID()
        let threadID = UUID()
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(id: threadID, displayName: "Thread", projectID: projectID, workingDirectory: root)
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        let model = AppModel(store: store)

        XCTAssertTrue(model.openFileInBrowser(relativePath: "README.md"))

        XCTAssertEqual(model.selectedRightPanelMode, .browser)
        XCTAssertEqual(model.selectedRightPanelTab.id, RightPanelTab.browserTabID(urlString: nil, relativePath: "README.md"))
        XCTAssertEqual(model.selectedRightPanelTab.relativePath, "README.md")
        XCTAssertEqual(model.selectedRightPanelTab.urlString, preview.standardizedFileURL.absoluteString)
        XCTAssertNil(model.selectedBrowserUnavailableMessage)
    }

    func testBrowserRejectsUnsupportedAndEscapingFilePathsWithoutChangingTab() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)
        let originalTab = model.selectedRightPanelTab

        XCTAssertFalse(model.openFileInBrowser(relativePath: "../secret.html"))
        XCTAssertEqual(model.selectedRightPanelTab, originalTab)
        XCTAssertNotNil(model.selectedBrowserUnavailableMessage)

        XCTAssertFalse(model.openFileInBrowser(relativePath: "Package.swift"))
        XCTAssertEqual(model.selectedRightPanelTab, originalTab)
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
        XCTAssertEqual(gitRequest.command, ["git", "--no-pager", "diff"])
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

        XCTAssertEqual(request.command, ["/usr/bin/git", "--no-pager", "diff"])
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

    func testOpeningSameFileSelectsExistingNvimTabWithoutReplacingSession() throws {
        let fixture = AppModelFixture()
        let manager = PlaceholderTerminalSessionManager()
        let resolver = StaticAppModelExecutableResolver(paths: ["nvim": "/tools/nvim"])
        let model = AppModel(store: fixture.store, terminalManager: manager, externalToolResolver: resolver, environment: [:])

        model.openFileInNvim(relativePath: "README.md")
        let firstSession = try XCTUnwrap(model.activateSelectedRightPanelTerminal())
        model.selectRightPanelMode(.files)
        model.openFileInNvim(relativePath: "README.md")
        let secondSession = try XCTUnwrap(model.activateSelectedRightPanelTerminal())

        XCTAssertEqual(firstSession.id, secondSession.id)
        XCTAssertEqual(firstSession.request, secondSession.request)
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

    func testSelectedExternalOpenDirectoryUsesSelectedThreadWorkingDirectory() throws {
        let root = try temporaryDirectory()
        let worktree = try temporaryDirectory()
        let projectID = UUID()
        let threadID = UUID()
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID,
                        displayName: "Thread",
                        projectID: projectID,
                        workingDirectory: worktree,
                        agentCLI: .codex
                    )
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        let model = AppModel(store: store)

        XCTAssertEqual(
            model.selectedExternalOpenDirectoryTarget,
            ExternalOpenTarget(url: worktree, kind: .directory)
        )
    }

    func testSelectedExternalOpenDirectoryFallsBackToProjectWhenNoThreadIsSelected() throws {
        let root = try temporaryDirectory()
        let projectID = UUID()
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [],
                selectedProjectID: projectID,
                selectedThreadID: nil,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        let model = AppModel(store: store)

        XCTAssertEqual(
            model.selectedExternalOpenDirectoryTarget,
            ExternalOpenTarget(url: root, kind: .directory)
        )
    }

    func testExternalOpenFileTargetUsesSelectedThreadWorkingDirectory() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        let target = model.externalOpenFileTarget(relativePath: "src/App/RootView.swift")

        XCTAssertEqual(
            target,
            ExternalOpenTarget(
                url: fixture.root.appendingPathComponent("src/App/RootView.swift"),
                kind: .file
            )
        )
    }

    func testFileBrowserPathResolutionRejectsEscapingRelativePaths() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        XCTAssertEqual(
            model.fileBrowserURL(relativePath: "src/App/RootView.swift"),
            fixture.root.appendingPathComponent("src/App/RootView.swift").standardizedFileURL
        )
        XCTAssertNil(model.fileBrowserURL(relativePath: "../outside.swift"))
        XCTAssertNil(model.fileBrowserExternalOpenTarget(relativePath: "../outside.swift", isDirectory: false))
    }

    func testSelectedContextProjectAndThreadCommandsUpdateCurrentSelection() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.toggleSelectedProjectPinned()
        model.toggleSelectedThreadPinned()
        model.archiveSelectedThread()

        XCTAssertTrue(try XCTUnwrap(model.projects.first { $0.id == fixture.projectID }).isPinned)
        XCTAssertTrue(try XCTUnwrap(model.threads.first { $0.id == fixture.firstThreadID }).isPinned)
        XCTAssertTrue(try XCTUnwrap(model.threads.first { $0.id == fixture.firstThreadID }).isArchived)
        XCTAssertEqual(model.selectedThreadID, fixture.secondThreadID)
    }

    func testSelectedFileDrivesExternalOpenAndNvimCommands() throws {
        let fixture = AppModelFixture()
        let model = AppModel(store: fixture.store)

        model.openFileInNvim(relativePath: "src/App/RootView.swift")
        let target = try XCTUnwrap(model.selectedExternalOpenFileTarget)

        XCTAssertEqual(
            target,
            ExternalOpenTarget(
                url: fixture.root.appendingPathComponent("src/App/RootView.swift"),
                kind: .file
            )
        )
        XCTAssertEqual(model.selectedRightPanelMode, .nvim)

        model.selectRightPanelMode(.files)
        model.openSelectedFileInNvim()

        XCTAssertEqual(model.selectedRightPanelMode, .nvim)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at path: URL, contents: String) throws {
        try contents.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
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

private final class RecordingThreadActivityNotificationDispatcher: ThreadActivityNotificationDispatching, @unchecked Sendable {
    private(set) var notifications: [ThreadActivityNotification] = []

    func dispatch(_ notification: ThreadActivityNotification) {
        notifications.append(notification)
    }
}

private final class RecordingThreadActivityBadgeUpdater: ThreadActivityBadgeUpdating, @unchecked Sendable {
    private(set) var counts: [Int] = []

    func updateUnreadThreadActivityCount(_ count: Int) {
        counts.append(count)
    }
}

private extension FileHandle {
    func closeAfterAppending(_ text: String) throws {
        defer { try? close() }
        try seekToEnd()
        try write(contentsOf: Data(text.utf8))
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
