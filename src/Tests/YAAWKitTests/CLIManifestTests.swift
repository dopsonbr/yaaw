import XCTest

@testable import YAAWKit

/// Manifest-driven tests new to the rewrite: per-family fixture conformance,
/// the reversible claude path encoding, drift detection, and a parameterized
/// resume-template check.
final class CLIManifestTests: XCTestCase {
    // MARK: - Reversible path encoding (lossy-bug fix)

    func testClaudeProjectPathEncodingIsReversibleAndDistinguishesHyphenFromSlash() throws {
        let cases = ["/a-b", "/a/b", "/a-b-c", "/home/user/a-b", "/home/user/a/b"]
        var encodings: [String] = []
        for path in cases {
            let encoded = ClaudeProjectPathEncoding.encode(path)
            encodings.append(encoded)
            XCTAssertEqual(
                ClaudeProjectPathEncoding.decode(encoded), path,
                "round trip failed for \(path)")
        }
        // The legacy bug collapsed `/a-b` and `/a/b` to the same name; the fixed
        // encoding must keep every distinct path distinct.
        XCTAssertEqual(Set(encodings).count, cases.count)
        XCTAssertNotEqual(
            ClaudeProjectPathEncoding.encode("/a-b"),
            ClaudeProjectPathEncoding.encode("/a/b")
        )
    }

    func testClaudeReaderMatchesBothLegacyAndReversibleDirectoryEncodings() async throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let projectsRoot =
            home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        // Directory named with the *legacy* lossy scheme (every existing on-disk
        // session uses it) must still resolve.
        let legacyName = ClaudeProjectPathEncoding.legacyEncode(root.path)
        let legacyDir = projectsRoot.appendingPathComponent(legacyName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try """
        {"type":"custom-title","customTitle":"Legacy Dir","sessionId":"claude-legacy"}
        """.write(
            to: legacyDir.appendingPathComponent("claude-legacy.jsonl"),
            atomically: true, encoding: .utf8)
        let thread = AgentThread(
            displayName: "Legacy Dir", projectID: UUID(), workingDirectory: root, agentCLI: .claude)

        let candidate = try unwrapAsync(await service.sessionLinkCandidates(for: thread).first)
        XCTAssertEqual(candidate.identity, "claude-legacy")
        XCTAssertEqual(candidate.displayName, "Legacy Dir")
    }

    // MARK: - Parameterized resume template

    func testResumeTemplateProducesCorrectArgumentStructurePerFamily() {
        let expectations: [(AgentCLIKind, [String])] = [
            (.codex, ["resume", "sess-1"]),
            (.claude, ["--resume", "sess-1"]),
            (.opencode, ["--session", "sess-1"]),
            (.copilot, ["--resume=sess-1"]),
        ]
        for (kind, expected) in expectations {
            let manifest = try? XCTUnwrap(CLIManifest.builtIn(for: kind))
            XCTAssertEqual(
                manifest?.resumeTemplate.arguments(sessionIdentity: "sess-1"), expected,
                "resume template mismatch for \(kind)")
        }
    }

    // MARK: - Per-family fixture conformance

    func testCodexFixtureExtractsExactCandidate() async throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try """
        {"session_id":"codex-fix-1","thread_name":"Fixture Codex","cwd":"\(root.path)","updated_at":"2026-06-01T09:00:00Z"}
        """.write(
            to: codexDir.appendingPathComponent("session_index.jsonl"),
            atomically: true, encoding: .utf8)
        let reader = SessionCatalogReader(manifest: CLIManifest.codex)

