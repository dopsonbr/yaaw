import AgentIDEKit
import Foundation

@main
struct AgentIDEE2E {
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
              artifactsIndex + 1 < arguments.count else {
            throw E2EFailure("usage: AgentIDEE2E --artifacts <directory>")
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
        try JSONConfigurationStore(path: paths.configPath).save(AgentIDEConfiguration())

        let focusedBehavior = try runFocusedBehaviorAssertions()
        try writeVisualStateDatabases(selectedThreadID: focusedBehavior.codexThreadID)
        try writeManifest(focusedBehavior: focusedBehavior)
    }

    private func resetArtifacts() throws {
        if fileManager.fileExists(atPath: artifactsDirectory.path) {
            try fileManager.removeItem(at: artifactsDirectory)
        }
        try fileManager.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.projectDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.captureDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.screenshotDirectory, withIntermediateDirectories: true)
    }

    private func writeFixtureProject() throws {
        try fileManager.createDirectory(
            at: paths.projectDirectory.appendingPathComponent("src/App", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "Agent IDE E2E README\n".write(
            to: paths.projectDirectory.appendingPathComponent("README.md"),
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
            if [[ "${1:-}" == "resume" ]]; then
              printf 'AGENT_IDE_SESSION_ID=%s\\n' "$2"
              printf 'AGENT_IDE_SESSION_NAME=Codex Resumed %s\\n' "$2"
            else
              printf 'AGENT_IDE_SESSION_ID=codex-e2e-001\\n'
              printf 'AGENT_IDE_SESSION_NAME=Codex E2E Session\\n'
            fi
            """
        )
        try writeExecutable(
            named: "claude",
            contents: """
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ "${1:-}" == "--resume" ]]; then
              printf 'AGENT_IDE_SESSION_ID=%s\\n' "$2"
              printf 'AGENT_IDE_SESSION_NAME=Claude Resumed %s\\n' "$2"
            else
              printf 'AGENT_IDE_SESSION_ID=claude-e2e-001\\n'
              printf 'AGENT_IDE_SESSION_NAME=Claude E2E Session\\n'
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
    }

    private func writeExecutable(named name: String, contents: String) throws {
        let path = paths.binDirectory.appendingPathComponent(name)
        try (contents + "\n").write(to: path, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private func runFocusedBehaviorAssertions() throws -> FocusedBehaviorResult {
        let databasePath = paths.stateDirectory.appendingPathComponent("focused-behavior.sqlite")
        let model = try makeModel(databasePath: databasePath)
        try assert(model.selectedProject?.displayName == "Global", "initial launch selected the seeded global project")

        try model.createProject(displayName: "E2E Project", rootDirectory: paths.projectDirectory)
        try assert(model.selectedProject?.rootDirectory == paths.projectDirectory, "project creation selected the fixture project")

        let codexThreadID = try model.createThread(agentCLI: .codex)
        try assert(model.selectedThread?.agentCLI == .codex, "codex choice created a codex-backed thread")
        model.recordAgentCLIOutput(
            threadID: codexThreadID,
            output: "AGENT_IDE_SESSION_ID=codex-e2e-001\nAGENT_IDE_SESSION_NAME=Codex E2E Session\n"
        )
        try assert(model.selectedThread?.displayName == "Codex E2E Session", "codex CLI metadata renamed the thread")

        let claudeThreadID = try model.createThread(agentCLI: .claude)
        model.recordAgentCLIOutput(
            threadID: claudeThreadID,
            output: "AGENT_IDE_SESSION_ID=claude-e2e-001\nAGENT_IDE_SESSION_NAME=Claude E2E Session\n"
        )
        try assert(model.selectedThread?.displayName == "Claude E2E Session", "claude CLI metadata renamed the thread")

        model.selectThread(id: codexThreadID)
        model.refreshSelectedFileBrowser()
        try waitUntil("file index contains README.md") {
            model.fileBrowserState.visibleEntries.contains { $0.relativePath == "README.md" }
        }
        model.updateFileSearchQuery("root")
        try assert(
            model.fileBrowserState.visibleEntries.first?.relativePath == "src/App/RootView.swift",
            "fuzzy search preferred RootView.swift"
        )
        model.openFileInNvim(relativePath: "src/App/RootView.swift")
        let nvimRequest = try unwrap(
            model.terminalLaunchRequest(for: .nvim(threadID: codexThreadID)),
            "nvim request exists"
        )
        let nvimCommandSuffix = Array(nvimRequest.command.suffix(2))
        try assert(
            nvimCommandSuffix == ["nvim", "src/App/RootView.swift"]
                || nvimCommandSuffix == [paths.binDirectory.appendingPathComponent("nvim").path, "src/App/RootView.swift"],
            "nvim request included the selected relative path"
        )

        model.selectRightPanelMode(.git)
        let gitRequest = try unwrap(
            model.terminalLaunchRequest(for: .lazygit(threadID: codexThreadID)),
            "git request exists"
        )
        try assert(gitRequest.command.last?.hasSuffix("/lazygit") == true, "git mode launched lazygit")
        try assertMissingLazygitFallsBackToRawCommand()

        model.toggleGlobalTerminal()
        model.setRightPanelWidth(420)
        model.setSidebarWidth(280)
        model.toggleRightPanelCollapsed()
        model.toggleRightPanelCollapsed()
        model.archiveThread(id: claudeThreadID)
        try assert(model.archivedThreadsForSelectedProject.contains { $0.id == claudeThreadID }, "archive moved the claude thread")

        let service = makeAgentCLIService()
        let freshCodexMetadata = try service.captureMetadataByRunningCLI(
            kind: .codex,
            workingDirectory: paths.projectDirectory,
            environment: environment
        )
        try assert(freshCodexMetadata.identity == "codex-e2e-001", "codex command double reported deterministic identity")
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

        let reloadedModel = try makeModel(databasePath: databasePath)
        try assert(reloadedModel.selectedThread?.id == codexThreadID, "relaunch preserved selected codex thread")
        try assert(reloadedModel.selectedThread?.sessionIdentity == "codex-e2e-001", "relaunch preserved codex session identity")
        let resumedRequest = try unwrap(reloadedModel.activateSelectedProjectTerminal(), "resumed project terminal exists")
        try assert(
            resumedRequest.request.command.contains("resume")
                && resumedRequest.request.command.contains("codex-e2e-001"),
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
            let databasePath = paths.stateDirectory.appendingPathComponent("\(state.rawValue).sqlite")
            let model = try makeModel(databasePath: databasePath)
            if state == .launch {
                continue
            }
            try model.createProject(displayName: "E2E Project", rootDirectory: paths.projectDirectory)
            if state == .projectCreation {
                continue
            }
            let threadID = try model.createThread(agentCLI: .codex)
            model.recordAgentCLIOutput(
                threadID: threadID,
                output: "AGENT_IDE_SESSION_ID=codex-e2e-001\nAGENT_IDE_SESSION_NAME=Codex E2E Session\n"
            )
            switch state {
            case .launch, .projectCreation:
                break
            case .files:
                model.refreshSelectedFileBrowser()
                try waitUntil("visual files state indexed README.md") {
                    model.fileBrowserState.visibleEntries.contains { $0.relativePath == "README.md" }
                }
            case .nvim:
                model.openFileInNvim(relativePath: "README.md")
            case .git:
                model.selectRightPanelMode(.git)
            case .globalTerminal:
                model.toggleGlobalTerminal()
            case .panelCollapse:
                model.toggleSidebarCollapsed()
                model.toggleRightPanelCollapsed()
            }
        }
        _ = selectedThreadID
    }

    private func assertMissingLazygitFallsBackToRawCommand() throws {
        let databasePath = paths.stateDirectory.appendingPathComponent("missing-lazygit.sqlite")
        let store = try SQLiteAgentIDEStore(databasePath: databasePath)
        let configuration = JSONConfigurationStore(path: paths.configPath).load()
        var missingToolEnvironment = environment
        missingToolEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let model = AppModel(
            store: store,
            agentCLIBindings: AgentCLISessionBindingService(
                environment: missingToolEnvironment,
                captureDirectory: paths.captureDirectory
            ),
            fileIndexer: ImmediateFileIndexer(),
            configuration: configuration,
            environment: missingToolEnvironment
        )
        try model.createProject(displayName: "Missing Tool Project", rootDirectory: paths.projectDirectory)
        let threadID = try model.createThread(agentCLI: .codex)
        model.selectRightPanelMode(.git)
        let request = try unwrap(model.terminalLaunchRequest(for: .lazygit(threadID: threadID)), "missing lazygit request")
        try assert(request.command == ["lazygit"], "missing lazygit fell back to the raw command name")
    }

    private func writeManifest(focusedBehavior: FocusedBehaviorResult) throws {
        let manifest = """
        Agent IDE E2E artifacts

        focused_behavior_database=\(focusedBehavior.databasePath.path)
        codex_thread_id=\(focusedBehavior.codexThreadID.uuidString)
        claude_thread_id=\(focusedBehavior.claudeThreadID.uuidString)
        fixture_project=\(paths.projectDirectory.path)
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
        env["AGENT_IDE_CONFIG_PATH"] = paths.configPath.path
        env["AGENT_IDE_CAPTURE_DIRECTORY"] = paths.captureDirectory.path
        return env
    }

    private func makeAgentCLIService() -> AgentCLISessionBindingService {
        AgentCLISessionBindingService(
            environment: environment,
            captureDirectory: paths.captureDirectory
        )
    }

    private func makeModel(databasePath: URL) throws -> AppModel {
        let store = try SQLiteAgentIDEStore(databasePath: databasePath)
        let configuration = JSONConfigurationStore(path: paths.configPath).load()
        return AppModel(
            store: store,
            agentCLIBindings: makeAgentCLIService(),
            fileIndexer: ImmediateFileIndexer(),
            configuration: configuration,
            environment: environment
        )
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
    var captureDirectory: URL { root.appendingPathComponent("captures", isDirectory: true) }
    var configPath: URL { root.appendingPathComponent("config/config.json") }
    var projectDirectory: URL { root.appendingPathComponent("fixture-project", isDirectory: true) }
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
    case globalTerminal = "global-terminal"
    case panelCollapse = "panel-collapse"
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
