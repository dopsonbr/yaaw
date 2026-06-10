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
            agentCLI: "codex",
            appShortcutSignatures: ["command+j", "command+shift+["]
        )

        let restored = try XCTUnwrap(IsolatedTerminalLaunch.from(payload: launch.payload()))
        XCTAssertEqual(restored, launch)
        XCTAssertEqual(restored.appShortcutSignatures, ["command+j", "command+shift+["])
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

        let launch = IsolatedTerminalLaunch(
            request: request,
            appShortcutSignatures: ["command+j"]
        )
        XCTAssertEqual(launch.command, ["codex", "--resume"])
        XCTAssertEqual(launch.environment["YAAW_EVENT_LOG"], "/tmp/e.log")
        XCTAssertEqual(launch.workingDirectory, "/Users/me/project")
        XCTAssertEqual(launch.captureLogPath, "/tmp/capture/abc.log")
        XCTAssertEqual(launch.captureLogMaximumBytes, 4096)
        XCTAssertEqual(launch.startupInput, "go\n")
        XCTAssertEqual(launch.agentCLI, "codex")
        XCTAssertEqual(launch.appShortcutSignatures, ["command+j"])
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

    private func makeLaunch() -> IsolatedTerminalLaunch {
        IsolatedTerminalLaunch(
            command: ["/usr/bin/env", "claude"],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: "/Users/me/project",
            captureLogPath: "/tmp/capture/abc.log",
            captureLogMaximumBytes: 4096,
            startupInput: "go\n",
            agentCLI: "claude",
            themeID: "dracula",
            terminalFontFamily: "JetBrains Mono",
            terminalFontSize: 15,
            appShortcutSignatures: ["command+j"]
        )
    }

    func testTerminalLaunchProcessIdentityIgnoresRenderingFields() {
        let launch = makeLaunch()
        var restyled = launch
        restyled.applyRendering(
            IsolatedTerminalRendering(
                themeID: "light-2026",
                terminalFontFamily: "Menlo",
                terminalFontSize: 13,
                appShortcutSignatures: ["command+k", "command+1"]
            ))

        XCTAssertNotEqual(restyled, launch)
        XCTAssertTrue(launch.processIdentityMatches(restyled))
        XCTAssertTrue(restyled.processIdentityMatches(launch))
    }

    func testTerminalLaunchProcessIdentityDetectsProcessChanges() {
        let launch = makeLaunch()
        let mutations: [(inout IsolatedTerminalLaunch) -> Void] = [
            { $0.command = ["/bin/zsh", "-il"] },
            { $0.environment["TERM"] = "dumb" },
            { $0.workingDirectory = "/elsewhere" },
            { $0.captureLogPath = nil },
            { $0.captureLogMaximumBytes = 8192 },
            { $0.startupInput = nil },
            { $0.agentCLI = "codex" },
        ]
        for (index, mutate) in mutations.enumerated() {
            var changed = launch
            mutate(&changed)
            XCTAssertFalse(
                launch.processIdentityMatches(changed),
                "identity mutation \(index) should not match")
        }
    }

    func testTerminalRenderingPayloadRoundTrips() {
        let rendering = IsolatedTerminalRendering(
            themeID: "dracula",
            terminalFontFamily: "JetBrains Mono",
            terminalFontSize: 17,
            terminalFontLigatures: false,
            appShortcutSignatures: ["command+j", "command+shift+["]
        )

        let restored = IsolatedTerminalRendering.from(payload: rendering.payload())
        XCTAssertEqual(restored, rendering)
        XCTAssertEqual(restored.appShortcutSignatures, ["command+j", "command+shift+["])
        XCTAssertEqual(restored.terminalFontLigatures, false)

        // Blank strings normalize to nil, matching the launch payload rules.
        let blank = IsolatedTerminalRendering(themeID: "  ", terminalFontFamily: "")
        XCTAssertNil(blank.themeID)
        XCTAssertNil(blank.terminalFontFamily)
        // An absent ligatures key stays nil (default: enabled).
        XCTAssertNil(blank.terminalFontLigatures)
        XCTAssertEqual(
            IsolatedTerminalRendering.from(payload: blank.payload()),
            IsolatedTerminalRendering())
    }

    func testTerminalLaunchTransitionClassification() {
        let launch = makeLaunch()
        var restyled = launch
        restyled.applyRendering(IsolatedTerminalRendering(themeID: "light-2026"))
        var ligaturesToggled = launch
        ligaturesToggled.terminalFontLigatures = false
        var relaunched = launch
        relaunched.command = ["/bin/zsh", "-il"]
        var relaunchedAndRestyled = relaunched
        relaunchedAndRestyled.applyRendering(IsolatedTerminalRendering(themeID: "light-2026"))

        XCTAssertEqual(IsolatedTerminalLaunchTransition.between(nil, launch), .launchNew)
        XCTAssertEqual(IsolatedTerminalLaunchTransition.between(launch, launch), .noChange)
        XCTAssertEqual(IsolatedTerminalLaunchTransition.between(launch, restyled), .updateRendering)
        // A ligature toggle is rendering-only: live update, no agent restart.
        XCTAssertEqual(
            IsolatedTerminalLaunchTransition.between(launch, ligaturesToggled), .updateRendering)
        XCTAssertEqual(
            IsolatedTerminalLaunchTransition.between(launch, relaunched), .relaunchProcess)
        XCTAssertEqual(
            IsolatedTerminalLaunchTransition.between(launch, relaunchedAndRestyled),
            .relaunchProcess)
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
