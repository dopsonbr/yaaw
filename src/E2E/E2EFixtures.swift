import Foundation
import YAAWKit

/// Filesystem + command-double fixtures, plus the store/stores builders the
/// headless runner drives. Split out of the orchestrator so each unit stays
/// under the body-length budget. The pre-rewrite runner constructed a single
/// `AppModel`; here we build the five `@MainActor @Observable` stores via
/// `AppEnvironment` + `AppStores.make`, exactly like the Chunk E store tests.
struct E2EFixtures {
    let paths: E2EPaths
    private let fileManager = FileManager.default

    init(paths: E2EPaths) {
        self.paths = paths
    }

    // MARK: - Reset & filesystem fixtures

    func resetArtifacts() throws {
        if fileManager.fileExists(atPath: paths.root.path) {
            try fileManager.removeItem(at: paths.root)
        }
        for directory in [
            paths.binDirectory, paths.missingToolBinDirectory, paths.workspaceDirectory,
            paths.projectDirectory, paths.stateDirectory, paths.captureDirectory,
            paths.activityDirectory, paths.helperBinDirectory, paths.screenshotDirectory,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func writeFixtureProject() throws {
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
            atomically: true, encoding: .utf8)
        try "<!doctype html><title>YAAW Preview</title><h1>Browser Preview</h1>\n".write(
            to: paths.projectDirectory.appendingPathComponent("index.html"),
            atomically: true, encoding: .utf8)
        try """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 40">
          <text x="8" y="25">YAAW</text>
        </svg>
        """.write(
            to: paths.projectDirectory.appendingPathComponent("diagram.svg"),
            atomically: true, encoding: .utf8)
        try "print(\"fixture\")\n".write(
            to: paths.projectDirectory.appendingPathComponent("src/App/RootView.swift"),
            atomically: true, encoding: .utf8)
        try "E2E_SECRET=not-real\n".write(
            to: paths.projectDirectory.appendingPathComponent(".env"),
            atomically: true, encoding: .utf8)
        try fileManager.createDirectory(
            at: paths.projectDirectory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try "ignored\n".write(
            to: paths.projectDirectory.appendingPathComponent(".git/HEAD"),
            atomically: true, encoding: .utf8)
    }

    func writeConfiguration() throws {
        // Pin a fixed theme: the default is System mode, which would make the
        // visual-state screenshots depend on the host machine's appearance.
        try YAMLConfigurationStore(path: paths.configPath).save(
            YAAWConfiguration(theme: ThemeSettings(active: ThemeCatalog.defaultID)))
    }

    var configuration: YAAWConfiguration {
        YAMLConfigurationStore(path: paths.configPath).load()
    }

    // MARK: - Environment

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = paths.binDirectory.path + ":" + (env["PATH"] ?? "")
        env["YAAW_E2E_CONFIG_PATH"] = paths.configPath.path
        env["YAAW_E2E_CAPTURE_DIRECTORY"] = paths.captureDirectory.path
        return env
    }

    // MARK: - Store / stores builders

    func makeSessionBindingActor(environment overrideEnvironment: [String: String]? = nil)
        -> SessionBindingActor
    {
        SessionBindingActor(
            resolver: PATHAgentCLIExecutableResolver(),
            environment: overrideEnvironment ?? environment,
            captureDirectory: paths.captureDirectory,
            activityDirectory: paths.activityDirectory,
            helperBinDirectory: paths.helperBinDirectory
        )
    }

    /// Builds the full store set over a SQLite database, seeding the sandbox
    /// project when the database is new. `environment`/`externalToolResolver`
    /// may be overridden for the missing-tool fallback assertions.
    @MainActor
    func makeStores(
        databasePath: URL,
        environment overrideEnvironment: [String: String]? = nil,
        externalToolResolver: (any AgentCLIExecutableResolving)? = nil,
        seed: YAAWSnapshot? = nil
    ) async throws -> AppStores {
        let runEnvironment = overrideEnvironment ?? environment
        let store = try await makeSeededStore(databasePath: databasePath, seed: seed)
        let appEnvironment = AppEnvironment(
            persistenceStore: store,
            fileIndexActor: FileIndexActor(store: store, fileIndexer: ImmediateE2EFileIndexer()),
            sessionBindingActor: makeSessionBindingActor(environment: runEnvironment),
            agentCLIOptionCatalogService: AgentCLIOptionCatalogService(
                cachePath: paths.stateDirectory.appendingPathComponent("agent-cli-options.json")),
            externalToolResolver: externalToolResolver
                ?? PATHAgentCLIExecutableResolver(fallbackSearchPaths: []),
            environment: runEnvironment
        )
        let stores = await AppStores.make(environment: appEnvironment)
        stores.settings.reloadConfiguration(configuration)
        // Session-link reconciliation now runs in a background task off the load
        // path (so a large catalog never blocks startup); await it so the runner's
        // assertions observe the reconciled link-required state deterministically.
        await stores.workspace.awaitLoadReconciliation()
        await flush(stores)
        return stores
    }

    /// Opens (or creates) a SQLite store, seeding the given snapshot — or the
    /// sandbox seed — only when the database file did not yet exist (so a reload
    /// preserves prior durable state, like the pre-rewrite `makeModel`).
    @MainActor
    func makeSeededStore(databasePath: URL, seed: YAAWSnapshot? = nil) async throws
        -> SQLiteYAAWStore
    {
        let databaseExists = fileManager.fileExists(atPath: databasePath.path)
        let store = try SQLiteYAAWStore(databasePath: databasePath)
        if !databaseExists {
            await store.save(seed ?? sandboxSeedSnapshot())
        }
        return store
    }

    func sandboxSeedSnapshot() -> YAAWSnapshot {
        YAAWSnapshot(
            projects: [
                Project(displayName: "E2E Sandbox", rootDirectory: paths.workspaceDirectory)
            ],
            threads: [],
            selectedProjectID: UUID(),  // overwritten below
            selectedThreadID: nil,
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false
        ).withSelectedProjectMatchingFirst()
    }

    func fixtureSeedSnapshot() -> YAAWSnapshot {
        YAAWSnapshot(
            projects: [
                Project(displayName: "E2E Project", rootDirectory: paths.projectDirectory)
            ],
            threads: [],
            selectedProjectID: UUID(),  // overwritten below
            selectedThreadID: nil,
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false
        ).withSelectedProjectMatchingFirst()
    }

    @MainActor
    func flush(_ stores: AppStores) async {
        await stores.workspace.flushPersistence()
        await stores.layout.flushPersistence()
        await stores.activity.flushPersistence()
        await stores.rightPanel.flushPersistence()
    }
}

extension YAAWSnapshot {
    /// Returns a copy whose `selectedProjectID` matches the first project (the
    /// public init takes a `selectedProjectID`, so seed snapshots construct then
    /// re-point it at the single seeded project's real id).
    fileprivate func withSelectedProjectMatchingFirst() -> YAAWSnapshot {
        guard let firstID = projects.first?.id else { return self }
        var copy = self
        copy.selectedProjectID = firstID
        return copy
    }
}
