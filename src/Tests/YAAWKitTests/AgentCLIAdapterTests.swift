import XCTest
@testable import YAAWKit

final class AgentCLIAdapterTests: XCTestCase {
    func testResumeCommandConstructionUsesStoredIdentity() {
        let service = AgentCLISessionBindingService(
            resolver: StaticExecutableResolver(paths: ["codex": "/tmp/bin/codex"]),
            captureDirectory: nil
        )
        let thread = AgentThread(
            displayName: "Existing",
            projectID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory,
            agentCLI: .codex,
            sessionIdentity: "codex-session-123"
        )

        let command = service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/codex", "resume", "codex-session-123"])
    }

    func testMissingExecutableFallsBackToRawCommandNameForShellErrorOutput() {
        let service = AgentCLISessionBindingService(
            resolver: StaticExecutableResolver(paths: [:]),
            captureDirectory: nil
        )
        let thread = AgentThread(
            displayName: "Missing",
            projectID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory,
            agentCLI: .claude,
            sessionIdentity: "claude-session-123"
        )

        let command = service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["claude", "--resume", "claude-session-123"])
    }

    func testPATHResolverSearchesFallbackDirectoriesAfterProcessPath() throws {
        let root = try temporaryDirectory()
        let fallbackBin = root.appendingPathComponent("fallback-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fallbackBin, withIntermediateDirectories: true)
        let lazygit = fallbackBin.appendingPathComponent("lazygit")
        try writeExecutable(at: lazygit, contents: "#!/bin/sh\n")
        let resolver = PATHAgentCLIExecutableResolver(fallbackSearchPaths: [fallbackBin.path])

        let resolved = resolver.executablePath(
            named: "lazygit",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )

        XCTAssertEqual(resolved, lazygit.path)
    }

    func testPATHResolverPrefersProcessPathBeforeFallbackDirectories() throws {
        let root = try temporaryDirectory()
        let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
        let fallbackBin = root.appendingPathComponent("fallback-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackBin, withIntermediateDirectories: true)
        let pathTool = pathBin.appendingPathComponent("lazygit")
        try writeExecutable(at: pathTool, contents: "#!/bin/sh\n")
        try writeExecutable(at: fallbackBin.appendingPathComponent("lazygit"), contents: "#!/bin/sh\n")
        let resolver = PATHAgentCLIExecutableResolver(fallbackSearchPaths: [fallbackBin.path])

        let resolved = resolver.executablePath(named: "lazygit", environment: ["PATH": pathBin.path])

        XCTAssertEqual(resolved, pathTool.path)
    }

    func testClaudeResumeCommandUsesCurrentResumeFlag() {
        let service = AgentCLISessionBindingService(
            resolver: StaticExecutableResolver(paths: ["claude": "/tmp/bin/claude"]),
            captureDirectory: nil
        )
        let thread = AgentThread(
            displayName: "Existing",
            projectID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory,
            agentCLI: .claude,
            sessionIdentity: "claude-session-123"
        )

        let command = service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/claude", "--resume", "claude-session-123"])
    }

    func testOpenCodeResumeCommandUsesSessionFlag() {
        let service = AgentCLISessionBindingService(
            resolver: StaticExecutableResolver(paths: ["opencode": "/tmp/bin/opencode"]),
            captureDirectory: nil
        )
        let thread = AgentThread(
            displayName: "Existing",
            projectID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory,
            agentCLI: .opencode,
            sessionIdentity: "opencode-session-123"
        )

        let command = service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/opencode", "--session", "opencode-session-123"])
    }

    func testCopilotResumeCommandUsesEqualsResumeFlag() {
        let service = AgentCLISessionBindingService(
            resolver: StaticExecutableResolver(paths: ["copilot": "/tmp/bin/copilot"]),
            captureDirectory: nil
        )
        let thread = AgentThread(
            displayName: "Existing",
            projectID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory,
            agentCLI: .copilot,
            sessionIdentity: "copilot-session-123"
        )

        let command = service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/copilot", "--resume=copilot-session-123"])
    }

    func testCanonicalNamePrefersReportedNameThenTitleThenIdentity() throws {
        let service = AgentCLISessionBindingService(captureDirectory: nil)

        let named = try XCTUnwrap(
            service.metadata(
                for: .codex,
                output: """
                YAAW_SESSION_ID=codex-123
                YAAW_SESSION_NAME=Refactor Session
                YAAW_SESSION_TITLE=Terminal Title
                """
            )
        )
        XCTAssertEqual(named.canonicalName, "Refactor Session")

        let titled = try XCTUnwrap(
            service.metadata(
                for: .claude,
                output: """
                session id: claude-123
                title: Claude Terminal Title
                """
            )
        )
        XCTAssertEqual(titled.canonicalName, "Claude Terminal Title")

        let identityOnly = try XCTUnwrap(
            service.metadata(for: .codex, output: "session id: codex-identity-only")
        )
        XCTAssertEqual(identityOnly.canonicalName, "codex-identity-only")

        let opencode = try XCTUnwrap(
            service.metadata(for: .opencode, output: "opencode session id: opencode-123")
        )
        XCTAssertEqual(opencode.identity, "opencode-123")

        let copilot = try XCTUnwrap(
            service.metadata(for: .copilot, output: "copilot_session_id=copilot-123")
        )
        XCTAssertEqual(copilot.identity, "copilot-123")
    }

    func testMetadataParserIgnoresScriptTerminalControls() throws {
        let service = AgentCLISessionBindingService(captureDirectory: nil)

        let metadata = try XCTUnwrap(
            service.metadata(
                for: .codex,
                output: "\u{04}\u{08}\u{08}YAAW_SESSION_ID=codex-script-123\nYAAW_SESSION_NAME=Script Capture"
            )
        )

        XCTAssertEqual(metadata.identity, "codex-script-123")
        XCTAssertEqual(metadata.canonicalName, "Script Capture")
    }

    func testCommandDoublesExerciseLaunchCaptureAndResumeCapture() throws {
        let root = try temporaryDirectory()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
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
        let service = AgentCLISessionBindingService(captureDirectory: nil)
        let environment = ["PATH": bin.path]

        let launched = try service.captureMetadataByRunningCLI(
            kind: .codex,
            workingDirectory: root,
            environment: environment
        )
        let resumed = try service.captureMetadataByRunningCLI(
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

    func testTerminalCommandWrapsCLIWithCaptureLogWhenCaptureDirectoryIsConfigured() throws {
        let root = try temporaryDirectory()
        let helperBin = try temporaryDirectory()
        let helperURL = helperBin.appendingPathComponent("yaaw-notify")
        try "stale helper".write(to: helperURL, atomically: true, encoding: .utf8)
        let service = AgentCLISessionBindingService(
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

        let command = service.terminalCommand(for: thread)

        XCTAssertEqual(command[0], "/bin/zsh")
        XCTAssertEqual(command[1], "-lic")
        XCTAssertTrue(command[2].contains("/usr/bin/script -q"))
        XCTAssertTrue(command[2].contains(root.appendingPathComponent("\(thread.id.uuidString).log").path))
        XCTAssertTrue(command[2].contains("YAAW_THREAD_ID=\(thread.id.uuidString)"))
        XCTAssertTrue(command[2].contains("YAAW_PROJECT_ID=\(thread.projectID.uuidString)"))
        XCTAssertTrue(command[2].contains(root.appendingPathComponent("\(thread.id.uuidString).ndjson").path))
        XCTAssertTrue(command[2].contains(helperBin.path))
        XCTAssertTrue(command[2].contains("/tmp/bin/claude"))
        XCTAssertTrue(command[2].contains("yaaw_exit_status=$?"))
        XCTAssertFalse(command[2].contains("; status=$?"))
        XCTAssertTrue(command[2].contains("exec /bin/zsh -l"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperURL.path))
        XCTAssertTrue(try String(contentsOf: helperURL, encoding: .utf8).contains("]777;notify"))
    }

    func testCapturedOutputReadsOnlyAppendedBytes() throws {
        let root = try temporaryDirectory()
        let service = AgentCLISessionBindingService(captureDirectory: root)
        let thread = AgentThread(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            displayName: "Codex",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex
        )
        let captureLogURL = try XCTUnwrap(service.captureLogURL(for: thread))
        try "first\n".write(to: captureLogURL, atomically: true, encoding: .utf8)

        let first = try XCTUnwrap(service.capturedOutput(for: thread, after: 0))
        try FileHandle(forWritingTo: captureLogURL).closeAfterAppending("second\n")
        let second = try XCTUnwrap(service.capturedOutput(for: thread, after: first.nextOffset))

        XCTAssertEqual(first.output, "first\n")
        XCTAssertEqual(first.startOffset, 0)
        XCTAssertEqual(second.output, "second\n")
        XCTAssertEqual(second.startOffset, first.nextOffset)
    }

    func testStaleCapturedOutputClampsRecoveryOffsetWhenMaxBytesExceedsFileSize() throws {
        let root = try temporaryDirectory()
        let service = AgentCLISessionBindingService(captureDirectory: root)
        let thread = AgentThread(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            displayName: "Codex",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex
        )
        let captureLogURL = try XCTUnwrap(service.captureLogURL(for: thread))
        try "first\n".write(to: captureLogURL, atomically: true, encoding: .utf8)
        let fileHandle = try FileHandle(forWritingTo: captureLogURL)
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: AgentCLISessionBindingService.captureLogStaleWindow + 1)

        let captured = try XCTUnwrap(
            service.capturedOutput(
                for: thread,
                after: 0,
                maxBytes: Int(AgentCLISessionBindingService.captureLogStaleWindow + 2)
            )
        )

        XCTAssertEqual(captured.startOffset, 0)
        XCTAssertTrue(captured.output.hasPrefix("first\n"))
    }

    func testNotifyHelperWritesActivityEventAndTerminalNotification() throws {
        let root = try temporaryDirectory()
        let helperBin = try temporaryDirectory()
        let service = AgentCLISessionBindingService(
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
        _ = service.terminalCommand(for: thread)
        let helperURL = helperBin.appendingPathComponent("yaaw-notify")
        let eventLogURL = root.appendingPathComponent("activity.ndjson")
        let stdout = Pipe()
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--status", "needs-input",
            "--title", "Needs \"quote\"",
            "--body", "Approve command"
        ]
        process.environment = [
            "YAAW_THREAD_ID": thread.id.uuidString,
            "YAAW_EVENT_LOG": eventLogURL.path
        ]
        process.standardOutput = stdout

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let log = try String(contentsOf: eventLogURL, encoding: .utf8)
        let event = try XCTUnwrap(ThreadActivityEvent.helperEvents(from: log).first)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("\u{001B}]777;notify;Needs \"quote\";Approve command\u{0007}"))
        XCTAssertEqual(event.threadID, thread.id)
        XCTAssertEqual(event.status, .needsInput)
        XCTAssertEqual(event.title, "Needs \"quote\"")
        XCTAssertEqual(event.body, "Approve command")
    }

    func testCapturedMetadataPersistsThroughSQLiteReload() throws {
        let path = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let projectID = UUID()
        let threadID = UUID()
        let root = try temporaryDirectory()
        store.save(
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
        let captureDirectory = try temporaryDirectory()
        let service = AgentCLISessionBindingService(captureDirectory: captureDirectory)
        let model = AppModel(store: store, agentCLIBindings: service)
        let selectedThread = try XCTUnwrap(model.selectedThread)
        let captureLogURL = try XCTUnwrap(service.captureLogURL(for: selectedThread))
        try """
        session id: codex-session-456
        session name: Stored Codex Session
        """.write(to: captureLogURL, atomically: true, encoding: .utf8)

        model.pollSelectedAgentCLICaptureLog()

        let reloaded = try SQLiteYAAWStore(databasePath: path).load()
        let reloadedThread = try XCTUnwrap(reloaded.threads.first { $0.id == threadID })
        XCTAssertEqual(reloadedThread.sessionIdentity, "codex-session-456")
        XCTAssertEqual(reloadedThread.canonicalSessionName, "Stored Codex Session")
        XCTAssertEqual(reloadedThread.displayName, "Stored Codex Session")
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

private struct StaticExecutableResolver: AgentCLIExecutableResolving {
    let paths: [String: String]

    func executablePath(named executableName: String, environment: [String: String]) -> String? {
        paths[executableName]
    }
}

private extension FileHandle {
    func closeAfterAppending(_ text: String) throws {
        defer { try? close() }
        try seekToEnd()
        try write(contentsOf: Data(text.utf8))
    }
}
