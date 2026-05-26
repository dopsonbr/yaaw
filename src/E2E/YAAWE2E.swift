import Foundation
import YAAWKit

@main
struct YAAWE2E {
    static func main() throws {
        let options = try E2EOptions(arguments: CommandLine.arguments)
        let runner = E2ERunner(artifactsDirectory: options.artifactsDirectory)
        try runner.run()
    }
}

private struct E2EOptions {
    let artifactsDirectory: URL

    init(arguments: [String]) throws {
        guard let artifactsIndex = arguments.firstIndex(of: "--artifacts"),
            artifactsIndex + 1 < arguments.count
        else {
            throw E2EFailure("usage: YAAWE2E --artifacts <directory>")
        }
        artifactsDirectory = URL(fileURLWithPath: arguments[artifactsIndex + 1], isDirectory: true)
    }
}

private final class E2ERunner {
    private let artifactsDirectory: URL
    private let fileManager = FileManager.default
    private lazy var paths = E2EPaths(root: artifactsDirectory)

    init(artifactsDirectory: URL) {
        self.artifactsDirectory = artifactsDirectory
    }

    func run() throws {
        try resetArtifacts()
        try writeFixtureProject()
        try writeCommandDoubles()
        try YAMLConfigurationStore(path: paths.configPath).save(YAAWConfiguration())

        let focusedBehavior = try runFocusedBehaviorAssertions()
        try writeVisualStateDatabases(selectedThreadID: focusedBehavior.codexThreadID)
        try assertStateDatabasesAvoidProtectedUserDirectories()
        try writeManifest(focusedBehavior: focusedBehavior)
    }

