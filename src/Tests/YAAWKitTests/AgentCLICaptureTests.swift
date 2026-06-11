import Darwin
import XCTest

@testable import YAAWKit

/// Metadata-parse, launch-descriptor, capture-log, notify-helper, and
/// persistence-roundtrip tests for `SessionBindingActor`. Ported from the legacy
/// `AgentCLIAdapterTests`; calls re-pointed at the async actor API.
final class AgentCLICaptureTests: XCTestCase {
    func testCanonicalNamePrefersReportedNameThenTitleThenIdentity() async throws {
        let service = SessionBindingActor(captureDirectory: nil)

        let named = try unwrapAsync(
            await service.metadata(
                for: .codex,
                output: """
                    YAAW_SESSION_ID=codex-123
                    YAAW_SESSION_NAME=Refactor Session
                    YAAW_SESSION_TITLE=Terminal Title
                    """
            )
        )
        XCTAssertEqual(named.canonicalName, "Refactor Session")

        let titled = try unwrapAsync(
            await service.metadata(
                for: .claude,
                output: """
                    session id: claude-123
                    title: Claude Terminal Title
                    """
            )
        )
        XCTAssertEqual(titled.canonicalName, "Claude Terminal Title")

        let identityOnly = try unwrapAsync(
            await service.metadata(for: .codex, output: "session id: codex-identity-only")
        )
        XCTAssertEqual(identityOnly.canonicalName, "codex-identity-only")

        let opencode = try unwrapAsync(
            await service.metadata(for: .opencode, output: "opencode session id: opencode-123")
        )
        XCTAssertEqual(opencode.identity, "opencode-123")

        let copilot = try unwrapAsync(
            await service.metadata(for: .copilot, output: "copilot_session_id=copilot-123")
        )
        XCTAssertEqual(copilot.identity, "copilot-123")
    }

    func testMetadataParserIgnoresScriptTerminalControls() async throws {
        let service = SessionBindingActor(captureDirectory: nil)

        let metadata = try unwrapAsync(
            await service.metadata(
                for: .codex,
                output:
                    "\u{04}\u{08}\u{08}YAAW_SESSION_ID=codex-script-123\nYAAW_SESSION_NAME=Script Capture"
            )
        )

        XCTAssertEqual(metadata.identity, "codex-script-123")
        XCTAssertEqual(metadata.canonicalName, "Script Capture")
    }

    func testCommandDoublesExerciseLaunchCaptureAndResumeCapture() async throws {
        let root = try makeTemporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutableFile(
            at: bin.appendingPathComponent("codex"),
            contents: """
                #!/bin/sh
                if [ "$1" = "resume" ]; then
                  printf 'YAAW_SESSION_ID=%s\\n' "$2"
                  printf 'YAAW_SESSION_NAME=Codex Resumed\\n'
                else
                  printf 'YAAW_SESSION_ID=codex-new-123\\n'
                  printf 'YAAW_SESSION_NAME=Codex New\\n'
                fi
                """
        )
        let service = SessionBindingActor(captureDirectory: nil)
        let environment = ["PATH": bin.path]

        let launched = try await service.captureMetadataByRunningCLI(
            kind: .codex,
            workingDirectory: root,
            environment: environment
        )
        let resumed = try await service.captureMetadataByRunningCLI(
            kind: .codex,
            resumeIdentity: launched.identity,
            workingDirectory: root,
            environment: environment
        )

        XCTAssertEqual(launched.identity, "codex-new-123")
        XCTAssertEqual(launched.canonicalName, "Codex New")
        XCTAssertEqual(resumed.identity, "codex-new-123")
        XCTAssertEqual(resumed.canonicalName, "Codex Resumed")
    }

