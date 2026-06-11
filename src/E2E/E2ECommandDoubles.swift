import Foundation
import YAAWKit

/// Writes the deterministic command doubles into `$ARTIFACT_DIR/bin` (placed
/// earlier on `PATH` than the real CLIs). Each double answers `--help` /
/// `--version` and the family-specific session flags, emitting
/// `YAAW_SESSION_ID=` / `YAAW_SESSION_NAME=` so the binding actor can scrape
/// deterministic metadata. Ported byte-for-byte from the pre-rewrite runner.
struct E2ECommandDoubles {
    let paths: E2EPaths
    private let fileManager = FileManager.default

    init(paths: E2EPaths) {
        self.paths = paths
    }

    func write() throws {
        try writeAgentDoubles()
        try writeToolDoubles()
        try copyDoublesForMissingToolBin()
    }

    private func writeAgentDoubles() throws {
        try writeExecutable(named: "codex", contents: Self.codexDouble)
        try writeExecutable(named: "claude", contents: Self.claudeDouble)
        try writeExecutable(named: "opencode", contents: Self.opencodeDouble)
        try writeExecutable(named: "copilot", contents: Self.copilotDouble)
    }

    private func writeToolDoubles() throws {
        try writeExecutable(named: "nvim", contents: Self.editorDouble(label: "NVIM_DOUBLE"))
        try writeExecutable(named: "vim", contents: Self.editorDouble(label: "VIM_DOUBLE"))
        try writeExecutable(named: "vi", contents: Self.editorDouble(label: "VI_DOUBLE"))
        try writeExecutable(named: "git", contents: Self.editorDouble(label: "GIT_DOUBLE"))
        try writeExecutable(named: "lazygit", contents: Self.lazygitDouble)
    }

    private func copyDoublesForMissingToolBin() throws {
        for tool in ["codex", "claude", "opencode", "copilot", "nvim", "vim", "vi", "git"] {
            let source = paths.binDirectory.appendingPathComponent(tool)
            let target = paths.missingToolBinDirectory.appendingPathComponent(tool)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source, to: target)
        }
    }

    private func writeExecutable(named name: String, contents: String) throws {
        let path = paths.binDirectory.appendingPathComponent(name)
        try (contents + "\n").write(to: path, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    // MARK: - Script literals

    private static let codexDouble = """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "${1:-}" == "--help" ]]; then
          printf '%s\\n' 'Usage: codex [OPTIONS]'
          printf '%s\\n' '  --ask-for-approval <POLICY>  untrusted, on-failure, on-request, never'
          printf '%s\\n' '  --sandbox <MODE>             read-only, workspace-write, danger-full-access'
          printf '%s\\n' '  --dangerously-bypass-approvals-and-sandbox'
          exit 0
        fi
        if [[ "${1:-}" == "--version" ]]; then
          printf 'codex 0.136.0\\n'
          exit 0
        fi
        if [[ "${YAAW_E2E_KEYBOARD_PROBE:-}" == "1" ]]; then
          printf 'YAAW_KEYBOARD_PROBE_READY\\n'
          IFS= read -r line
          printf 'YAAW_ENTER_RECEIVED=%s\\n' "$line"
          sleep 1
          exit 0
        fi
        if [[ "${1:-}" == "resume" ]]; then
          printf 'YAAW_SESSION_ID=%s\\n' "$2"
          printf 'YAAW_SESSION_NAME=Codex Resumed %s\\n' "$2"
        else
          printf 'YAAW_SESSION_ID=codex-e2e-001\\n'
          printf 'YAAW_SESSION_NAME=Codex E2E Session\\n'
        fi
        if [[ -t 1 ]]; then
          tick=0
          while true; do
            printf 'YAAW_STREAM_TICK=%s\\n' "$tick"
            tick=$((tick + 1))
            sleep 0.05
          done
        fi
        """

    private static let claudeDouble = """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "${1:-}" == "--help" ]]; then
          printf '%s\\n' 'Usage: claude [options]'
          printf '%s\\n' '  --permission-mode <mode>  plan, auto, acceptEdits, dontAsk, bypassPermissions'
          exit 0
        fi
        if [[ "${1:-}" == "--version" ]]; then
          printf 'claude 2.1.161\\n'
          exit 0
        fi
        if [[ "${1:-}" == "--resume" ]]; then
          printf 'YAAW_SESSION_ID=%s\\n' "$2"
          printf 'YAAW_SESSION_NAME=Claude Resumed %s\\n' "$2"
        else
          printf 'YAAW_SESSION_ID=claude-e2e-001\\n'
          printf 'YAAW_SESSION_NAME=Claude E2E Session\\n'
        fi
        if [[ -t 1 ]]; then
          while true; do sleep 1; done
        fi
        """

    private static let opencodeDouble = """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "${1:-}" == "--help" ]]; then
          printf '%s\\n' 'Usage: opencode [command] [options]'
          printf '%s\\n' '  run'
          printf '%s\\n' '  serve'
          exit 0
        fi
        if [[ "${1:-}" == "--version" ]]; then
          printf 'opencode 1.4.6\\n'
          exit 0
        fi
        if [[ "${1:-}" == "--session" ]]; then
          printf 'YAAW_SESSION_ID=%s\\n' "$2"
          printf 'YAAW_SESSION_NAME=OpenCode Resumed %s\\n' "$2"
        else
          printf 'YAAW_SESSION_ID=opencode-e2e-001\\n'
          printf 'YAAW_SESSION_NAME=OpenCode E2E Session\\n'
        fi
        if [[ -t 1 ]]; then
          while true; do sleep 1; done
        fi
        """

    private static let copilotDouble = """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "${1:-}" == "--help" ]]; then
          printf '%s\\n' 'Usage: copilot [options]'
          printf '%s\\n' '  --plan'
          printf '%s\\n' '  --autopilot'
          printf '%s\\n' '  --allow-all-tools'
          printf '%s\\n' '  --allow-all'
          printf '%s\\n' '  --yolo'
          exit 0
        fi
        if [[ "${1:-}" == "--version" ]]; then
          printf 'copilot 1.0.51\\n'
          exit 0
        fi
        if [[ "${1:-}" == --resume=* ]]; then
          session="${1#--resume=}"
          printf 'YAAW_SESSION_ID=%s\\n' "$session"
          printf 'YAAW_SESSION_NAME=Copilot Resumed %s\\n' "$session"
        else
          printf 'YAAW_SESSION_ID=copilot-e2e-001\\n'
          printf 'YAAW_SESSION_NAME=Copilot E2E Session\\n'
        fi
        if [[ -t 1 ]]; then
          while true; do sleep 1; done
        fi
        """

    private static func editorDouble(label: String) -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '\(label) %s\\n' "${*:-}"
        sleep 1
        """
    }

    private static let lazygitDouble = """
        #!/usr/bin/env bash
        set -euo pipefail
        printf 'LAZYGIT_DOUBLE\\n'
        sleep 1
        """
}
