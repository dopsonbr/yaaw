import XCTest
import YAAWRenderProtocol

final class RenderProtocolTests: XCTestCase {

    // MARK: - RenderMessage round-trips

    func testRenderMessageLaunchRoundTrips() throws {
        let payload = LaunchPayload(
            toolKind: "terminal",
            command: ["/usr/bin/env", "claude", "--flag"],
            environment: ["TERM": "xterm-256color", "YAAW_EVENT_LOG": "/tmp/e.log"],
            workingDirectory: "/Users/me/project",
            captureLogPath: "/tmp/capture/abc.log",
            captureLogMaximumBytes: 8 * 1024 * 1024,
            startupInput: "hello\n",
            agentCLI: "claude",
            themeID: "dracula",
            terminalFontFamily: "JetBrains Mono",
            terminalFontSize: 15,
            terminalFontLigatures: false,
            appShortcutSignatures: ["command+j", "command+shift+["]
        )
        try assertRoundTrips(RenderMessage.launch(payload))
    }

    func testRenderMessageResizeRoundTrips() throws {
        let payload = ResizePayload(
            columns: 120,
            rows: 40,
            widthPixels: 1920,
            heightPixels: 1080,
            contentsScale: 2.0
        )
        try assertRoundTrips(RenderMessage.resize(payload))
    }

    func testRenderMessageInputCarriesRawBytesWithoutBase64() throws {
        // Binary-safe: raw (including NUL and high) bytes survive the round-trip.
        let rawBytes = Data([0x00, 0x16, 0xFF, 0x41, 0x0A, 0x7F])
        let message = RenderMessage.input(InputPayload(data: rawBytes))
        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(RenderMessage.self, from: encoded)

        XCTAssertEqual(decoded, message)
        guard case .input(let payload) = decoded else {
            return XCTFail("expected .input")
        }
        XCTAssertEqual(payload.data, rawBytes)
    }

    func testRenderMessageSetRenderingRoundTrips() throws {
        let payload = RenderingPayload(
            themeID: "light-2026",
            terminalFontFamily: "Menlo",
            terminalFontSize: 13,
            terminalFontLigatures: true,
            appShortcutSignatures: ["command+k"]
        )
        try assertRoundTrips(RenderMessage.setRendering(payload))
    }

    func testRenderMessageShutdownRoundTrips() throws {
        try assertRoundTrips(RenderMessage.shutdown)
    }

    // MARK: - RenderEvent round-trips

    func testRenderEventVariantsRoundTrip() throws {
        try assertRoundTrips(RenderEvent.title("Agent"))
        try assertRoundTrips(
            RenderEvent.activity(ActivityPayload(activity: "running tests", isRunning: true)))
        try assertRoundTrips(RenderEvent.sessionId("session-1"))
        try assertRoundTrips(RenderEvent.bell)
        try assertRoundTrips(RenderEvent.notification(title: "Done", body: "build finished"))
        try assertRoundTrips(RenderEvent.pwd("/Users/me/project"))
        try assertRoundTrips(RenderEvent.commandFinished(exitCode: 0, durationNanos: 1_234_567))
        try assertRoundTrips(RenderEvent.commandFinished(exitCode: nil, durationNanos: 0))
        try assertRoundTrips(RenderEvent.exited(0))
        try assertRoundTrips(RenderEvent.exited(nil))
        try assertRoundTrips(RenderEvent.captureTruncated(truncatedAtByte: 8_388_608))
    }

    // MARK: - Version negotiation

    func testVersionNegotiationPicksLowerOfTwoHighest() {
        XCTAssertEqual(RenderProtocolVersion.negotiated(appVersion: 3, helperVersion: 5), 3)
        XCTAssertEqual(RenderProtocolVersion.negotiated(appVersion: 5, helperVersion: 3), 3)
        XCTAssertEqual(RenderProtocolVersion.negotiated(appVersion: 4, helperVersion: 4), 4)
    }

    func testVersionNegotiationDefaultsToCurrentForApp() {
        XCTAssertEqual(
            RenderProtocolVersion.negotiated(helperVersion: RenderProtocolVersion.current),
            RenderProtocolVersion.current
        )
    }

    func testVersionNegotiationRejectsNonPositiveOffers() {
        XCTAssertNil(RenderProtocolVersion.negotiated(appVersion: 0, helperVersion: 2))
        XCTAssertNil(RenderProtocolVersion.negotiated(appVersion: 2, helperVersion: -1))
    }

    // MARK: - IsolatedTerminalLaunch payload round-trips

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

    // MARK: - processIdentityMatches + transition classification

    func testTerminalLaunchProcessIdentityIgnoresRenderingFields() {
        let launch = Self.makeLaunch()
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
        let launch = Self.makeLaunch()
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

    func testTerminalLaunchTransitionClassification() {
        let launch = Self.makeLaunch()
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

    func testLaunchPayloadBridgesFromIsolatedTerminalLaunch() {
        let launch = Self.makeLaunch()
        let payload = LaunchPayload(terminal: launch)

        XCTAssertEqual(payload.toolKind, IsolatedToolKind.terminal.rawValue)
        XCTAssertEqual(payload.command, launch.command)
        XCTAssertEqual(payload.environment, launch.environment)
        XCTAssertEqual(payload.workingDirectory, launch.workingDirectory)
        XCTAssertEqual(payload.agentCLI, launch.agentCLI)
        XCTAssertEqual(payload.themeID, launch.themeID)
    }

    func testRenderingPayloadBridgesFromIsolatedTerminalRendering() {
        let rendering = IsolatedTerminalRendering(
            themeID: "dracula",
            terminalFontFamily: "JetBrains Mono",
            terminalFontSize: 15,
            terminalFontLigatures: false,
            appShortcutSignatures: ["command+j"]
        )
        let payload = RenderingPayload(rendering: rendering)

        XCTAssertEqual(payload.themeID, rendering.themeID)
        XCTAssertEqual(payload.terminalFontFamily, rendering.terminalFontFamily)
        XCTAssertEqual(payload.terminalFontSize, rendering.terminalFontSize)
        XCTAssertEqual(payload.terminalFontLigatures, rendering.terminalFontLigatures)
        XCTAssertEqual(payload.appShortcutSignatures, rendering.appShortcutSignatures)
    }

    // MARK: - Helpers

    private func assertRoundTrips<T: Codable & Equatable>(_ value: T) throws {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: encoded)
        XCTAssertEqual(decoded, value)
    }

    private static func makeLaunch() -> IsolatedTerminalLaunch {
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
}
