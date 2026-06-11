import XCTest

@testable import YAAWKit

/// Activity / notification / unread / badge parity, re-pointed from
/// `AppModelTests` onto `ActivityStore` (with `WorkspaceStore` for thread reads).
final class ActivityStoreTests: XCTestCase {
    func testThreadActivityTextInfersWorkingBeforeDoneCompletion() {
        XCTAssertEqual(
            ThreadActivityText.inferredStatus(title: nil, body: "Almost done thinking"), .working)
        XCTAssertEqual(
            ThreadActivityText.inferredStatus(title: nil, body: "Plan mode on"), .working)
        XCTAssertEqual(
            ThreadActivityText.inferredStatus(title: nil, body: "Esc to interrupt"), .working)
    }

    func testThreadActivityTextInfersNeedsInputAndCompletion() {
        XCTAssertEqual(
            ThreadActivityText.inferredStatus(title: nil, body: "Claude is waiting for your input"),
            .needsInput)
        XCTAssertEqual(
            ThreadActivityText.inferredStatus(title: "Task complete", body: nil), .complete)
        XCTAssertEqual(ThreadActivityText.inferredStatus(title: nil, body: "Finished"), .complete)
    }

    @MainActor
    func testTerminalNotificationUpdatesThreadActivityAndDispatchesSystemNotification() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), isApplicationActive: { false })

        harness.activity.recordAgentTerminalNotification(
            threadID: fixture.firstThreadID, title: "Agent waiting",
            body: "Agent needs input before continuing")
        await harness.flush()

        let activity = harness.activity.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .needsInput)
        XCTAssertEqual(activity.preview, "Agent needs input before continuing")
        XCTAssertTrue(activity.isUnread)
        XCTAssertEqual(harness.activity.unreadThreadActivityCount, 1)
        XCTAssertEqual(harness.badgeUpdater.counts.last, 1)
        XCTAssertEqual(harness.notificationDispatcher.notifications.first?.title, "First")
        XCTAssertEqual(
            harness.notificationDispatcher.notifications.first?.body,
            "Agent needs input before continuing")
    }

    @MainActor
    func testFocusedSelectedThreadSuppressesUnreadAndSystemNotification() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), isApplicationActive: { true })

        harness.activity.recordAgentTerminalFocus(threadID: fixture.firstThreadID, focused: true)
        harness.activity.recordAgentTerminalNotification(
            threadID: fixture.firstThreadID, title: "Agent waiting", body: "Agent needs input")
        await harness.flush()

        let activity = harness.activity.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .needsInput)
        XCTAssertFalse(activity.isUnread)
        XCTAssertTrue(harness.notificationDispatcher.notifications.isEmpty)
    }

    @MainActor
    func testGenericTerminalNotificationPreservesExistingStatus() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), isApplicationActive: { false })

        harness.activity.recordAgentTerminalNotification(
            threadID: fixture.firstThreadID, title: "Agent update", body: "Wrote a draft response")

        let activity = harness.activity.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .inactive)
        XCTAssertEqual(activity.preview, "Wrote a draft response")
        XCTAssertTrue(activity.isUnread)
    }

    @MainActor
    func testCapturedWorkingOutputClearsStaleNeedsInputPreview() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        harness.activity.recordAgentTerminalNotification(
            threadID: fixture.secondThreadID, title: "Claude is waiting",
            body: "Claude is waiting for your input")
        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.secondThreadID, output: "Claude is Thinking...\nEsc to interrupt\n")

        let activity = harness.activity.threadActivity(for: fixture.secondThreadID)
        XCTAssertEqual(activity.status, .working)
        XCTAssertNil(activity.preview)
        XCTAssertNil(activity.title)
        XCTAssertNil(activity.body)
        XCTAssertFalse(activity.isUnread)
    }

    @MainActor
    func testDuplicateCapturedActivityDoesNotPersistAgain() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID, output: "Thinking...\nEsc to interrupt\n")
        await harness.flush()
        let firstWriteCount = await harness.store.threadActivityWriteCount

        await harness.activity.recordAgentCLIOutput(
            threadID: fixture.firstThreadID, output: "Thinking...\nEsc to interrupt\n")
        await harness.flush()

        XCTAssertEqual(
            harness.activity.threadActivity(for: fixture.firstThreadID).status, .working)
        let secondWriteCount = await harness.store.threadActivityWriteCount
        XCTAssertEqual(secondWriteCount, firstWriteCount)
    }

    @MainActor
    func testDuplicateActivityReadDoesNotPersistAgain() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), isApplicationActive: { true })

        harness.activity.recordAgentTerminalNotification(
            threadID: fixture.firstThreadID, title: "Agent waiting", body: "Agent needs input")
        harness.activity.recordAgentTerminalFocus(threadID: fixture.firstThreadID, focused: true)
        await harness.flush()
        let firstReadWriteCount = await harness.store.threadActivityWriteCount

        harness.activity.recordAgentTerminalFocus(threadID: fixture.firstThreadID, focused: true)
        await harness.flush()

        XCTAssertFalse(harness.activity.threadActivity(for: fixture.firstThreadID).isUnread)
        let secondWriteCount = await harness.store.threadActivityWriteCount
        XCTAssertEqual(secondWriteCount, firstReadWriteCount)
    }

    @MainActor
    func testPersistedWorkingActivityDowngradesToInactiveOnLaunch() async {
        let fixture = StoreFixture()
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [
                    Project(
                        id: fixture.projectID, displayName: "Project", rootDirectory: fixture.root)
                ],
                threads: [
                    AgentThread(
                        id: fixture.firstThreadID, displayName: "First",
                        projectID: fixture.projectID,
                        workingDirectory: fixture.root)
                ],
                selectedProjectID: fixture.projectID,
                selectedThreadID: fixture.firstThreadID,
                rightPanelModesByThreadID: [fixture.firstThreadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false,
                threadActivityByThreadID: [
                    fixture.firstThreadID: ThreadActivityState(
                        threadID: fixture.firstThreadID, status: .working, preview: "Running",
                        isUnread: true, title: "Running", body: nil, source: .helper)
                ]
            ))
        let harness = await StoreHarnessBuilder.make(store: store)
        await harness.flush()

        XCTAssertEqual(
            harness.activity.threadActivity(for: fixture.firstThreadID).status, .inactive)
        XCTAssertFalse(harness.activity.threadActivity(for: fixture.firstThreadID).isUnread)
        let reloaded = await store.load()
        XCTAssertEqual(reloaded.threadActivityByThreadID[fixture.firstThreadID]?.status, .inactive)
    }

    @MainActor
    func testTerminalLifecycleEventsStillDriveThreadActivity() async {
        let fixture = StoreFixture()
        let harness = await StoreHarnessBuilder.make(store: fixture.makeStore())

        harness.activity.recordAgentCommandFinished(threadID: fixture.firstThreadID, exitCode: 0)
        var activity = harness.activity.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.preview, "Command exited with status 0")

        harness.activity.recordAgentTerminalClosed(threadID: fixture.firstThreadID)
        activity = harness.activity.threadActivity(for: fixture.firstThreadID)
        XCTAssertEqual(activity.status, .inactive)
        XCTAssertEqual(activity.preview, "Terminal closed")
    }

    @MainActor
    func testThreadActivitySortsProjectThreadsByRecentInteraction() async {
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = FileManager.default.temporaryDirectory
        let store = InMemoryYAAWStore(
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
                selectedRightPanelMode: .files, isGlobalTerminalExpanded: false))
        let harness = await StoreHarnessBuilder.make(store: store)

        XCTAssertEqual(
            harness.workspace.activeThreads(for: projectID).map(\.id),
            [secondThreadID, firstThreadID])

        harness.activity.recordAgentCommandFinished(threadID: firstThreadID, exitCode: 0)
        XCTAssertEqual(
            harness.workspace.activeThreads(for: projectID).map(\.id),
            [firstThreadID, secondThreadID])
        await harness.flush()
        let reloaded = await store.load()
        XCTAssertGreaterThan(
            reloaded.threads.first { $0.id == firstThreadID }?.lastOpenedAt
                ?? Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 20))
    }

    @MainActor
    func testAgentCLIMetadataRenameReordersCachedThreads() async {
        let projectID = UUID()
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let root = FileManager.default.temporaryDirectory
        let timestamp = Date(timeIntervalSince1970: 10)
        let store = InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: firstThreadID, displayName: "Bravo", projectID: projectID,
                        workingDirectory: root, agentCLI: .codex, createdAt: timestamp,
                        lastOpenedAt: timestamp),
                    AgentThread(
                        id: secondThreadID, displayName: "Charlie", projectID: projectID,
                        workingDirectory: root, agentCLI: .codex, createdAt: timestamp,
                        lastOpenedAt: timestamp),
                ],
                selectedProjectID: projectID, selectedThreadID: firstThreadID,
                selectedRightPanelMode: .files, isGlobalTerminalExpanded: false))
        let harness = await StoreHarnessBuilder.make(store: store)

        XCTAssertEqual(
            harness.workspace.activeThreads(for: projectID).map(\.id),
            [firstThreadID, secondThreadID])

        await harness.activity.recordAgentCLIOutput(
            threadID: secondThreadID,
            output: "session id: codex-session-222\nsession name: Alpha")

        XCTAssertEqual(
            harness.workspace.activeThreads(for: projectID).map(\.id),
            [secondThreadID, firstThreadID])
    }
}
