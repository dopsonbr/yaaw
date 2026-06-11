import Darwin
import XCTest

@testable import YAAWKit

/// Catalog-scan, exact-link, ranking, and claude-specific session-binding tests.
/// Ported from the legacy `AgentCLIAdapterTests`; calls re-pointed at the async
/// `SessionBindingActor` API.
final class AgentCLISessionCatalogTests: XCTestCase {
    func testSessionCatalogReadersReturnWorkingDirectoryCandidates() async throws {
        let home = try makeTemporaryDirectory()
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)

        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"codex-1","thread_name":"Codex Linked","cwd":"\(root.path)","updated_at":"2026-05-26T10:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let claudeProjectDirectory =
            home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                root.path.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeProjectDirectory,
            withIntermediateDirectories: true
        )
        try """
        {"sessionId":"claude-1","cwd":"\(root.path)","agent-name":"Claude Linked","timestamp":"2026-05-26T11:00:00Z"}
        """.write(
            to: claudeProjectDirectory.appendingPathComponent("claude-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let openCodeDirectory =
            home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
        try FileManager.default.createDirectory(
            at: openCodeDirectory, withIntermediateDirectories: true)
        try """
        {"id":"opencode-1","title":"OpenCode Linked","directory":"\(root.path)","updated":1779796800}
        """.write(
            to: openCodeDirectory.appendingPathComponent("opencode-1.json"),
            atomically: true,
            encoding: .utf8
        )

        let copilotDirectory =
            home
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent("copilot-1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: copilotDirectory, withIntermediateDirectories: true)
        try """
        {"id":"copilot-1","name":"Copilot Linked","context":{"cwd":"\(root.path)"},"updated_at":"2026-05-26T12:00:00Z"}
        """.write(
            to: copilotDirectory.appendingPathComponent("vscode.metadata.json"),
            atomically: true,
            encoding: .utf8
        )

        let codex = AgentThread(
            displayName: "Codex",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            sessionIdentity: "codex-1"
        )
        let claude = AgentThread(
            displayName: "Claude",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .claude
        )
        let opencode = AgentThread(
            displayName: "OpenCode",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .opencode
        )
        let copilot = AgentThread(
            displayName: "Copilot",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .copilot
        )

        // A reader built straight from the manifest produces the same candidate
        // the actor does (replaces the old direct `CodexCLIAdapter()` call).
        let codexReader = SessionCatalogReader(manifest: CLIManifest.codex)
        XCTAssertEqual(
            codexReader.candidates(workingDirectory: root, homeDirectory: home).first?.displayName,
            "Codex Linked"
        )

        let codexCandidates = await service.sessionLinkCandidates(for: codex)
        let claudeCandidates = await service.sessionLinkCandidates(for: claude)
        let opencodeCandidates = await service.sessionLinkCandidates(for: opencode)
        let copilotCandidates = await service.sessionLinkCandidates(for: copilot)
        let codexMetadata = await service.catalogMetadata(for: codex)
        XCTAssertEqual(codexCandidates.first?.displayName, "Codex Linked")
        XCTAssertEqual(claudeCandidates.first?.identity, "claude-1")
        XCTAssertEqual(opencodeCandidates.first?.displayName, "OpenCode Linked")
        XCTAssertEqual(copilotCandidates.first?.identity, "copilot-1")
        XCTAssertEqual(codexMetadata?.canonicalName, "Codex Linked")
    }

    func testExactSessionLinkCandidateRejectsUniqueCodexNameWithoutWorkingDirectory() async throws {
        let home = try makeTemporaryDirectory()
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"codex-1","thread_name":"rename-test","updated_at":"2026-05-26T10:00:00Z"}
        {"id":"codex-2","thread_name":"other","updated_at":"2026-05-26T11:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let thread = AgentThread(
            displayName: "rename-test",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            pendingSessionRename: "rename-test"
        )

        let exact = await service.exactSessionLinkCandidate(for: thread)
        XCTAssertNil(exact)

        let candidates = await service.sessionLinkCandidates(for: thread)
        XCTAssertTrue(
            candidates.contains {
                $0.identity == "codex-1" && $0.displayName == "rename-test"
            })
    }

    func testExactSessionLinkCandidateUsesCodexHistoryWhenIndexIsMissingSession() async throws {
        let home = try makeTemporaryDirectory()
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"other","thread_name":"other","updated_at":"2026-05-26T10:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"session_id":"codex-history-1","cwd":"\(root.path)","ts":1779820871,"text":"tell me 2 jokes"}
        """.write(
            to: codexDirectory.appendingPathComponent("history.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let thread = AgentThread(
            displayName: "tell me 2 jokes",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            pendingSessionRename: "tell me 2 jokes"
        )

        let candidate = try unwrapAsync(await service.exactSessionLinkCandidate(for: thread))

        XCTAssertEqual(candidate.identity, "codex-history-1")
        XCTAssertEqual(candidate.displayName, "tell me 2 jokes")
        XCTAssertEqual(candidate.workingDirectory?.standardizedFileURL.path, root.path)
        XCTAssertEqual(candidate.source, "~/.codex/history.jsonl")
    }

    func testExactSessionLinkCandidateDoesNotAutoLinkDirectorylessCodexHistory() async throws {
        let home = try makeTemporaryDirectory()
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"session_id":"codex-history-1","ts":1779820871,"text":"tell me 2 jokes"}
        """.write(
            to: codexDirectory.appendingPathComponent("history.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let thread = AgentThread(
            displayName: "tell me 2 jokes",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            pendingSessionRename: "tell me 2 jokes"
        )

        let exact = await service.exactSessionLinkCandidate(for: thread)
        XCTAssertNil(exact)
        let candidates = await service.sessionLinkCandidates(for: thread)
        XCTAssertEqual(candidates.first?.identity, "codex-history-1")
    }

    func testManualSessionLinkCandidatesRankDirectoryMatchesBeforeRecency() async throws {
        let home = try makeTemporaryDirectory()
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"directory-match","thread_name":"Older Exact","cwd":"\(root.path)","updated_at":"2026-05-26T10:00:00Z"}
        {"id":"directoryless-newer","thread_name":"Newer Unknown","updated_at":"2026-05-26T12:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let thread = AgentThread(
            displayName: "Manual",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex
        )

        let candidates = await service.sessionLinkCandidates(for: thread)

        XCTAssertEqual(candidates.map(\.identity), ["directory-match", "directoryless-newer"])
    }

    func testExactSessionLinkCandidateRejectsAmbiguousCodexNames() async throws {
        let home = try makeTemporaryDirectory()
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true)
        try """
        {"id":"codex-1","thread_name":"rename-test","cwd":"\(root.path)","updated_at":"2026-05-26T10:00:00Z"}
        {"id":"codex-2","thread_name":"rename-test","cwd":"\(root.path)","updated_at":"2026-05-26T11:00:00Z"}
        """.write(
            to: codexDirectory.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let thread = AgentThread(
            displayName: "rename-test",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            pendingSessionRename: "rename-test"
        )

        let exact = await service.exactSessionLinkCandidate(for: thread)
        XCTAssertNil(exact)
    }

    func testExactSessionLinkCandidateReadsClaudeCustomTitle() async throws {
        let home = try makeTemporaryDirectory()
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let claudeProjectDirectory =
            home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                root.path.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeProjectDirectory,
            withIntermediateDirectories: true
        )
        try """
        {"type":"custom-title","customTitle":"claude-resume-test","sessionId":"claude-1"}
        """.write(
            to: claudeProjectDirectory.appendingPathComponent("claude-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let thread = AgentThread(
            displayName: "claude-resume-test",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .claude,
            pendingSessionRename: "claude-resume-test"
        )

        let candidate = try unwrapAsync(await service.exactSessionLinkCandidate(for: thread))

        XCTAssertEqual(candidate.identity, "claude-1")
        XCTAssertEqual(candidate.displayName, "claude-resume-test")
    }

    func testClaudeCandidateIgnoresNestedToolUseNames() async throws {
        let home = try makeTemporaryDirectory()
        let root = try makeTemporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let claudeProjectDirectory =
            home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                root.path.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeProjectDirectory,
            withIntermediateDirectories: true
        )
        // The real title is in the top-level `custom-title`/`agent-name` lines. The
        // `assistant` lines embed `tool_use` blocks whose `name` is a tool; a recursive
        // search would let the last one ("Bash") win and mislabel the thread.
        try """
        {"type":"custom-title","customTitle":"ux-improvements","sessionId":"claude-1"}
        {"type":"agent-name","agentName":"ux-improvements","sessionId":"claude-1"}
        {"type":"assistant","sessionId":"claude-1","cwd":"\(root.path)","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}
        {"type":"assistant","sessionId":"claude-1","cwd":"\(root.path)","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        """.write(
            to: claudeProjectDirectory.appendingPathComponent("claude-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let thread = AgentThread(
            displayName: "ux-improvements",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .claude
        )

        let candidate = try unwrapAsync(await service.sessionLinkCandidates(for: thread).first)

        XCTAssertEqual(candidate.identity, "claude-1")
        XCTAssertEqual(candidate.displayName, "ux-improvements")
    }
}