    private func resetArtifacts() throws {
        if fileManager.fileExists(atPath: artifactsDirectory.path) {
            try fileManager.removeItem(at: artifactsDirectory)
        }
        try fileManager.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.missingToolBinDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.workspaceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.projectDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.captureDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.activityDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.helperBinDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.screenshotDirectory, withIntermediateDirectories: true)
    }

    private func writeFixtureProject() throws {
        try fileManager.createDirectory(
            at: paths.projectDirectory.appendingPathComponent("src/App", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        # YAAW E2E README

        ```mermaid
        graph TD
          A[Start] --> B[Browser]
        ```
        """.write(
            to: paths.projectDirectory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "<!doctype html><title>YAAW Preview</title><h1>Browser Preview</h1>\n".write(
            to: paths.projectDirectory.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
          <text x="8" y="25">YAAW</text>
        </svg>
        """.write(
            to: paths.projectDirectory.appendingPathComponent("diagram.svg"),
            atomically: true,
            encoding: .utf8
        )
        try "print(\"fixture\")\n".write(
            to: paths.projectDirectory.appendingPathComponent("src/App/RootView.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "E2E_SECRET=not-real\n".write(
            to: paths.projectDirectory.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try fileManager.createDirectory(
            at: paths.projectDirectory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ignored\n".write(
            to: paths.projectDirectory.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeCommandDoubles() throws {
        try writeExecutable(
            named: "codex",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
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
                  while true; do sleep 1; done
                fi
                """
        )
        try writeExecutable(
            named: "claude",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
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
        )
        try writeExecutable(
            named: "opencode",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
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
        )
        try writeExecutable(
            named: "copilot",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
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
        )
        try writeExecutable(
            named: "nvim",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
                printf 'NVIM_DOUBLE %s\\n' "${*:-}"
                sleep 1
                """
        )
        try writeExecutable(
            named: "lazygit",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
                printf 'LAZYGIT_DOUBLE\\n'
                sleep 1
                """
        )
        try writeExecutable(
            named: "vim",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
                printf 'VIM_DOUBLE %s\\n' "${*:-}"
                sleep 1
                """
        )
        try writeExecutable(
            named: "vi",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
                printf 'VI_DOUBLE %s\\n' "${*:-}"
                sleep 1
                """
        )
        try writeExecutable(
            named: "git",
            contents: """
                #!/usr/bin/env bash
                set -euo pipefail
                printf 'GIT_DOUBLE %s\\n' "${*:-}"
                sleep 1
                """
        )
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

    private func runFocusedBehaviorAssertions() throws -> FocusedBehaviorResult {
        let databasePath = paths.stateDirectory.appendingPathComponent("focused-behavior.sqlite")
        let model = try makeModel(databasePath: databasePath)
        let settingsText = try String(contentsOf: paths.configPath, encoding: .utf8)
        try assert(settingsText.contains("externalOpen:"), "settings YAML exposes externalOpen")
        try assert(
            settingsText.contains("default: zed"),
            "settings YAML exposes the default external-open destination")
        try assert(settingsText.contains("fonts:"), "settings YAML exposes font settings")
        try assert(
            settingsText.contains("interfaceFamily: system"),
            "settings YAML exposes the interface font family")
        try assert(
            settingsText.contains("editorFamily: system-monospace"),
            "settings YAML exposes the editor font family")
        try assert(
            settingsText.contains("terminalFamily: \"\""),
            "settings YAML exposes the Ghostty-default terminal font family")
        let detectedExternalTools: Set<ExternalOpenToolID> = [.vscode, .finder]
        try assert(
            ExternalOpenToolResolver.defaultTool(
                settings: model.configuration.tools.externalOpen,
                detectedTools: detectedExternalTools
            ) == .vscode,
            "external-open default falls back to first detected preferred destination"
        )
        try assert(
            model.selectedProject?.displayName == "E2E Sandbox",
            "initial launch selected the seeded sandbox project")
        try assert(
            model.selectedProject?.rootDirectory == paths.workspaceDirectory,
            "initial launch used an E2E sandbox root")
        try assert(
            model.selectedExternalOpenDirectoryTarget
                == ExternalOpenTarget(url: paths.workspaceDirectory, kind: .directory),
            "external-open target falls back to selected project when no thread is selected"
        )

        try model.createProject(displayName: "E2E Project", rootDirectory: paths.projectDirectory)
        try assert(
            model.selectedProject?.rootDirectory == paths.projectDirectory,
            "project creation selected the fixture project")
        try assert(
            model.selectedExternalOpenDirectoryTarget
                == ExternalOpenTarget(url: paths.projectDirectory, kind: .directory),
            "external-open target follows the selected project before thread creation"
        )
        let e2eProjectID = try unwrap(model.selectedProject?.id, "fixture project id exists")
        let sandboxProjectID = try unwrap(
            model.projects.first { $0.displayName == "E2E Sandbox" }?.id,
            "sandbox project id exists"
        )
        let sandboxThreadID = try model.createThread(
            projectID: sandboxProjectID,
            agentCLI: .codex,
            displayName: "  Sandbox Named Thread  "
        )
        try assert(
            model.selectedProjectID == sandboxProjectID,
            "project-row thread creation selected the target project")
        try assert(
            model.selectedThread?.displayName == "Sandbox Named Thread",
            "project-row thread creation accepted optional name")
        try assert(
            model.activeThreads(for: sandboxProjectID).contains { $0.id == sandboxThreadID },
            "targeted thread appeared under its project")
        try assert(
            model.isProjectExpanded(sandboxProjectID),
            "targeted project expanded after creating a thread")
        model.toggleProjectPinned(id: e2eProjectID)
        try assert(model.projects.first?.id == e2eProjectID, "pinned project sorted first")
        model.toggleThreadPinned(id: sandboxThreadID)
        try assert(
            model.activeThreads(for: sandboxProjectID).first?.id == sandboxThreadID,
            "pinned thread sorted first")
        model.selectProject(id: e2eProjectID)

        let codexThreadID = try model.createThread(agentCLI: .codex)
        try assert(
            model.selectedThread?.agentCLI == .codex, "codex choice created a codex-backed thread")
        try assert(
            model.selectedExternalOpenDirectoryTarget
                == ExternalOpenTarget(url: paths.projectDirectory, kind: .directory),
            "external-open target follows the selected thread working directory"
        )
        model.recordAgentCLIOutput(
            threadID: codexThreadID,
            output: "YAAW_SESSION_ID=codex-e2e-001\nYAAW_SESSION_NAME=Codex E2E Session\n"
        )
        try assert(
            model.selectedThread?.displayName == "Codex E2E Session",
            "codex CLI metadata renamed the thread")
        try model.requestThreadRename(id: codexThreadID, to: "Codex Renamed E2E")
        try assert(
            model.selectedThread?.displayName == "Codex E2E Session",
            "queued context-menu rename left the confirmed codex name visible")
        try assert(
            model.selectedThread?.pendingSessionRename == "Codex Renamed E2E",
            "queued context-menu rename persisted pending intent")
        let renameSession = try unwrap(
            model.terminalSession(for: .project(threadID: codexThreadID)),
            "rename relaunch terminal session")
        if case .agentPTY(let renameLaunch) = renameSession.request.backend {
            try assert(
                renameLaunch.startupInput == "/rename Codex Renamed E2E\n",
                "rename relaunch queued slash command startup input")
            try assert(
                renameLaunch.command.joined(separator: " ").contains("codex-e2e-001"),
                "rename relaunch resumed the stored codex session")
        } else {
            throw E2EFailure("rename relaunch did not use an agent PTY")
        }
        model.recordAgentCLIOutput(
            threadID: codexThreadID,
            output: "YAAW_SESSION_ID=codex-e2e-001\nYAAW_SESSION_NAME=Codex Renamed E2E\n"
        )
        try assert(
            model.selectedThread?.displayName == "Codex Renamed E2E",
            "manual slash rename metadata updated the project/thread row")
        try assert(
            model.selectedThread?.pendingSessionRename == nil,
            "confirmed slash rename cleared pending intent")
        try runYAAWNotify(
            threadID: codexThreadID,
            status: "needs-input",
            title: "Approval needed",
            body: "Review fixture command"
        )
        model.pollAgentCLIActivityLogs()
        try assert(
            model.threadActivity(for: codexThreadID).status == .needsInput,
            "helper notification marked codex thread as needing input"
        )
        try assert(
            model.threadActivity(for: codexThreadID).preview == "Review fixture command",
            "helper notification preview was captured"
        )
        try assert(
            model.threadActivity(for: codexThreadID).isUnread,
            "helper notification marked codex thread unread")
        model.recordAgentTerminalFocus(threadID: codexThreadID, focused: true)
        try assert(
            !model.threadActivity(for: codexThreadID).isUnread,
            "focused codex terminal cleared unread notification")
        model.recordAgentTerminalNotification(
            threadID: codexThreadID, title: "Task complete", body: "Fixture tests passed")
        try assert(
            model.threadActivity(for: codexThreadID).status == .complete,
            "OSC-style terminal notification marked codex thread complete"
        )

        let claudeThreadID = try model.createThread(agentCLI: .claude)
        model.recordAgentCLIOutput(
            threadID: claudeThreadID,
            output: "YAAW_SESSION_ID=claude-e2e-001\nYAAW_SESSION_NAME=Claude E2E Session\n"
        )
        try assert(
            model.selectedThread?.displayName == "Claude E2E Session",
            "claude CLI metadata renamed the thread")

        let opencodeThreadID = try model.createThread(agentCLI: .opencode)
        model.recordAgentCLIOutput(
            threadID: opencodeThreadID,
            output: "YAAW_SESSION_ID=opencode-e2e-001\nYAAW_SESSION_NAME=OpenCode E2E Session\n"
        )
        try assert(
            model.selectedThread?.displayName == "OpenCode E2E Session",
            "opencode CLI metadata renamed the thread")

        let copilotThreadID = try model.createThread(agentCLI: .copilot)
        model.recordAgentCLIOutput(
            threadID: copilotThreadID,
            output: "YAAW_SESSION_ID=copilot-e2e-001\nYAAW_SESSION_NAME=Copilot E2E Session\n"
        )
        try assert(
            model.selectedThread?.displayName == "Copilot E2E Session",
            "copilot CLI metadata renamed the thread")

        model.selectThread(id: codexThreadID)
        model.reloadConfiguration(
            YAAWConfiguration(
                theme: ThemeSettings(active: "light-high-contrast"),
                fonts: FontSettings(
                    interfaceFamily: "Avenir Next",
                    interfaceSize: 14,
                    editorFamily: "SF Mono",
                    editorSize: 15,
                    terminalFamily: "JetBrains Mono",
                    terminalSize: 16
                )
            )
        )
        try assert(
            model.configuration.themeName == "light-high-contrast",
            "settings reload applied selected built-in theme")
        try assert(
            model.configuration.resolvedTheme.group == .highContrast,
            "selected theme resolved to high contrast group")
        try assert(
            model.configuration.fonts.interfaceFamily == "Avenir Next",
            "settings reload applied interface font family")
        try assert(
            model.configuration.fonts.interfaceSize == 14,
            "settings reload applied interface font size")
        try assert(
            model.configuration.fonts.editorFamily == "SF Mono",
            "settings reload applied editor font family")
        try assert(
            model.configuration.fonts.editorSize == 15,
            "settings reload applied editor font size")
        try assert(
            model.configuration.fonts.terminalFamily == "JetBrains Mono",
            "settings reload applied terminal font family")
        try assert(
            model.configuration.fonts.terminalSize == 16,
            "settings reload applied terminal font size")
        try assert(
            model.selectedThread?.id == codexThreadID,
            "appearance settings reload preserved selected thread")

        model.refreshSelectedFileBrowser()
        try waitUntil("file index contains README.md") {
            model.fileBrowserState.visibleEntries.contains { $0.relativePath == "README.md" }
        }
        model.selectThread(id: claudeThreadID)
        try assert(
            model.fileBrowserState.visibleEntries.contains { $0.relativePath == "README.md" },
            "same-directory thread reused the shared file index cache without a blank files state"
        )
        model.selectThread(id: codexThreadID)
        model.updateFileSearchQuery("root")
        try assert(
            model.fileBrowserState.visibleEntries.first?.relativePath == "src/App/RootView.swift",
            "fuzzy search preferred RootView.swift"
        )
        try assert(
            model.openFileInBrowser(relativePath: "index.html"),
            "HTML fixture opened in Browser mode")
        try assert(
            model.selectedRightPanelMode == .browser, "browser preview selected Browser mode")
        try assert(
            model.selectedRightPanelTab.relativePath == "index.html",
            "browser tab tracked HTML relative path")
        try assert(
            model.selectedRightPanelTab.urlString
                == paths.projectDirectory.appendingPathComponent("index.html").standardizedFileURL
                .absoluteString,
            "browser tab loaded HTML fixture file URL"
        )
        try assert(
            model.openFileInBrowser(relativePath: "diagram.svg"),
            "SVG fixture opened in Browser mode")
        try assert(
            model.selectedRightPanelTab.relativePath == "diagram.svg",
            "browser tab tracked SVG relative path")
        let browserTabIDs = model.selectedRightPanelState.tabs.filter { $0.kind == .browser }.map(
            \.id)
        try assert(
            browserTabIDs.contains(
                RightPanelTab.browserTabID(urlString: nil, relativePath: "index.html"))
                && browserTabIDs.contains(
                    RightPanelTab.browserTabID(urlString: nil, relativePath: "diagram.svg")),
            "browser tabs included HTML and SVG preview files"
        )
        try assert(
            model.openFileInBrowser(relativePath: "README.md"),
            "Markdown fixture opened in Browser mode")
        try assert(
            model.selectedRightPanelTab.relativePath == "README.md",
            "browser tab tracked Markdown relative path")
        model.openBrowserTab(urlString: "example.com")
        try assert(
            model.selectedRightPanelTab.urlString == "https://example.com",
            "typed browser URL normalized")
        model.openFileInNvim(relativePath: "src/App/RootView.swift")
        try assert(
            model.externalOpenFileTarget(relativePath: "src/App/RootView.swift")
                == ExternalOpenTarget(
                    url: paths.projectDirectory.appendingPathComponent("src/App/RootView.swift")
                        .standardizedFileURL,
                    kind: .file
                ),
            "external-open file target uses the selected thread working directory"
        )
        let nvimRequest = try unwrap(
            model.terminalLaunchRequest(for: .nvim(threadID: codexThreadID)),
            "nvim request exists"
        )
        let nvimCommandSuffix = Array(nvimRequest.command.suffix(2))
        try assert(
            nvimCommandSuffix == ["nvim", "src/App/RootView.swift"]
                || nvimCommandSuffix == [
                    paths.binDirectory.appendingPathComponent("nvim").path,
                    "src/App/RootView.swift",
                ],
            "nvim request included the selected relative path"
        )

        model.selectRightPanelMode(.git)
        let gitRequest = try unwrap(
            model.terminalLaunchRequest(for: .lazygit(threadID: codexThreadID)),
            "git request exists"
        )
        try assert(
            gitRequest.command.last?.hasSuffix("/lazygit") == true, "git mode launched lazygit")
        try assertMissingLazygitFallsBackToGitDiff()
        try assertMissingNvimFallsBackToVimThenVi()
        try assertImagePastePolicyUsesNativeShortcut()
        try assertMissingDirectoryRecovery()
        try assertUnboundThreadLinkRecovery()

        model.toggleBottomTerminal()
        model.setRightPanelWidth(960)
        model.setSidebarWidth(320)
        model.setGlobalTerminalHeight(240)
        model.toggleWorkspaceSwap()
        model.toggleRightPanelCollapsed()
        model.toggleRightPanelCollapsed()
        model.archiveThread(id: claudeThreadID)
        try assert(
            model.archivedThreadsForSelectedProject.contains { $0.id == claudeThreadID },
            "archive moved the claude thread")

        let service = makeAgentCLIService()
        let freshCodexMetadata = try service.captureMetadataByRunningCLI(
            kind: .codex,
            workingDirectory: paths.projectDirectory,
            environment: environment
        )
        try assert(
            freshCodexMetadata.identity == "codex-e2e-001",
            "codex command double reported deterministic identity")
        let resumedClaudeMetadata = try service.captureMetadataByRunningCLI(
            kind: .claude,
            resumeIdentity: "claude-e2e-001",
            workingDirectory: paths.projectDirectory,
            environment: environment
        )
        try assert(
            resumedClaudeMetadata.canonicalName == "Claude Resumed claude-e2e-001",
            "claude command double reported deterministic resume metadata"
        )
        let resumedOpenCodeMetadata = try service.captureMetadataByRunningCLI(
            kind: .opencode,
            resumeIdentity: "opencode-e2e-001",
            workingDirectory: paths.projectDirectory,
            environment: environment
        )
        try assert(
            resumedOpenCodeMetadata.canonicalName == "OpenCode Resumed opencode-e2e-001",
            "opencode command double reported deterministic resume metadata"
        )
        let resumedCopilotMetadata = try service.captureMetadataByRunningCLI(
            kind: .copilot,
            resumeIdentity: "copilot-e2e-001",
            workingDirectory: paths.projectDirectory,
            environment: environment
        )
        try assert(
            resumedCopilotMetadata.canonicalName == "Copilot Resumed copilot-e2e-001",
            "copilot command double reported deterministic resume metadata"
        )

        let reloadedModel = try makeModel(databasePath: databasePath)
        try assert(
            reloadedModel.selectedThread?.id == codexThreadID,
            "relaunch preserved selected codex thread")
        try assert(
            reloadedModel.selectedThread?.sessionIdentity == "codex-e2e-001",
            "relaunch preserved codex session identity")
        try assert(
            reloadedModel.layoutState.sidebarWidth == 320,
            "relaunch preserved resized sidebar width")
        try assert(
            reloadedModel.layoutState.rightPanelWidth == 960,
            "relaunch preserved resized right panel width")
        try assert(
            reloadedModel.layoutState.isWorkspaceSwapped,
            "relaunch preserved swapped main and right panels")
        try assert(
            reloadedModel.layoutState.globalTerminalHeight == 240,
            "relaunch preserved resized bottom terminal height"
        )
        let resumedRequest = try unwrap(
            reloadedModel.activateSelectedProjectTerminal(), "resumed project terminal exists")
        let resumedCommand = resumedRequest.request.command.joined(separator: " ")
        try assert(
            resumedCommand.contains("resume")
                && resumedCommand.contains("codex-e2e-001"),
            "reopened codex thread resumed the stored session identity"
        )

        return FocusedBehaviorResult(
            databasePath: databasePath,
            codexThreadID: codexThreadID,
            claudeThreadID: claudeThreadID
        )
    }

    private func writeVisualStateDatabases(selectedThreadID: UUID) throws {
        for state in VisualState.allCases {
            let databasePath = paths.stateDirectory.appendingPathComponent(
                "\(state.rawValue).sqlite")
            let model = try makeFixtureOnlyModel(databasePath: databasePath)
            if state == .projectCreation {
                continue
            }
            let threadID = try model.createThread(agentCLI: .codex)
            model.recordAgentCLIOutput(
                threadID: threadID,
                output: "YAAW_SESSION_ID=codex-e2e-001\nYAAW_SESSION_NAME=Codex E2E Session\n"
            )
            if state == .missingDirectory {
                let missingRoot = paths.missingDirectory
                try fileManager.createDirectory(at: missingRoot, withIntermediateDirectories: true)
                try model.createProject(
                    displayName: "Missing Directory Project", rootDirectory: missingRoot)
                _ = try model.createThread(agentCLI: .codex)
                try fileManager.removeItem(at: missingRoot)
                continue
            }
            switch state {
            case .launch, .projectCreation, .missingDirectory:
                break
            case .files:
                model.refreshSelectedFileBrowser()
                try waitUntil("visual files state indexed README.md") {
                    model.fileBrowserState.visibleEntries.contains {
                        $0.relativePath == "README.md"
                    }
                }
            case .nvim:
                model.openFileInNvim(relativePath: "README.md")
            case .git:
                model.selectRightPanelMode(.git)
            case .missingTool:
                model.selectRightPanelMode(.git)
            case .bottomTerminal:
                model.toggleBottomTerminal()
            case .panelResize:
                model.setSidebarWidth(360)
                model.setRightPanelWidth(960)
                model.setGlobalTerminalHeight(260)
                model.toggleWorkspaceSwap()
                model.toggleBottomTerminal()
            case .panelCollapse:
                model.toggleSidebarCollapsed()
                model.toggleRightPanelCollapsed()
            case .keyboardInput:
                break
            }
        }
        _ = selectedThreadID
    }

    private func assertMissingLazygitFallsBackToGitDiff() throws {
        let databasePath = paths.stateDirectory.appendingPathComponent("missing-lazygit.sqlite")
        let store = try makeSandboxSeededStore(databasePath: databasePath)
        let configuration = YAMLConfigurationStore(path: paths.configPath).load()
        var missingToolEnvironment = environment
        missingToolEnvironment["PATH"] =
            paths.missingToolBinDirectory.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let model = AppModel(
            store: store,
            agentCLIBindings: AgentCLISessionBindingService(
                environment: missingToolEnvironment,
                captureDirectory: paths.captureDirectory,
                activityDirectory: paths.activityDirectory,
                helperBinDirectory: paths.helperBinDirectory
            ),
            fileIndexer: ImmediateFileIndexer(),
            externalToolResolver: PATHAgentCLIExecutableResolver(fallbackSearchPaths: []),
            configuration: configuration,
            environment: missingToolEnvironment
        )
        try model.createProject(
            displayName: "Missing Tool Project", rootDirectory: paths.projectDirectory)
        let threadID = try model.createThread(agentCLI: .codex)
        model.selectRightPanelMode(.git)
        let request = try unwrap(
            model.terminalLaunchRequest(for: .lazygit(threadID: threadID)),
            "missing lazygit request")
        try assert(
            request.command == ["git", "--no-pager", "diff"]
                || request.command == [
                    paths.missingToolBinDirectory.appendingPathComponent("git").path, "--no-pager",
                    "diff",
                ]
                || request.command == ["/usr/bin/git", "--no-pager", "diff"],
            "missing lazygit fell back to git --no-pager diff"
        )
    }

    private func assertMissingNvimFallsBackToVimThenVi() throws {
        let databasePath = paths.stateDirectory.appendingPathComponent("missing-nvim.sqlite")
        let configuration = YAMLConfigurationStore(path: paths.configPath).load()
        let nvimPath = paths.missingToolBinDirectory.appendingPathComponent("nvim")
        if fileManager.fileExists(atPath: nvimPath.path) {
            try fileManager.removeItem(at: nvimPath)
        }
        var missingToolEnvironment = environment
        missingToolEnvironment["PATH"] = paths.missingToolBinDirectory.path
        let model = AppModel(
            store: try makeSandboxSeededStore(databasePath: databasePath),
            agentCLIBindings: AgentCLISessionBindingService(
                environment: missingToolEnvironment,
                captureDirectory: paths.captureDirectory,
                activityDirectory: paths.activityDirectory,
                helperBinDirectory: paths.helperBinDirectory
            ),
            fileIndexer: ImmediateFileIndexer(),
            externalToolResolver: PATHAgentCLIExecutableResolver(fallbackSearchPaths: []),
            configuration: configuration,
            environment: missingToolEnvironment
        )
        try model.createProject(
            displayName: "Missing nvim Project", rootDirectory: paths.projectDirectory)
        let threadID = try model.createThread(agentCLI: .codex)
        model.openFileInNvim(relativePath: "README.md")
        let request = try unwrap(
            model.terminalLaunchRequest(for: .nvim(threadID: threadID)), "missing nvim request")
        try assert(
            Array(request.command.suffix(2)) == [
                paths.missingToolBinDirectory.appendingPathComponent("vim").path, "README.md",
            ],
            "missing nvim fell back to vim"
        )

        let vimPath = paths.missingToolBinDirectory.appendingPathComponent("vim")
        try fileManager.removeItem(at: vimPath)
        let viRequest = try unwrap(
            model.terminalLaunchRequest(for: .nvim(threadID: threadID)),
            "missing nvim and vim request")
        try assert(
            Array(viRequest.command.suffix(2)) == [
                paths.missingToolBinDirectory.appendingPathComponent("vi").path, "README.md",
            ],
            "missing nvim and vim fell back to vi"
        )
    }

    private func assertImagePastePolicyUsesNativeShortcut() throws {
        let policy = TerminalImagePastePolicy()

        for cli in AgentCLIKind.allCases {
            let text = policy.textForImagePaste(agentCLI: cli)
            try assert(
                text == TerminalImagePastePolicy.nativeAttachmentShortcutText,
                "\(cli.displayName) image paste uses native attachment shortcut"
            )
            try assert(
                !text.contains("Attached image:"),
                "\(cli.displayName) image paste avoids path formatter")
            try assert(
                !text.contains(paths.root.path),
                "\(cli.displayName) image paste does not expose sandbox path")
        }
    }

    private func assertMissingDirectoryRecovery() throws {
        let databasePath = paths.stateDirectory.appendingPathComponent(
            "missing-directory-recovery.sqlite")
        let recoverableRoot = paths.root.appendingPathComponent(
            "recoverable-project", isDirectory: true)
        try fileManager.createDirectory(at: recoverableRoot, withIntermediateDirectories: true)
        let model = try makeModel(databasePath: databasePath)
        try model.createProject(displayName: "Recoverable Project", rootDirectory: recoverableRoot)
        let threadID = try model.createThread(agentCLI: .codex)
        model.recordAgentCLIOutput(
            threadID: threadID,
            output:
                "YAAW_SESSION_ID=codex-missing-directory\nYAAW_SESSION_NAME=Missing Directory\n"
        )
        try fileManager.removeItem(at: recoverableRoot)

        try assert(
            model.selectedThreadWorkingDirectoryState == .missing(path: recoverableRoot.path),
            "deleted directory reported missing")
        try assert(
            model.terminalLaunchRequest(for: .project(threadID: threadID)) == nil,
            "missing directory blocked terminal launch")
        model.refreshSelectedFileBrowser()
        try assert(
            model.fileBrowserState.errorMessage
                == "Missing working directory: \(recoverableRoot.path)",
            "missing directory surfaced in file browser")

        try fileManager.createDirectory(at: recoverableRoot, withIntermediateDirectories: true)
        try "restored\n".write(
            to: recoverableRoot.appendingPathComponent("RESTORED.md"),
            atomically: true,
            encoding: .utf8
        )
        let reloadedModel = try makeModel(databasePath: databasePath)
        try assert(
            reloadedModel.selectedThreadWorkingDirectoryState
                == .available(path: recoverableRoot.path),
            "restored directory reported available after reload"
        )
        try assert(
            reloadedModel.terminalLaunchRequest(for: .project(threadID: threadID)) != nil,
            "restored directory allowed terminal launch after reload"
        )
    }

    private func assertUnboundThreadLinkRecovery() throws {
        let databasePath = paths.stateDirectory.appendingPathComponent(
            "unbound-thread-link.sqlite")
        let store = try SQLiteYAAWStore(databasePath: databasePath)
        let projectID = UUID()
        let threadID = UUID()
        store.save(
            YAAWSnapshot(
                projects: [
                    Project(
                        id: projectID,
                        displayName: "Unbound Project",
                        rootDirectory: paths.projectDirectory
                    )
                ],
                threads: [
                    AgentThread(
                        id: threadID,
                        displayName: "Legacy Thread",
                        projectID: projectID,
                        workingDirectory: paths.projectDirectory,
                        agentCLI: .codex
                    )
                ],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        let model = try makeModel(databasePath: databasePath)
        try assert(model.selectedThreadRequiresSessionLink, "unbound loaded thread required link")
        try assert(
            model.terminalLaunchRequest(for: .project(threadID: threadID)) == nil,
            "unbound loaded thread did not silently start a fresh session")

        let candidate = SessionLinkCandidate(
            identity: "codex-linked-e2e",
            displayName: "Linked E2E Session",
            agentCLI: .codex,
            workingDirectory: paths.projectDirectory,
            source: "fixture"
        )
        model.linkSession(threadID: threadID, candidate: candidate)
        try assert(!model.selectedThreadRequiresSessionLink, "link selection cleared link state")
        let linkedSession = try unwrap(
            model.activateSelectedProjectTerminal(),
            "linked project terminal session")
        try assert(
            linkedSession.request.command.joined(separator: " ").contains("codex-linked-e2e"),
            "linked session resumed the selected identity")

        let secondThreadID = UUID()
        store.save(
            YAAWSnapshot(
                projects: [
                    Project(
                        id: projectID,
                        displayName: "Unbound Project",
                        rootDirectory: paths.projectDirectory
                    )
                ],
                threads: [
                    AgentThread(
                        id: secondThreadID,
                        displayName: "Start Fresh",
                        projectID: projectID,
                        workingDirectory: paths.projectDirectory,
                        agentCLI: .codex
                    )
                ],
                selectedProjectID: projectID,
                selectedThreadID: secondThreadID,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        let startNewModel = try makeModel(databasePath: databasePath)
        try assert(
            startNewModel.selectedThreadRequiresSessionLink,
            "second unbound thread required link")
        startNewModel.startNewSessionForUnlinkedThread(threadID: secondThreadID)
        let freshSession = try unwrap(
            startNewModel.activateSelectedProjectTerminal(),
            "fresh project terminal session")
        try assert(
            !freshSession.request.command.joined(separator: " ").contains(" resume "),
            "explicit start-new action launched a fresh CLI session")
    }

    private func assertStateDatabasesAvoidProtectedUserDirectories() throws {
        let databaseURLs = try fileManager.contentsOfDirectory(
            at: paths.stateDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "sqlite" }
        let protectedDirectories = protectedUserDirectories()

        for databaseURL in databaseURLs {
            let snapshot = try SQLiteYAAWStore(databasePath: databaseURL).load()
            for project in snapshot.projects {
                try assert(
                    !protectedDirectories.containsPath(project.rootDirectory.path),
                    "\(databaseURL.lastPathComponent) project root avoided protected user folders"
                )
            }
            for thread in snapshot.threads {
                try assert(
                    !protectedDirectories.containsPath(thread.workingDirectory.path),
                    "\(databaseURL.lastPathComponent) thread working directory avoided protected user folders"
                )
            }
        }
    }

    private func protectedUserDirectories() -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [home.standardizedFileURL.path]
            + [
                "Desktop",
                "Documents",
                "Downloads",
                "Music",
                "Movies",
                "Pictures",
            ].map { home.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path }
    }

    private func writeManifest(focusedBehavior: FocusedBehaviorResult) throws {
        let manifest = """
            YAAW E2E artifacts

            focused_behavior_database=\(focusedBehavior.databasePath.path)
            codex_thread_id=\(focusedBehavior.codexThreadID.uuidString)
            claude_thread_id=\(focusedBehavior.claudeThreadID.uuidString)
            fixture_project=\(paths.projectDirectory.path)
            sandbox_workspace=\(paths.workspaceDirectory.path)
            fixture_bin=\(paths.binDirectory.path)
            config_path=\(paths.configPath.path)
            screenshots=\(paths.screenshotDirectory.path)
            """
        try manifest.write(
            to: artifactsDirectory.appendingPathComponent("manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = paths.binDirectory.path + ":" + (env["PATH"] ?? "")
        env["YAAW_E2E_CONFIG_PATH"] = paths.configPath.path
        env["YAAW_E2E_CAPTURE_DIRECTORY"] = paths.captureDirectory.path
        return env
    }

    private func makeAgentCLIService() -> AgentCLISessionBindingService {
        AgentCLISessionBindingService(
            environment: environment,
            captureDirectory: paths.captureDirectory,
            activityDirectory: paths.activityDirectory,
            helperBinDirectory: paths.helperBinDirectory
        )
    }

    private func runYAAWNotify(threadID: UUID, status: String, title: String, body: String) throws {
        let helperURL = paths.helperBinDirectory.appendingPathComponent("yaaw-notify")
        if !fileManager.isExecutableFile(atPath: helperURL.path) {
            let thread = AgentThread(
                id: threadID,
                displayName: "Fixture",
                projectID: UUID(),
                workingDirectory: paths.projectDirectory
            )
            _ = makeAgentCLIService().terminalCommand(for: thread)
        }
        let eventLogURL = paths.activityDirectory.appendingPathComponent(
            "\(threadID.uuidString).ndjson")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--status", status, "--title", title, "--body", body]
        process.environment = [
            "YAAW_THREAD_ID": threadID.uuidString,
            "YAAW_EVENT_LOG": eventLogURL.path,
        ]
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        try assert(process.terminationStatus == 0, "yaaw-notify helper exited successfully")
    }

    private func makeModel(databasePath: URL) throws -> AppModel {
        let store = try makeSandboxSeededStore(databasePath: databasePath)
        let configuration = YAMLConfigurationStore(path: paths.configPath).load()
        return AppModel(
            store: store,
            agentCLIBindings: makeAgentCLIService(),
            fileIndexer: ImmediateFileIndexer(),
            configuration: configuration,
            environment: environment
        )
    }

    private func makeSandboxSeededStore(databasePath: URL) throws -> SQLiteYAAWStore {
        let databaseExists = fileManager.fileExists(atPath: databasePath.path)
        let store = try SQLiteYAAWStore(databasePath: databasePath)
        if !databaseExists {
            store.save(sandboxSeedSnapshot())
        }
        return store
    }

    private func sandboxSeedSnapshot() -> YAAWSnapshot {
        let projectID = UUID()
        return YAAWSnapshot(
            projects: [
                Project(
                    id: projectID,
                    displayName: "E2E Sandbox",
                    rootDirectory: paths.workspaceDirectory
                )
            ],
            threads: [],
            selectedProjectID: projectID,
            selectedThreadID: nil,
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false
        )
    }

    private func makeFixtureOnlyModel(databasePath: URL) throws -> AppModel {
        let projectID = UUID()
        let store = try SQLiteYAAWStore(databasePath: databasePath)
        store.save(
            YAAWSnapshot(
                projects: [
                    Project(
                        id: projectID,
                        displayName: "E2E Project",
                        rootDirectory: paths.projectDirectory
                    )
                ],
                threads: [],
                selectedProjectID: projectID,
                selectedThreadID: nil,
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
        return try makeModel(databasePath: databasePath)
    }

    private func waitUntil(_ description: String, condition: () -> Bool) throws {
        for _ in 0..<50 {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw E2EFailure("timed out waiting for \(description)")
    }

    private func unwrap<T>(_ value: T?, _ description: String) throws -> T {
        guard let value else {
            throw E2EFailure("missing \(description)")
        }
        return value
    }

    private func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw E2EFailure("assertion failed: \(message)")
        }
    }
}

private struct E2EPaths {
    let root: URL

    var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
    var missingToolBinDirectory: URL {
        root.appendingPathComponent("bin-missing-lazygit", isDirectory: true)
    }
    var captureDirectory: URL { root.appendingPathComponent("captures", isDirectory: true) }
    var activityDirectory: URL { root.appendingPathComponent("activity", isDirectory: true) }
    var helperBinDirectory: URL { root.appendingPathComponent("helper-bin", isDirectory: true) }
    var configPath: URL { root.appendingPathComponent("config/settings.yaml") }
    var workspaceDirectory: URL {
        root.appendingPathComponent("sandbox-workspace", isDirectory: true)
    }
    var projectDirectory: URL { root.appendingPathComponent("fixture-project", isDirectory: true) }
    var missingDirectory: URL {
        root.appendingPathComponent("missing-directory-project", isDirectory: true)
    }
    var screenshotDirectory: URL { root.appendingPathComponent("screenshots", isDirectory: true) }
    var stateDirectory: URL { root.appendingPathComponent("states", isDirectory: true) }
}

private struct FocusedBehaviorResult {
    var databasePath: URL
    var codexThreadID: UUID
    var claudeThreadID: UUID
}

private enum VisualState: String, CaseIterable {
    case launch
    case projectCreation = "project-creation"
    case files
    case nvim
    case git
    case missingDirectory = "missing-directory"
    case missingTool = "missing-tool"
    case bottomTerminal = "bottom-terminal"
    case panelResize = "panel-resize"
    case panelCollapse = "panel-collapse"
    case keyboardInput = "keyboard-input"
}

private struct E2EFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class ImmediateFileIndexer: FileIndexing {
    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        do {
            let result = try BackgroundFileIndexer.buildIndex(
                threadID: threadID,
                root: root,
                ignoreRules: ignoreRules
            )
            completion(.success(result))
        } catch {
            completion(.failure(error))
        }
    }
}

extension [String] {
    fileprivate func containsPath(_ candidate: String) -> Bool {
        let candidate = URL(fileURLWithPath: candidate).standardizedFileURL.path
        return contains { protected in
            candidate == protected || candidate.hasPrefix(protected + "/")
        }
    }
}