    func testTerminalLaunchDescriptorUsesShellWithoutNestedScriptWhenCaptureIsConfigured()
        async throws
    {
        let root = try makeTemporaryDirectory()
        let helperBin = try makeTemporaryDirectory()
        let helperURL = helperBin.appendingPathComponent("yaaw-notify")
        try "stale helper".write(to: helperURL, atomically: true, encoding: .utf8)
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["claude": "/tmp/bin/claude"]),
            environment: ["SHELL": "/bin/zsh"],
            captureDirectory: root,
            activityDirectory: root,
            helperBinDirectory: helperBin
        )
        let thread = AgentThread(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            displayName: "Claude",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .claude
        )

        let launch = await service.terminalLaunchDescriptor(for: thread)

        XCTAssertEqual(launch.command[0], "/bin/zsh")
        XCTAssertEqual(launch.command[1], "-lic")
        XCTAssertFalse(launch.command[2].contains("/usr/bin/script"))
        XCTAssertEqual(
            launch.captureLogURL,
            root.appendingPathComponent("\(thread.id.uuidString).log"))
        XCTAssertEqual(launch.environment["YAAW_THREAD_ID"], thread.id.uuidString)
        XCTAssertEqual(launch.environment["YAAW_PROJECT_ID"], thread.projectID.uuidString)
        XCTAssertEqual(
            launch.environment["YAAW_EVENT_LOG"],
            root.appendingPathComponent("\(thread.id.uuidString).ndjson").path)
        let launchPath = try XCTUnwrap(launch.environment["PATH"])
        XCTAssertEqual(launchPath.split(separator: ":").first.map(String.init), helperBin.path)
        XCTAssertEqual(launch.environment["TERM"], "xterm-256color")
        XCTAssertEqual(launch.environment["COLORTERM"], "truecolor")
        XCTAssertEqual(launch.environment["TERM_PROGRAM"], "YAAW")
        XCTAssertTrue(launch.command[2].contains("/tmp/bin/claude"))
        XCTAssertTrue(launch.command[2].contains("yaaw_exit_status=$?"))
        XCTAssertFalse(launch.command[2].contains("; status=$?"))
        XCTAssertTrue(launch.command[2].contains("trap 'exit 143' TERM"))
        XCTAssertTrue(launch.command[2].contains("exec /bin/zsh -l"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperURL.path))
        XCTAssertTrue(try String(contentsOf: helperURL, encoding: .utf8).contains("]777;notify"))
    }

    func testTerminalLaunchDescriptorAvoidsNestedScriptForEveryAgentCLI() async throws {
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: [
                "codex": "/tmp/bin/codex",
                "claude": "/tmp/bin/claude",
                "opencode": "/tmp/bin/opencode",
                "copilot": "/tmp/bin/copilot",
            ]),
            environment: ["SHELL": "/bin/zsh", "PATH": "/tmp/bin"],
            captureDirectory: root,
            activityDirectory: root,
            helperBinDirectory: try makeTemporaryDirectory()
        )

        for kind in AgentCLIKind.allCases {
            let thread = AgentThread(
                displayName: kind.displayName,
                projectID: UUID(),
                workingDirectory: root,
                agentCLI: kind,
                sessionIdentity: "\(kind.rawValue)-session"
            )

            let launch = await service.terminalLaunchDescriptor(for: thread)

            XCTAssertFalse(launch.command.joined(separator: " ").contains("/usr/bin/script"))
            XCTAssertTrue(launch.command[2].contains("/tmp/bin/\(kind.rawValue)"))
            XCTAssertEqual(launch.environment["YAAW_THREAD_ID"], thread.id.uuidString)
            XCTAssertEqual(launch.captureLogURL?.lastPathComponent, "\(thread.id.uuidString).log")
        }
    }

    func testCapturedOutputReadsOnlyAppendedBytes() async throws {
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: root)
        let thread = AgentThread(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            displayName: "Codex",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex
        )
        let captureLogURL = try unwrapAsync(await service.captureLogURL(for: thread))
        try "first\n".write(to: captureLogURL, atomically: true, encoding: .utf8)

        let first = try unwrapAsync(await service.capturedOutput(for: thread, after: 0))
        try FileHandle(forWritingTo: captureLogURL).closeAfterAppending("second\n")
        let second = try unwrapAsync(
            await service.capturedOutput(for: thread, after: first.nextOffset))

        XCTAssertEqual(first.output, "first\n")
        XCTAssertEqual(first.startOffset, 0)
        XCTAssertEqual(second.output, "second\n")
        XCTAssertEqual(second.startOffset, first.nextOffset)
    }

    func testStaleCapturedOutputClampsRecoveryOffsetWhenMaxBytesExceedsFileSize() async throws {
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: root)
        let thread = AgentThread(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            displayName: "Codex",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex
        )
        let captureLogURL = try unwrapAsync(await service.captureLogURL(for: thread))
        try "first\n".write(to: captureLogURL, atomically: true, encoding: .utf8)
        let fileHandle = try FileHandle(forWritingTo: captureLogURL)
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: SessionBindingActor.captureLogStaleWindow + 1)

        let captured = try unwrapAsync(
            await service.capturedOutput(
                for: thread,
                after: 0,
                maxBytes: Int(SessionBindingActor.captureLogStaleWindow + 2)
            )
        )

        XCTAssertEqual(captured.startOffset, 0)
        XCTAssertTrue(captured.output.hasPrefix("first\n"))
    }

    func testCapturedOutputRecoversAfterCaptureLogRotation() async throws {
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: root)
        let thread = AgentThread(
            id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            displayName: "Codex",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex
        )
        let captureLogURL = try unwrapAsync(await service.captureLogURL(for: thread))
        try "rotated\n".write(to: captureLogURL, atomically: true, encoding: .utf8)

        let captured = try unwrapAsync(await service.capturedOutput(for: thread, after: 1024))

        XCTAssertEqual(captured.output, "rotated\n")
        XCTAssertEqual(captured.startOffset, 0)
    }

    func testNotifyHelperWritesActivityEventAndTerminalNotification() async throws {
        let root = try makeTemporaryDirectory()
        let helperBin = try makeTemporaryDirectory()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["codex": "/tmp/bin/codex"]),
            environment: ["SHELL": "/bin/zsh"],
            captureDirectory: root,
            activityDirectory: root,
            helperBinDirectory: helperBin
        )
        let thread = AgentThread(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            displayName: "Codex",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex
        )
        _ = await service.terminalCommand(for: thread)
        let helperURL = helperBin.appendingPathComponent("yaaw-notify")
        let eventLogURL = root.appendingPathComponent("activity.ndjson")
        let stdout = Pipe()
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--status", "needs-input",
            "--title", "Needs \"quote\"",
            "--body", "Approve command",
        ]
        process.environment = [
            "YAAW_THREAD_ID": thread.id.uuidString,
            "YAAW_EVENT_LOG": eventLogURL.path,
        ]
        process.standardOutput = stdout

        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let log = try String(contentsOf: eventLogURL, encoding: .utf8)
        let event = try XCTUnwrap(ThreadActivityEvent.helperEvents(from: log).first)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(
            output.contains("\u{001B}]777;notify;Needs \"quote\";Approve command\u{0007}"))
        XCTAssertEqual(event.threadID, thread.id)
        XCTAssertEqual(event.status, .needsInput)
        XCTAssertEqual(event.title, "Needs \"quote\"")
        XCTAssertEqual(event.body, "Approve command")
    }

    func testCapturedMetadataPersistsThroughSQLiteReload() async throws {
        let path = try makeTemporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = try makeTemporaryDirectory()
        await store.save(
            YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: threadID,
                        displayName: "New codex thread",
                        projectID: projectID,
                        workingDirectory: root,
                        agentCLI: .codex
                    )
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        let captureDirectory = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: captureDirectory)
        let snapshot = await store.load()
        let selectedThread = try XCTUnwrap(snapshot.threads.first { $0.id == threadID })
        let captureLogURL = try unwrapAsync(await service.captureLogURL(for: selectedThread))
        try """
        session id: codex-session-456
        session name: Stored Codex Session
        """.write(to: captureLogURL, atomically: true, encoding: .utf8)

        // Reproduce the pollSelectedAgentCLICaptureLog behavior (Chunk E owns the
        // store-driven loop): read the captured output, parse metadata, fold it
        // into the thread, and persist.
        let captured = try unwrapAsync(
            await service.capturedOutput(for: selectedThread, after: 0))
        let metadata = try unwrapAsync(
            await service.metadata(for: .codex, output: captured.output))
        var updated = selectedThread
        updated.sessionIdentity = metadata.identity
        updated.canonicalSessionName = metadata.canonicalName
        updated.displayName = metadata.canonicalName
        await store.upsertThread(updated)

        let reloaded = try await SQLiteYAAWStore(databasePath: path).load()
        let reloadedThread = try XCTUnwrap(reloaded.threads.first { $0.id == threadID })
        XCTAssertEqual(reloadedThread.sessionIdentity, "codex-session-456")
        XCTAssertEqual(reloadedThread.canonicalSessionName, "Stored Codex Session")
        XCTAssertEqual(reloadedThread.displayName, "Stored Codex Session")
    }
}
