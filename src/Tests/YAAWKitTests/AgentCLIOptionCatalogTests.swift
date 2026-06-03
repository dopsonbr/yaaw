import XCTest

@testable import YAAWKit

final class AgentCLIOptionCatalogTests: XCTestCase {
    func testCodexHelpParserFindsApprovalSandboxAndBypassPresets() {
        let modes = AgentCLIOptionCatalogParser.permissionPresets(
            kind: .codex,
            helpText: """
                Usage: codex [OPTIONS]
                  --ask-for-approval <POLICY>  untrusted, on-failure, on-request, never
                  --sandbox <MODE>             read-only, workspace-write, danger-full-access
                  --dangerously-bypass-approvals-and-sandbox
                """
        )

        XCTAssertTrue(modes.contains { $0.id == "codex-on-request" })
        XCTAssertTrue(modes.contains { $0.id == "codex-on-failure" })
        XCTAssertTrue(modes.contains { $0.id == "codex-workspace-write" })
        XCTAssertTrue(modes.contains { $0.id == "codex-bypass" })
    }

    func testClaudeHelpParserFindsPermissionModePresets() {
        let modes = AgentCLIOptionCatalogParser.permissionPresets(
            kind: .claude,
            helpText: """
                Usage: claude [options]
                  --permission-mode <mode>  plan, auto, acceptEdits, dontAsk, bypassPermissions
                """
        )

        XCTAssertEqual(
            modes.map(\.id),
            [
                "claude-plan",
                "claude-auto",
                "claude-accept-edits",
                "claude-dont-ask",
                "claude-bypass-permissions",
            ]
        )
    }

    func testOpenCodeHelpParserFallsBackToCLIDefaultOnly() {
        let modes = AgentCLIOptionCatalogParser.permissionPresets(
            kind: .opencode,
            helpText: """
                Usage: opencode [command] [options]
                  serve
                  run
                """
        )

        XCTAssertTrue(modes.isEmpty)
    }

    func testCopilotHelpParserFindsPermissionFlags() {
        let modes = AgentCLIOptionCatalogParser.permissionPresets(
            kind: .copilot,
            helpText: """
                Usage: copilot [options]
                  --plan
                  --autopilot
                  --allow-all-tools
                  --allow-all
                  --yolo
                """
        )

        XCTAssertEqual(
            modes.map(\.id),
            [
                "copilot-plan",
                "copilot-autopilot",
                "copilot-allow-all-tools",
                "copilot-allow-all",
                "copilot-yolo",
            ]
        )
    }
}
