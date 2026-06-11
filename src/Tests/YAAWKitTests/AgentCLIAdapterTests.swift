import Darwin
import XCTest

@testable import YAAWKit

/// Behavior-parity tests for the manifest-driven `SessionBindingActor`. Ported
/// from the legacy `AgentCLIAdapterTests`; the assertions are preserved while the
/// calls are re-pointed at the async actor API (`await`).
final class AgentCLIAdapterTests: XCTestCase {
    func testResumeCommandConstructionUsesStoredIdentity() async {
        let service = SessionBindingActor(
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

        let command = await service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/codex", "resume", "codex-session-123"])
    }

    func testLaunchOptionsPrependPermissionAndAdditionalArgumentsBeforeResume() async {
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["codex-beta": "/tmp/bin/codex-beta"]),
            captureDirectory: nil
        )
        let thread = AgentThread(
            displayName: "Existing",
            projectID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory,
            agentCLI: .codex,
            launchOptions: AgentLaunchOptions(
                executableName: "codex-beta",
                permissionModeID: "codex-on-request",
                additionalArguments: ["--model", "gpt-5"]
            ),
            sessionIdentity: "codex-session-123"
        )

        let command = await service.terminalCommand(for: thread)

        XCTAssertEqual(
            command,
            [
                "/tmp/bin/codex-beta",
                "--ask-for-approval",
                "on-request",
                "--model",
                "gpt-5",
                "resume",
                "codex-session-123",
            ]
        )
    }

    func testLaunchOptionsIgnoreUnsupportedPermissionModeForAgent() async {
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["opencode": "/tmp/bin/opencode"]),
            captureDirectory: nil
        )
        let thread = AgentThread(
            displayName: "OpenCode",
            projectID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory,
            agentCLI: .opencode,
            launchOptions: AgentLaunchOptions(
                permissionModeID: "codex-on-request",
                additionalArguments: ["--model", "anthropic/claude-sonnet-4"]
            )
        )

        let command = await service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/opencode", "--model", "anthropic/claude-sonnet-4"])
    }

    func testLaunchOptionsArgumentParserSupportsQuotesAndEscapes() throws {
        let arguments = try AgentLaunchOptions.parseAdditionalArguments(
            #"--model gpt-5 --profile "Work Profile" '--flag=value' escaped\ value"#
        )

        XCTAssertEqual(
            arguments,
            ["--model", "gpt-5", "--profile", "Work Profile", "--flag=value", "escaped value"]
        )
    }

    func testLaunchOptionsArgumentParserRejectsUnclosedQuote() {
        XCTAssertThrowsError(
            try AgentLaunchOptions.parseAdditionalArguments(#"--model "gpt 5"#)
        ) { error in
            XCTAssertEqual(error as? AgentLaunchOptionsArgumentError, .unclosedQuote)
        }
    }

    func testMissingExecutableFallsBackToRawCommandNameForShellErrorOutput() async {
        let service = SessionBindingActor(
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

        let command = await service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["claude", "--resume", "claude-session-123"])
    }

    func testPATHResolverSearchesFallbackDirectoriesAfterProcessPath() throws {
        let root = try makeTemporaryDirectory()
        let fallbackBin = root.appendingPathComponent("fallback-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fallbackBin, withIntermediateDirectories: true)
        let lazygit = fallbackBin.appendingPathComponent("lazygit")
        try writeExecutableFile(at: lazygit, contents: "#!/bin/sh\n")
        let resolver = PATHAgentCLIExecutableResolver(fallbackSearchPaths: [fallbackBin.path])

        let resolved = resolver.executablePath(
            named: "lazygit",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )

        XCTAssertEqual(resolved, lazygit.path)
    }

    func testPATHResolverPrefersProcessPathBeforeFallbackDirectories() throws {
        let root = try makeTemporaryDirectory()
        let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
        let fallbackBin = root.appendingPathComponent("fallback-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackBin, withIntermediateDirectories: true)
        let pathTool = pathBin.appendingPathComponent("lazygit")
        try writeExecutableFile(at: pathTool, contents: "#!/bin/sh\n")
        try writeExecutableFile(
            at: fallbackBin.appendingPathComponent("lazygit"), contents: "#!/bin/sh\n")
        let resolver = PATHAgentCLIExecutableResolver(fallbackSearchPaths: [fallbackBin.path])

        let resolved = resolver.executablePath(
            named: "lazygit", environment: ["PATH": pathBin.path])

        XCTAssertEqual(resolved, pathTool.path)
    }

    func testClaudeResumeCommandUsesCurrentResumeFlag() async {
        let service = SessionBindingActor(
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

        let command = await service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/claude", "--resume", "claude-session-123"])
    }

    func testOpenCodeResumeCommandUsesSessionFlag() async {
        let service = SessionBindingActor(
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

        let command = await service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/opencode", "--session", "opencode-session-123"])
    }

    func testCopilotResumeCommandUsesEqualsResumeFlag() async {
        let service = SessionBindingActor(
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

        let command = await service.terminalCommand(for: thread)

        XCTAssertEqual(command, ["/tmp/bin/copilot", "--resume=copilot-session-123"])
    }

    func testStartNameAndInteractiveRenameCapabilitiesUseManifestContracts() async throws {
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: [
                "codex": "/tmp/bin/codex",
                "claude": "/tmp/bin/claude",
                "opencode": "/tmp/bin/opencode",
                "copilot": "/tmp/bin/copilot",
            ]),
            environment: ["SHELL": "/bin/zsh"],
            captureDirectory: root,
            activityDirectory: root,
            helperBinDirectory: try makeTemporaryDirectory()
        )

        let codex = AgentThread(
            displayName: "Codex Name",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            pendingSessionRename: "Codex Name"
        )
        let claude = AgentThread(
            displayName: "Claude Name",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .claude,
            pendingSessionRename: "Claude Name"
        )
        let claudeResume = AgentThread(
            displayName: "Claude",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .claude,
            sessionIdentity: "claude-123",
            pendingSessionRename: "Claude Renamed"
        )
        let copilot = AgentThread(
            displayName: "Copilot Name",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .copilot,
            pendingSessionRename: "Copilot Name"
        )
        let opencode = AgentThread(
            displayName: "OpenCode Name",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .opencode,
            pendingSessionRename: "OpenCode Name"
        )

        let supportsCodex = await service.supportsSessionRename(for: .codex)
        let supportsClaude = await service.supportsSessionRename(for: .claude)
        let supportsOpenCode = await service.supportsSessionRename(for: .opencode)
        let supportsCopilot = await service.supportsSessionRename(for: .copilot)
        XCTAssertTrue(supportsCodex)
        XCTAssertTrue(supportsClaude)
        XCTAssertFalse(supportsOpenCode)
        XCTAssertTrue(supportsCopilot)

        let claudeInvocation = await service.invocation(for: claude).command
        let copilotInvocation = await service.invocation(for: copilot).command
        let opencodeInvocation = await service.invocation(for: opencode).command
        XCTAssertEqual(claudeInvocation, ["/tmp/bin/claude", "--name", "Claude Name"])
        XCTAssertEqual(copilotInvocation, ["/tmp/bin/copilot", "--name", "Copilot Name"])
        XCTAssertEqual(opencodeInvocation, ["/tmp/bin/opencode"])

        let codexStartup = await service.terminalLaunchDescriptor(for: codex).startupInput
        let claudeStartup = await service.terminalLaunchDescriptor(for: claude).startupInput
        let claudeResumeStartup = await service.terminalLaunchDescriptor(for: claudeResume)
            .startupInput
        XCTAssertEqual(codexStartup, "/rename Codex Name\n")
        XCTAssertNil(claudeStartup)
        XCTAssertEqual(claudeResumeStartup, "/rename Claude Renamed\n")
    }

    func testUsesTerminalTitleAsSessionNameIsFalseOnlyForClaude() async throws {
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(
            captureDirectory: root,
            activityDirectory: root,
            helperBinDirectory: try makeTemporaryDirectory()
        )

        let claude = await service.usesTerminalTitleAsSessionName(for: .claude)
        let codex = await service.usesTerminalTitleAsSessionName(for: .codex)
        let opencode = await service.usesTerminalTitleAsSessionName(for: .opencode)
        let copilot = await service.usesTerminalTitleAsSessionName(for: .copilot)
        XCTAssertFalse(claude)
        XCTAssertTrue(codex)
        XCTAssertTrue(opencode)
        XCTAssertTrue(copilot)
    }
}