        let candidate = try XCTUnwrap(
            reader.candidates(workingDirectory: root, homeDirectory: home).first)
        XCTAssertEqual(candidate.identity, "codex-fix-1")
        XCTAssertEqual(candidate.displayName, "Fixture Codex")
        XCTAssertEqual(candidate.workingDirectory?.standardizedFileURL.path, root.path)
        XCTAssertNotNil(candidate.updatedAt)
    }

    func testOpenCodeFixtureRequiresExplicitDirectory() async throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let sessionDir =
            home
            .appendingPathComponent(".local/share/opencode/storage/session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        // Has explicit directory → matches.
        try """
        {"id":"oc-1","title":"With Dir","directory":"\(root.path)","updated":1779796800}
        """.write(
            to: sessionDir.appendingPathComponent("oc-1.json"), atomically: true, encoding: .utf8)
        // No directory → strict matching rejects it.
        try """
        {"id":"oc-2","title":"No Dir","updated":1779796900}
        """.write(
            to: sessionDir.appendingPathComponent("oc-2.json"), atomically: true, encoding: .utf8)
        let reader = SessionCatalogReader(manifest: CLIManifest.opencode)

        let candidates = reader.candidates(workingDirectory: root, homeDirectory: home)
        XCTAssertEqual(candidates.map(\.identity), ["oc-1"])
    }

    func testCopilotFixtureMergesMetadataAndEvents() async throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let sessionDir =
            home
            .appendingPathComponent(".copilot/session-state", isDirectory: true)
            .appendingPathComponent("cp-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        {"id":"cp-1","name":"Metadata Name","cwd":"\(root.path)","updated_at":"2026-06-01T10:00:00Z"}
        """.write(
            to: sessionDir.appendingPathComponent("vscode.metadata.json"),
            atomically: true, encoding: .utf8)
        // Events override the metadata name.
        try """
        {"session_id":"cp-1","firstUserMessage":"Events Name","cwd":"\(root.path)","timestamp":"2026-06-01T11:00:00Z"}
        """.write(
            to: sessionDir.appendingPathComponent("events.jsonl"),
            atomically: true, encoding: .utf8)
        let reader = SessionCatalogReader(manifest: CLIManifest.copilot)

        let candidate = try XCTUnwrap(
            reader.candidates(workingDirectory: root, homeDirectory: home).first)
        XCTAssertEqual(candidate.identity, "cp-1")
        XCTAssertEqual(candidate.displayName, "Events Name")
    }

    // MARK: - Drift detection (loud failure)

    func testCatalogMetadataResultReportsDriftForPresentButUnparseableRecord() async throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let recorder = RecordingDiagnosticEventRecorder()
        let service = SessionBindingActor(
            captureDirectory: nil, homeDirectory: home, diagnosticRecorder: recorder)
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        // The session record plainly references the identity (e.g. inside a field
        // YAAW does not recognize), so the catalog is NOT empty for this id — but
        // no candidate parses out, which is drift, not absence.
        try """
        {"unexpected_id_field":"codex-drift-1","thread_name":"Drifted","cwd":"\(root.path)"}
        """.write(
            to: codexDir.appendingPathComponent("session_index.jsonl"),
            atomically: true, encoding: .utf8)
        let thread = AgentThread(
            displayName: "Drifted",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            sessionIdentity: "codex-drift-1"
        )

        let result = await service.catalogMetadataResult(for: thread)

        guard case .driftDetected(let reason) = result else {
            return XCTFail("expected drift, got \(result)")
        }
        XCTAssertTrue(reason.contains("codex-drift-1"))
        let drift = recorder.events.contains { $0.name == "session_catalog_drift" }
        XCTAssertTrue(drift, "drift must be recorded as a diagnostic")
    }

    func testCatalogMetadataResultIsAbsentWhenNoRecordReferencesIdentity() async throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try """
        {"session_id":"codex-other","thread_name":"Other","cwd":"\(root.path)"}
        """.write(
            to: codexDir.appendingPathComponent("session_index.jsonl"),
            atomically: true, encoding: .utf8)
        let thread = AgentThread(
            displayName: "Missing",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            sessionIdentity: "codex-missing"
        )

        let result = await service.catalogMetadataResult(for: thread)
        XCTAssertEqual(result, .absent)
    }

    func testCatalogMetadataResultIsFoundForParseableRecord() async throws {
        let home = try temporaryDirectory()
        let root = try temporaryDirectory()
        let service = SessionBindingActor(captureDirectory: nil, homeDirectory: home)
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try """
        {"session_id":"codex-ok","thread_name":"Found Codex","cwd":"\(root.path)"}
        """.write(
            to: codexDir.appendingPathComponent("session_index.jsonl"),
            atomically: true, encoding: .utf8)
        let thread = AgentThread(
            displayName: "Found",
            projectID: UUID(),
            workingDirectory: root,
            agentCLI: .codex,
            sessionIdentity: "codex-ok"
        )

        let result = await service.catalogMetadataResult(for: thread)
        XCTAssertEqual(
            result,
            .found(AgentCLISessionMetadata(identity: "codex-ok", reportedName: "Found Codex")))
    }

    // MARK: - Unsupported permission mode (loud failure)

    func testUnsupportedPermissionModeIsLoggedNotSilentlyDropped() async throws {
        let recorder = RecordingDiagnosticEventRecorder()
        let service = SessionBindingActor(
            resolver: StaticExecutableResolver(paths: ["opencode": "/tmp/bin/opencode"]),
            captureDirectory: nil,
            diagnosticRecorder: recorder
        )
        let thread = AgentThread(
            displayName: "OpenCode",
            projectID: UUID(),
            workingDirectory: FileManager.default.temporaryDirectory,
            agentCLI: .opencode,
            launchOptions: AgentLaunchOptions(permissionModeID: "codex-on-request")
        )

        // OpenCode has no permission modes, so the requested mode is unsupported:
        // the command drops it (parity) AND a diagnostic is recorded (loud).
        let command = await service.invocation(
            for: thread, permissionModes: AgentPermissionMode.supportedModes(for: .opencode)
        ).command
        XCTAssertEqual(command, ["/tmp/bin/opencode"])
        let logged = recorder.events.contains { $0.name == "permission_mode_unsupported" }
        XCTAssertTrue(logged)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
