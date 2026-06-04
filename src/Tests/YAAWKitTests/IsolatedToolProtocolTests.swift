import XCTest

@testable import YAAWKit

final class IsolatedToolProtocolTests: XCTestCase {
    func testEnvelopeRoundTripsVersionedCommand() throws {
        let envelope = IsolatedToolEnvelope(
            toolKind: .browser,
            instanceID: "thread:browser",
            messageID: "message-1",
            type: "load",
            payload: ["urlString": "file:///tmp/index.html"]
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IsolatedToolEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
        XCTAssertNoThrow(try decoded.validated())
    }

    func testEnvelopeRejectsUnsupportedProtocolVersion() throws {
        let envelope = IsolatedToolEnvelope(
            protocolVersion: 999,
            toolKind: .browser,
            instanceID: "thread:browser",
            type: "load"
        )

        XCTAssertThrowsError(try envelope.validated()) { error in
            XCTAssertEqual(error as? IsolatedToolProtocolError, .unsupportedProtocolVersion(999))
        }
    }

    func testRuntimeReducerTracksBrowserStateAndCrash() {
        var snapshot = IsolatedToolRuntimeSnapshot()

        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .launch)
        XCTAssertEqual(snapshot.phase, .launching)

        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .ready)
        XCTAssertEqual(snapshot.phase, .ready)

        snapshot = IsolatedToolRuntimeReducer.reduce(
            snapshot,
            action: .stateChanged([
                "title": "Preview",
                "urlString": "file:///tmp/index.html",
                "isLoading": "true",
                "canGoBack": "true",
                "canGoForward": "false",
            ])
        )
        XCTAssertEqual(snapshot.phase, .loading)
        XCTAssertEqual(snapshot.title, "Preview")
        XCTAssertEqual(snapshot.urlString, "file:///tmp/index.html")
        XCTAssertTrue(snapshot.isLoading)
        XCTAssertTrue(snapshot.canGoBack)
        XCTAssertFalse(snapshot.canGoForward)

        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .crashed("renderer exited"))
        XCTAssertEqual(snapshot.phase, .crashed)
        XCTAssertEqual(snapshot.errorMessage, "renderer exited")
        XCTAssertFalse(snapshot.isLoading)
    }

    func testTerminalEnvelopeRoundTrips() throws {
        let launch = IsolatedTerminalLaunch(
            command: ["/usr/bin/env", "claude", "--flag"],
            environment: ["YAAW_EVENT_LOG": "/tmp/events.log", "TERM": "xterm-256color"],
            workingDirectory: "/Users/me/project",
            captureLogPath: "/tmp/capture/abc.log",
            captureLogMaximumBytes: 8 * 1024 * 1024,
            startupInput: "hello\n",
            agentCLI: "claude"
        )
        let envelope = IsolatedToolEnvelope(
            toolKind: .terminal,
            instanceID: "project:abc",
            type: "launchTerminal",
            payload: launch.payload()
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IsolatedToolEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.toolKind, .terminal)
        XCTAssertNoThrow(try decoded.validated())
    }

    func testTerminalLaunchPayloadRoundTrips() throws {
        let launch = IsolatedTerminalLaunch(
            command: ["/bin/zsh", "-lc", "exec codex"],
            environment: ["A": "1", "B": "two"],
            workingDirectory: "/tmp/work",
            captureLogPath: "/tmp/capture/xyz.log",
            captureLogMaximumBytes: 1234,
            startupInput: "go\n",
            agentCLI: "codex"
        )

        let restored = try XCTUnwrap(IsolatedTerminalLaunch.from(payload: launch.payload()))
        XCTAssertEqual(restored, launch)
    }

    func testTerminalLaunchRejectsEmptyCommand() {
        let payload: [String: String] = [
            "command": "[]",
            "environment": "{}",
            "workingDirectory": "/tmp",
        ]
        XCTAssertNil(IsolatedTerminalLaunch.from(payload: payload))
    }

    func testIsolatedTerminalLaunchFromAgentPTYRequest() {
        let descriptor = AgentTerminalLaunchDescriptor(
            command: ["codex", "--resume"],
            environment: ["YAAW_EVENT_LOG": "/tmp/e.log", "TERM": "xterm-256color"],
            captureLogURL: URL(fileURLWithPath: "/tmp/capture/abc.log"),
            captureLogMaximumBytes: 4096,
            startupInput: "go\n"
        )
        let request = TerminalLaunchRequest(
            role: .project(threadID: UUID()),
            title: "Agent",
            workingDirectory: URL(fileURLWithPath: "/Users/me/project"),
            command: ["codex", "--resume"],
            backend: .agentPTY(descriptor),
            agentCLI: .codex
        )

        let launch = IsolatedTerminalLaunch(request: request)
        XCTAssertEqual(launch.command, ["codex", "--resume"])
        XCTAssertEqual(launch.environment["YAAW_EVENT_LOG"], "/tmp/e.log")
        XCTAssertEqual(launch.workingDirectory, "/Users/me/project")
        XCTAssertEqual(launch.captureLogPath, "/tmp/capture/abc.log")
        XCTAssertEqual(launch.captureLogMaximumBytes, 4096)
        XCTAssertEqual(launch.startupInput, "go\n")
        XCTAssertEqual(launch.agentCLI, "codex")
    }

    func testIsolatedTerminalLaunchFromExecRequest() {
        let request = TerminalLaunchRequest(
            role: .bottom(threadID: UUID()),
            title: "Bottom Terminal",
            workingDirectory: URL(fileURLWithPath: "/work"),
            command: ["/bin/zsh", "-il"],
            backend: .exec
        )

        let launch = IsolatedTerminalLaunch(request: request)
        XCTAssertEqual(launch.command, ["/bin/zsh", "-il"])
        // Empty environment signals the helper to inherit its own (the app's) env.
        XCTAssertTrue(launch.environment.isEmpty)
        XCTAssertEqual(launch.workingDirectory, "/work")
        XCTAssertNil(launch.captureLogPath)
        XCTAssertNil(launch.captureLogMaximumBytes)
        XCTAssertNil(launch.startupInput)
    }

    func testRuntimeReducerTracksTerminalExit() {
        var snapshot = IsolatedToolRuntimeSnapshot()
        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .launch)
        XCTAssertNil(snapshot.exitCode)

        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .ready)
        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .exited(0))
        XCTAssertEqual(snapshot.phase, .exited)
        XCTAssertEqual(snapshot.exitCode, 0)

        // Relaunch clears the prior exit code.
        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .launch)
        XCTAssertEqual(snapshot.phase, .launching)
        XCTAssertNil(snapshot.exitCode)
    }
}
