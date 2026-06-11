import Foundation
import YAAWKit

/// The headless durable-state runner. Builds fixtures + command doubles, drives
/// the five stores through the full no-mock journey (create → name → pin →
/// archive → record output → index → browser → layout → persist+reload to
/// verify session resume), writes the visual-state databases the launched app
/// screenshots, and emits a manifest.
///
/// The pre-rewrite runner drove a single `AppModel`; this one drives
/// `WorkspaceStore`/`ActivityStore`/`RightPanelStore`/`LayoutStore`/
/// `SettingsStore` via `AppEnvironment` + `AppStores.make`. Every assertion that
/// touched durable state has a store equivalent here.
@MainActor
final class E2ERunner {
    let paths: E2EPaths
    let fixtures: E2EFixtures
    private let fileManager = FileManager.default
    /// Every store set the run builds is retained for the run's lifetime. The
    /// app keeps its stores alive for the whole process; the runner builds many
    /// short-lived sets, and a store set's in-flight file-index Task reads its
    /// `unowned` WorkspaceStore in the completion — releasing the set early would
    /// crash that read. Retaining mirrors the app's lifetime and keeps it safe.
    private var retainedStores: [AppStores] = []

    init(artifactsDirectory: URL) {
        self.paths = E2EPaths(root: artifactsDirectory)
        self.fixtures = E2EFixtures(paths: paths)
    }

    /// Builds a store set via the fixtures and retains it for the run's lifetime.
    func makeStores(
        databasePath: URL,
        environment: [String: String]? = nil,
        externalToolResolver: (any AgentCLIExecutableResolving)? = nil,
        seed: YAAWSnapshot? = nil
    ) async throws -> AppStores {
        let stores = try await fixtures.makeStores(
            databasePath: databasePath, environment: environment,
            externalToolResolver: externalToolResolver, seed: seed)
        retainedStores.append(stores)
        return stores
    }

    func run() async throws {
        try fixtures.resetArtifacts()
        try fixtures.writeFixtureProject()
        try E2ECommandDoubles(paths: paths).write()
        try fixtures.writeConfiguration()

        let focusedBehavior = try await runFocusedBehaviorAssertions()
        try await writeVisualStateDatabases()
        try await assertStateDatabasesAvoidProtectedUserDirectories()
        try writeManifest(focusedBehavior: focusedBehavior)
    }

    // MARK: - Visual-state databases

    /// Builds a fresh SQLite database per `VisualState` so the launched app can
    /// load each and the script can screenshot the rendered result. These write
    /// the durable state only — no rendering — so they run headless here.
    func writeVisualStateDatabases() async throws {
        for state in VisualState.allCases where state != .projectCreation {
            let databasePath = paths.stateDirectory.appendingPathComponent(
                "\(state.rawValue).sqlite")
            let stores = try await makeStores(
                databasePath: databasePath, seed: fixtures.fixtureSeedSnapshot())
            let workspace = stores.workspace
            let threadID = try workspace.createThread(agentCLI: .codex)
            await stores.activity.recordAgentCLIOutput(
                threadID: threadID,
                output: "YAAW_SESSION_ID=codex-e2e-001\nYAAW_SESSION_NAME=Codex E2E Session\n")
            if state == .missingDirectory {
                try await writeMissingDirectoryVisualState(stores: stores)
            } else {
                try await applyVisualState(state, stores: stores, threadID: threadID)
            }
            await fixtures.flush(stores)
        }
    }

    private func writeMissingDirectoryVisualState(stores: AppStores) async throws {
        let missingRoot = paths.missingDirectory
        try fileManager.createDirectory(at: missingRoot, withIntermediateDirectories: true)
        _ = try stores.workspace.createProject(
            displayName: "Missing Directory Project", rootDirectory: missingRoot)
        _ = try stores.workspace.createThread(agentCLI: .codex)
        try fileManager.removeItem(at: missingRoot)
    }

    private func applyVisualState(_ state: VisualState, stores: AppStores, threadID: UUID)
        async throws
    {
        switch state {
        case .launch, .projectCreation, .missingDirectory, .keyboardInput:
            break
        case .files:
            stores.activity.refreshSelectedFileBrowser()
            try await e2eWaitUntil("visual files state indexed README.md") {
                stores.activity.fileBrowserState.visibleEntries.contains {
                    $0.relativePath == "README.md"
                }
            }
        case .nvim:
            stores.rightPanel.openFileInNvim(relativePath: "README.md")
        case .git, .missingTool:
            stores.rightPanel.selectRightPanelMode(.git)
        case .bottomTerminal:
            stores.layout.toggleBottomTerminal()
        case .panelResize:
            stores.layout.setSidebarWidth(360)
            stores.layout.setRightPanelWidth(960)
            stores.layout.setGlobalTerminalHeight(260)
            stores.layout.toggleWorkspaceSwap()
            stores.layout.toggleBottomTerminal()
        case .panelCollapse:
            stores.layout.toggleSidebarCollapsed()
            stores.layout.toggleRightPanelCollapsed()
        }
    }

    // MARK: - Protected-directory security check

    func assertStateDatabasesAvoidProtectedUserDirectories() async throws {
        let databaseURLs = try fileManager.contentsOfDirectory(
            at: paths.stateDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "sqlite" }
        let protectedDirectories = protectedUserDirectories()

        for databaseURL in databaseURLs {
            let snapshot = try await SQLiteYAAWStore(databasePath: databaseURL).load()
            for project in snapshot.projects {
                try e2eAssert(
                    !protectedDirectories.containsPath(project.rootDirectory.path),
                    "\(databaseURL.lastPathComponent) project root avoided protected user folders")
            }
            for thread in snapshot.threads {
                try e2eAssert(
                    !protectedDirectories.containsPath(thread.workingDirectory.path),
                    "\(databaseURL.lastPathComponent) thread working directory "
                        + "avoided protected user folders")
            }
        }
    }

    private func protectedUserDirectories() -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [home.standardizedFileURL.path]
            + ["Desktop", "Documents", "Downloads", "Music", "Movies", "Pictures"].map {
                home.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path
            }
    }

    // MARK: - Manifest

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
            to: paths.root.appendingPathComponent("manifest.txt"),
            atomically: true, encoding: .utf8)
    }
}
