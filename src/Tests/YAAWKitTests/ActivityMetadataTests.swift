import XCTest

@testable import YAAWKit

/// Terminal-title heuristics, captured-metadata application, and activity-log
/// polling parity, re-pointed from `AppModelTests` onto `ActivityStore` +
/// `WorkspaceStore` + `SessionBindingActor`.
final class ActivityMetadataTests: XCTestCase {
    func testThreadActivityTextInfersCodexPromptReadyAfterWorking() {
        let output = """
            \u{001B}]0;yaaw\u{0007}Working (5m 16s - esc to interrupt)
            > Use /skills to list available skills gpt-5.5 high fast - ~/github/dopsonbr/yaaw - Context 13% used
            """
        XCTAssertEqual(ThreadActivityText.inferredStatus(fromTerminalOutput: output), .complete)
    }

    func testThreadActivityTextInfersCodexWorkedForSummaryAsComplete() {
        XCTAssertEqual(
            ThreadActivityText.inferredStatus(fromTerminalOutput: "Worked for 2m 52s"), .complete)
    }

    @MainActor
    func testCapturedWorkingOutputStillAppliesAgentCLIMetadata() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID,
            output: "Thinking...\nsession id: codex-session-789\nsession name: Captured Session")
        XCTAssertEqual(harness.activity.threadActivity(for: fixture.firstThreadID).status, .working)
        XCTAssertEqual(harness.workspace.selectedThread?.sessionIdentity, "codex-session-789")
        XCTAssertEqual(harness.workspace.selectedThread?.displayName, "Captured Session")
    }

    @MainActor
    func testCapturedCodexPromptReadyOutputClearsStaleWorkingState() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID, output: "Working (5m 16s - esc to interrupt)")
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID,
            output:
                "Working (5m 16s - esc to interrupt) > Use /skills to list available skills gpt-5.5 high fast - ~/github/dopsonbr/yaaw - Context 13% used"
        )
        let activity = harness.activity.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertNil(activity.preview)
        XCTAssertFalse(activity.isUnread)
    }

    @MainActor
    func testTransientTerminalTitleDoesNotOverwriteCapturedCanonicalName() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID,
            output: "session id: codex-session-789\nsession name: Captured Session")
        await harness.activity.recordAgentCLITerminalTitle(
            threadID: fixture.firstThreadID, title: "~/project")
        XCTAssertEqual(harness.workspace.selectedThread?.canonicalSessionName, "Captured Session")
        XCTAssertEqual(harness.workspace.selectedThread?.displayName, "Captured Session")
    }

    @MainActor
    func testEarlyTerminalTitleBecomesFallbackWhenOutputOnlyReportsIdentity() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLITerminalTitle(
            threadID: fixture.firstThreadID, title: "CLI Title")
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID, output: "session id: codex-session-789")
        XCTAssertEqual(harness.workspace.selectedThread?.sessionIdentity, "codex-session-789")
        XCTAssertEqual(harness.workspace.selectedThread?.canonicalSessionName, "CLI Title")
        XCTAssertEqual(harness.workspace.selectedThread?.displayName, "CLI Title")
    }

    @MainActor
    func testClaudeTerminalTitleDoesNotBecomeThreadName() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.secondThreadID, output: "session id: claude-xyz")
        await harness.activity.recordAgentCLITerminalTitle(
            threadID: fixture.secondThreadID, title: "Bash")
        let claudeThread = harness.workspace.threads.first { $0.id == fixture.secondThreadID }
        XCTAssertEqual(claudeThread?.sessionIdentity, "claude-xyz")
        XCTAssertEqual(claudeThread?.displayName, "Second")
        XCTAssertNil(claudeThread?.canonicalSessionName)
    }

    @MainActor
    func testClaudeTerminalTitleShowsAsActivityPreview() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLITerminalTitle(
            threadID: fixture.secondThreadID, title: "Bash")
        XCTAssertEqual(harness.activity.threadActivity(for: fixture.secondThreadID).preview, "Bash")
        XCTAssertEqual(
            harness.workspace.threads.first { $0.id == fixture.secondThreadID }?.displayName,
            "Second")
    }

    @MainActor
    func testClaudeTerminalTitleMatchingThreadNameShowsNoSubtitle() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLITerminalTitle(
            threadID: fixture.secondThreadID, title: "Bash")
        XCTAssertEqual(harness.activity.threadActivity(for: fixture.secondThreadID).preview, "Bash")
        await harness.activity.recordAgentCLITerminalTitle(
            threadID: fixture.secondThreadID, title: "Second")
        XCTAssertNil(harness.activity.threadActivity(for: fixture.secondThreadID).preview)
    }

    @MainActor
    func testClaudeAuthoritativeReportedNameStillNamesThread() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.secondThreadID,
            output: "session id: claude-xyz\nsession name: Real Session Name")
        let claudeThread = harness.workspace.threads.first { $0.id == fixture.secondThreadID }
        XCTAssertEqual(claudeThread?.canonicalSessionName, "Real Session Name")
        XCTAssertEqual(claudeThread?.displayName, "Real Session Name")
    }

    @MainActor
    func testClaudeEstablishedNameSurvivesToolTitleChurn() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.secondThreadID,
            output: "session id: claude-xyz\nsession name: Real Session Name")
        for tool in ["Bash", "Read", "Edit"] {
            await harness.activity.recordAgentCLITerminalTitle(
                threadID: fixture.secondThreadID, title: tool)
        }
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.secondThreadID, output: "session id: claude-xyz")
        let claudeThread = harness.workspace.threads.first { $0.id == fixture.secondThreadID }
        XCTAssertEqual(claudeThread?.displayName, "Real Session Name")
        XCTAssertEqual(claudeThread?.canonicalSessionName, "Real Session Name")
        XCTAssertEqual(harness.activity.threadActivity(for: fixture.secondThreadID).preview, "Edit")
    }

    @MainActor
    func testQueuedRenameWaitsForConfirmedCLIMetadata() async throws {
        let fixture = StoreFixture()
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [
                    Project(
                        id: fixture.projectID, displayName: "Project", rootDirectory: fixture.root)
                ],
                threads: [
                    AgentThread(
                        id: fixture.firstThreadID, displayName: "Original",
                        projectID: fixture.projectID,
                        workingDirectory: fixture.root, agentCLI: .codex,
                        sessionIdentity: "codex-1", canonicalSessionName: "Original")
                ],
                selectedProjectID: fixture.projectID, selectedThreadID: fixture.firstThreadID,
                selectedRightPanelMode: .files, isGlobalTerminalExpanded: false))
        let harness = await StoreHarnessBuilder.make(store: store)

        try await harness.workspace.requestThreadRename(
            id: fixture.firstThreadID, to: "  Renamed  ")
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID, output: "session id: codex-1\nsession name: Original")
        XCTAssertEqual(harness.workspace.selectedThread?.displayName, "Original")
        XCTAssertEqual(harness.workspace.selectedThread?.pendingSessionRename, "Renamed")

        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID, output: "session id: codex-1\nsession name: Renamed")
        XCTAssertEqual(harness.workspace.selectedThread?.displayName, "Renamed")
        XCTAssertNil(harness.workspace.selectedThread?.pendingSessionRename)
        await harness.flush()
        let reloaded = await store.load()
        XCTAssertEqual(reloaded.threads.first?.displayName, "Renamed")
    }

    // MARK: - Activity-log polling

    @MainActor
    func testPollingHelperActivityEventsUpdatesThreadActivity() async throws {
        let fixture = StoreFixture()
        let activityDirectory = try storeTemporaryDirectory()
        let service = SessionBindingActor(
            captureDirectory: nil, activityDirectory: activityDirectory,
            helperBinDirectory: activityDirectory)
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), sessionBindingActor: service)
        let logURL = activityDirectory.appendingPathComponent("\(fixture.firstThreadID).ndjson")
        try """
        {"thread_id":"\(fixture.firstThreadID.uuidString)","status":"complete","title":"Done","body":"Tests passed","source":"helper","created_at":42}

        """.write(to: logURL, atomically: true, encoding: .utf8)

        await harness.activity.pollAgentCLIActivityLogs()
        let activity = harness.activity.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.preview, "Tests passed")
        XCTAssertTrue(activity.isUnread)
    }

    @MainActor
    func testPollingHelperActivityEventsBuffersSplitJSONLines() async throws {
        let fixture = StoreFixture()
        let activityDirectory = try storeTemporaryDirectory()
        let service = SessionBindingActor(
            captureDirectory: nil, activityDirectory: activityDirectory,
            helperBinDirectory: activityDirectory)
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), sessionBindingActor: service)
        let logURL = activityDirectory.appendingPathComponent("\(fixture.firstThreadID).ndjson")
        let prefix =
            #"{"thread_id":"\#(fixture.firstThreadID.uuidString)","status":"complete","title":"Done""#
        let suffix = #","body":"Buffered event","source":"helper","created_at":42}"# + "\n"
        try prefix.write(to: logURL, atomically: true, encoding: .utf8)

        await harness.activity.pollAgentCLIActivityLogs()
        XCTAssertEqual(
            harness.activity.threadActivity(for: fixture.firstThreadID).status, .inactive)

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()
        await harness.activity.pollAgentCLIActivityLogs()
        let activity = harness.activity.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.preview, "Buffered event")
    }

    @MainActor
    func testBackgroundAgentCLIPollAppliesCaptureAndActivityOutput() async throws {
        let fixture = StoreFixture()
        let directory = try storeTemporaryDirectory()
        let service = SessionBindingActor(
            captureDirectory: directory, activityDirectory: directory, helperBinDirectory: directory
        )
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), sessionBindingActor: service)
        let captureURL = directory.appendingPathComponent("\(fixture.firstThreadID).log")
        let activityURL = directory.appendingPathComponent("\(fixture.firstThreadID).ndjson")
        try "session id: background-session\nsession name: Background Session\n".write(
            to: captureURL, atomically: true, encoding: .utf8)
        try """
        {"thread_id":"\(fixture.firstThreadID.uuidString)","status":"complete","title":"Done","body":"Background poll","source":"helper","created_at":42}

        """.write(to: activityURL, atomically: true, encoding: .utf8)

        await harness.activity.pollAgentCLIStateInBackground()
        XCTAssertEqual(harness.workspace.selectedThread?.sessionIdentity, "background-session")
        XCTAssertEqual(harness.workspace.selectedThread?.displayName, "Background Session")
        XCTAssertEqual(
            harness.activity.threadActivity(for: fixture.firstThreadID).preview, "Background poll")
        XCTAssertEqual(
            harness.activity.threadActivity(for: fixture.firstThreadID).status, .complete)
    }

    // MARK: - File-browser snapshot reuse

    @MainActor
    func testSelectingSameDirectoryThreadReusesPublishedFileBrowserSnapshot() async throws {
        let root = try storeTemporaryDirectory()
        try "readme\n".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let harness = await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                    threads: [
                        AgentThread(
                            id: firstThreadID, displayName: "First", projectID: projectID,
                            workingDirectory: root, agentCLI: .codex),
                        AgentThread(
                            id: secondThreadID, displayName: "Second", projectID: projectID,
                            workingDirectory: root, agentCLI: .claude),
                    ],
                    selectedProjectID: projectID, selectedThreadID: firstThreadID,
                    rightPanelModesByThreadID: [firstThreadID: .files, secondThreadID: .files],
                    selectedRightPanelMode: .files, isGlobalTerminalExpanded: false)),
            fileIndexer: ImmediateTestFileIndexer())

        harness.activity.refreshSelectedFileBrowser()
        await harness.flush()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(
            harness.activity.fileBrowserState.visibleEntries.contains {
                $0.relativePath == "README.md"
            })

        harness.workspace.selectThread(id: secondThreadID)
        XCTAssertTrue(
            harness.activity.fileBrowserState.visibleEntries.contains {
                $0.relativePath == "README.md"
            })
        XCTAssertEqual(harness.activity.fileBrowserState.metadata?.threadID, secondThreadID)
    }
}
