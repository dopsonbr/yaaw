import XCTest

@testable import YAAWKit

/// Session-linking + terminal-launch-descriptor parity, re-pointed from
/// `AppModelTests` onto `WorkspaceStore` + `SessionBindingActor`. The pre-rewrite
/// `terminalLaunchRequest(for:)` is now `surfaceLaunch(for:)`, returning a
/// `RenderSurfaceLaunch` whose `command` is the agent PTY command.
final class SessionLinkingTests: XCTestCase {
    @MainActor
    private func singleThreadStore(
        threadID: UUID, projectID: UUID, root: URL, displayName: String, agentCLI: AgentCLIKind,
        sessionIdentity: String? = nil, canonicalSessionName: String? = nil,
        pendingSessionRename: String? = nil
    ) -> InMemoryYAAWStore {
        InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID, displayName: displayName, projectID: projectID,
                        workingDirectory: root, agentCLI: agentCLI,
                        sessionIdentity: sessionIdentity,
                        canonicalSessionName: canonicalSessionName,
                        pendingSessionRename: pendingSessionRename)
                ],
                selectedProjectID: projectID, selectedThreadID: threadID,
                selectedRightPanelMode: .files, isGlobalTerminalExpanded: false))
    }

    @MainActor
    func testStoredIdentityLaunchesResumeAfterReload() async throws {
        let fixture = StoreFixture()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["codex": "/tmp/bin/codex"]),
            captureDirectory: nil)
        let store = singleThreadStore(
            threadID: fixture.firstThreadID, projectID: fixture.projectID, root: fixture.root,
            displayName: "Existing", agentCLI: .codex, sessionIdentity: "codex-resume-1",
            canonicalSessionName: "Existing")
        let harness = await StoreHarnessBuilder.make(
            store: store, sessionBindingActor: service)

        let launchResult = await harness.workspace.surfaceLaunch(
            for: .project(threadID: fixture.firstThreadID))
        let launch = try XCTUnwrap(launchResult)
        XCTAssertTrue(launch.command[2].contains("/tmp/bin/codex resume codex-resume-1"))
    }

    @MainActor
    func testLoadedUnboundThreadRequiresExplicitLinkOrNewSession() async throws {
        let fixture = StoreFixture()
        let home = try storeTemporaryDirectory()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["codex": "/tmp/bin/codex"]),
            captureDirectory: nil, homeDirectory: home)
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), sessionBindingActor: service,
            requiresSessionLinkForLoadedUnboundThreads: true)

        XCTAssertTrue(harness.workspace.selectedThreadRequiresSessionLink)
        let blocked = await harness.workspace.surfaceLaunch(
            for: .project(threadID: fixture.firstThreadID))
        XCTAssertNil(blocked)

        harness.workspace.startNewSessionForUnlinkedThread(threadID: fixture.firstThreadID)
        let launchResult = await harness.workspace.surfaceLaunch(
            for: .project(threadID: fixture.firstThreadID))
        let launch = try XCTUnwrap(launchResult)
        XCTAssertFalse(harness.workspace.selectedThreadRequiresSessionLink)
        XCTAssertTrue(launch.command[2].contains("/tmp/bin/codex"))
    }

    @MainActor
    func testLoadedUnboundCodexThreadAutoLinksExactNameAndResumes() async throws {
        let fixture = StoreFixture()
        let home = try storeTemporaryDirectory()
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"codex-1","thread_name":"rename-test","cwd":"\(fixture.root.path)","updated_at":"2026-05-26T10:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"), atomically: true,
            encoding: .utf8)
        let store = singleThreadStore(
            threadID: fixture.firstThreadID, projectID: fixture.projectID, root: fixture.root,
            displayName: "rename-test", agentCLI: .codex, pendingSessionRename: "rename-test")
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["codex": "/tmp/bin/codex"]),
            captureDirectory: nil, homeDirectory: home)
        let harness = await StoreHarnessBuilder.make(
            store: store, sessionBindingActor: service,
            requiresSessionLinkForLoadedUnboundThreads: true)

        let launchResult = await harness.workspace.surfaceLaunch(
            for: .project(threadID: fixture.firstThreadID))
        let launch = try XCTUnwrap(launchResult)
        await harness.flush()
        let reloaded = await store.load()
        let reloadedThread = try XCTUnwrap(
            reloaded.threads.first { $0.id == fixture.firstThreadID })

        XCTAssertFalse(harness.workspace.selectedThreadRequiresSessionLink)
        XCTAssertTrue(launch.command[2].contains("/tmp/bin/codex resume codex-1"))
        XCTAssertEqual(reloadedThread.sessionIdentity, "codex-1")
        XCTAssertEqual(reloadedThread.canonicalSessionName, "rename-test")
        XCTAssertEqual(reloadedThread.displayName, "rename-test")
        XCTAssertNil(reloadedThread.pendingSessionRename)
    }

    @MainActor
    func testLoadedUnboundThreadRequiresLinkWhenExactNameIsAmbiguous() async throws {
        let fixture = StoreFixture()
        let home = try storeTemporaryDirectory()
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"codex-1","thread_name":"rename-test","cwd":"\(fixture.root.path)","updated_at":"2026-05-26T10:00:00Z"}
        {"id":"codex-2","thread_name":"rename-test","cwd":"\(fixture.root.path)","updated_at":"2026-05-26T11:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"), atomically: true,
            encoding: .utf8)
        let store = singleThreadStore(
            threadID: fixture.firstThreadID, projectID: fixture.projectID, root: fixture.root,
            displayName: "rename-test", agentCLI: .codex, pendingSessionRename: "rename-test")
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["codex": "/tmp/bin/codex"]),
            captureDirectory: nil, homeDirectory: home)
        let harness = await StoreHarnessBuilder.make(
            store: store, sessionBindingActor: service,
            requiresSessionLinkForLoadedUnboundThreads: true)

        XCTAssertTrue(harness.workspace.selectedThreadRequiresSessionLink)
        let blocked = await harness.workspace.surfaceLaunch(
            for: .project(threadID: fixture.firstThreadID))
        XCTAssertNil(blocked)
    }

    @MainActor
    func testSelectedUnboundNamedThreadSyncAutoLinksExactCatalogMetadata() async throws {
        let fixture = StoreFixture()
        let home = try storeTemporaryDirectory()
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"codex-1","thread_name":"rename-test","cwd":"\(fixture.root.path)","updated_at":"2026-05-26T10:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"), atomically: true,
            encoding: .utf8)
        let store = singleThreadStore(
            threadID: fixture.firstThreadID, projectID: fixture.projectID, root: fixture.root,
            displayName: "rename-test", agentCLI: .codex, pendingSessionRename: "rename-test")
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let harness = await StoreHarnessBuilder.make(
            store: store, sessionBindingActor: service,
            requiresSessionLinkForLoadedUnboundThreads: false)

        await harness.workspace.syncSelectedThreadSessionMetadata()
        await harness.flush()
        let reloaded = await store.load()
        let reloadedThread = try XCTUnwrap(
            reloaded.threads.first { $0.id == fixture.firstThreadID })

        XCTAssertFalse(harness.workspace.selectedThreadRequiresSessionLink)
        XCTAssertEqual(reloadedThread.sessionIdentity, "codex-1")
        XCTAssertNil(reloadedThread.pendingSessionRename)
    }

    @MainActor
    func testStartNewSessionSkipsExactAutoLinkDuringCurrentRun() async throws {
        let fixture = StoreFixture()
        let home = try storeTemporaryDirectory()
        let store = singleThreadStore(
            threadID: fixture.firstThreadID, projectID: fixture.projectID, root: fixture.root,
            displayName: "rename-test", agentCLI: .codex, pendingSessionRename: "rename-test")
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let harness = await StoreHarnessBuilder.make(
            store: store, sessionBindingActor: service,
            requiresSessionLinkForLoadedUnboundThreads: true)

        XCTAssertTrue(harness.workspace.selectedThreadRequiresSessionLink)
        harness.workspace.startNewSessionForUnlinkedThread(threadID: fixture.firstThreadID)

        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"codex-1","thread_name":"rename-test","updated_at":"2026-05-26T10:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"), atomically: true,
            encoding: .utf8)
        await harness.workspace.syncSelectedThreadSessionMetadata()
        await harness.flush()

        let reloaded = await store.load()
        let reloadedThread = try XCTUnwrap(
            reloaded.threads.first { $0.id == fixture.firstThreadID })
        XCTAssertFalse(harness.workspace.selectedThreadRequiresSessionLink)
        XCTAssertNil(reloadedThread.sessionIdentity)
        XCTAssertEqual(reloadedThread.pendingSessionRename, "rename-test")
    }

    @MainActor
    func testLinkSelectionPersistsSessionIdentityAndName() async throws {
        let fixture = StoreFixture()
        let home = try storeTemporaryDirectory()
        let store = singleThreadStore(
            threadID: fixture.firstThreadID, projectID: fixture.projectID, root: fixture.root,
            displayName: "Pending", agentCLI: .codex, pendingSessionRename: "Pending")
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let harness = await StoreHarnessBuilder.make(
            store: store, sessionBindingActor: service,
            requiresSessionLinkForLoadedUnboundThreads: true)
        let candidate = SessionLinkCandidate(
            identity: "codex-linked-1", displayName: "Linked Codex", agentCLI: .codex,
            workingDirectory: fixture.root, source: "fixture")

        harness.workspace.linkSession(threadID: fixture.firstThreadID, candidate: candidate)
        await harness.flush()
        let reloaded = await store.load()
        let reloadedThread = try XCTUnwrap(
            reloaded.threads.first { $0.id == fixture.firstThreadID })

        XCTAssertFalse(harness.workspace.selectedThreadRequiresSessionLink)
        XCTAssertEqual(reloadedThread.sessionIdentity, "codex-linked-1")
        XCTAssertEqual(reloadedThread.displayName, "Linked Codex")
        XCTAssertEqual(reloadedThread.canonicalSessionName, "Linked Codex")
        XCTAssertNil(reloadedThread.pendingSessionRename)
    }

    @MainActor
    func testProjectTerminalRequestsUseAgentPTYForEverySupportedAgentCLI() async throws {
        let fixture = StoreFixture()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(
                paths: Dictionary(
                    uniqueKeysWithValues: AgentCLIKind.allCases.map {
                        ($0.rawValue, "/tmp/bin/\($0.rawValue)")
                    })),
            captureDirectory: nil)
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), sessionBindingActor: service)

        for kind in AgentCLIKind.allCases {
            let threadID = try harness.workspace.createThread(agentCLI: kind)
            let launchResult = await harness.workspace.surfaceLaunch(
                for: .project(threadID: threadID))
            let launch = try XCTUnwrap(launchResult)
            XCTAssertTrue(launch.isAgentPTY)
            XCTAssertTrue(launch.command[2].contains("/tmp/bin/\(kind.rawValue)"))
            XCTAssertFalse(launch.command[2].contains("/usr/bin/script"))
        }
    }

    @MainActor
    func testConfiguredAgentExecutableNameIsUsedForProjectTerminal() async throws {
        let fixture = StoreFixture()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["codex-nightly": "/tools/codex-nightly"]),
            captureDirectory: nil)
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), sessionBindingActor: service,
            configuration: YAAWConfiguration(
                tools: ToolSettings(agents: AgentToolSettings(codex: "codex-nightly"))))

        let launchResult = await harness.workspace.surfaceLaunch(
            for: .project(threadID: fixture.firstThreadID))
        let launch = try XCTUnwrap(launchResult)
        XCTAssertTrue(launch.isAgentPTY)
        XCTAssertTrue(launch.command[2].contains("/tools/codex-nightly"))
    }

    @MainActor
    func testThreadLaunchOptionsOverrideExecutableAndApplyArguments() async throws {
        let fixture = StoreFixture()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["codex-beta": "/tools/codex-beta"]),
            captureDirectory: nil)
        let harness = await StoreHarnessBuilder.make(
            store: fixture.makeStore(), sessionBindingActor: service)

        let threadID = try harness.workspace.createThread(
            agentCLI: .codex,
            launchOptions: AgentLaunchOptions(
                executableName: "codex-beta", permissionModeID: "codex-never",
                additionalArguments: ["--model", "gpt-5"]))
        let thread = try XCTUnwrap(harness.workspace.threads.first { $0.id == threadID })
        XCTAssertEqual(thread.launchOptions.executableName, "codex-beta")
        XCTAssertEqual(thread.launchOptions.permissionModeID, "codex-never")
        XCTAssertEqual(thread.launchOptions.additionalArguments, ["--model", "gpt-5"])

        let launchResult = await harness.workspace.surfaceLaunch(
            for: .project(threadID: threadID))
        let launch = try XCTUnwrap(launchResult)
        XCTAssertTrue(
            launch.command[2].contains("/tools/codex-beta --ask-for-approval never --model gpt-5"))
    }

    @MainActor
    func testMissingSelectedThreadDirectoryReportsStateAndBlocksTerminals() async throws {
        let recorder = RecordingDiagnosticEventRecorder()
        let root = try storeTemporaryDirectory()
        try FileManager.default.removeItem(at: root)
        let projectID = UUID()
        let threadID = UUID()
        let harness = await StoreHarnessBuilder.make(
            store: InMemoryYAAWStore(
                snapshot: YAAWSnapshot(
                    projects: [Project(id: projectID, displayName: "Missing", rootDirectory: root)],
                    threads: [
                        AgentThread(
                            id: threadID, displayName: "Missing Thread", projectID: projectID,
                            workingDirectory: root)
                    ],
                    selectedProjectID: projectID, selectedThreadID: threadID,
                    rightPanelModesByThreadID: [threadID: .files], selectedRightPanelMode: .files,
                    isGlobalTerminalExpanded: false)),
            diagnosticRecorder: recorder)

        XCTAssertEqual(harness.workspace.selectedProjectDirectoryState, .missing(path: root.path))
        XCTAssertEqual(
            harness.workspace.selectedThreadWorkingDirectoryState, .missing(path: root.path))
        let launch = await harness.workspace.surfaceLaunch(for: .project(threadID: threadID))
        XCTAssertNil(launch)

        harness.activity.refreshSelectedFileBrowser()
        await harness.flush()

        XCTAssertEqual(harness.activity.fileBrowserState.rootPath, root.path)
        XCTAssertEqual(
            harness.activity.fileBrowserState.errorMessage,
            "Missing working directory: \(root.path)")
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Terminal" && $0.name == "terminal_launch_failed"
                    && $0.metadata["reason"] == "missing_working_directory"
            })
        XCTAssertTrue(
            recorder.events.contains {
                $0.category == "Indexing" && $0.name == "file_index_failed"
                    && $0.metadata["reason"] == "missing_root"
            })
    }
}
