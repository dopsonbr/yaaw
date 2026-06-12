import Foundation
import XCTest

@testable import YAAWKit

/// Builds the full store set from a test `AppEnvironment` (InMemoryYAAWStore + a
/// fake RenderSurfaceManager + recording notification/badge doubles + an
/// isApplicationActive stub) and re-points each ported `AppModelTests` assertion at
/// the owning store. The pre-rewrite tests constructed a single `AppModel`; this
/// harness exposes the five stores plus the doubles the tests inspect.
@MainActor
struct StoreHarness {
    let stores: AppStores
    let store: InMemoryYAAWStore
    let surfaceManager: RecordingRenderSurfaceManager
    let notificationDispatcher: RecordingThreadActivityNotificationDispatcher
    let badgeUpdater: RecordingThreadActivityBadgeUpdater
    let diagnosticRecorder: RecordingDiagnosticEventRecorder

    var workspace: WorkspaceStore { stores.workspace }
    var layout: LayoutStore { stores.layout }
    var activity: ActivityStore { stores.activity }
    var settings: SettingsStore { stores.settings }
    var rightPanel: RightPanelStore { stores.rightPanel }

    /// Awaits every store's pending persistence so write-counter assertions are
    /// deterministic (the seam the ported tests use after a mutation).
    func flush() async {
        await workspace.flushPersistence()
        await layout.flushPersistence()
        await activity.flushPersistence()
        await rightPanel.flushPersistence()
    }
}

@MainActor
enum StoreHarnessBuilder {
    /// Builds a harness over the given snapshot/store and collaborators. Defaults
    /// match the pre-rewrite `AppModel` defaults used across `AppModelTests`.
    static func make(
        store: InMemoryYAAWStore,
        sessionBindingActor: SessionBindingActor = SessionBindingActor(captureDirectory: nil),
        fileIndexer: any FileIndexing = ImmediateTestFileIndexer(),
        agentCLIOptionCatalogService: any AgentCLIOptionCatalogServicing =
            AgentCLIOptionCatalogService(),
        externalToolResolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        configuration: YAAWConfiguration = YAAWConfiguration(),
        systemAppearanceIsDark: Bool = true,
        isApplicationActive: @escaping @Sendable () -> Bool = { false },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requiresSessionLinkForLoadedUnboundThreads: Bool? = nil,
        diagnosticRecorder: RecordingDiagnosticEventRecorder = RecordingDiagnosticEventRecorder()
    ) async -> StoreHarness {
        let surfaceManager = RecordingRenderSurfaceManager()
        let notificationDispatcher = RecordingThreadActivityNotificationDispatcher()
        let badgeUpdater = RecordingThreadActivityBadgeUpdater()
        let appEnvironment = AppEnvironment(
            persistenceStore: store,
            fileIndexActor: FileIndexActor(store: store, fileIndexer: fileIndexer),
            sessionBindingActor: sessionBindingActor,
            renderSurfaceManager: surfaceManager,
            agentCLIOptionCatalogService: agentCLIOptionCatalogService,
            externalToolResolver: externalToolResolver,
            notificationDispatcher: notificationDispatcher,
            badgeUpdater: badgeUpdater,
            diagnosticRecorder: diagnosticRecorder,
            isApplicationActive: isApplicationActive,
            environment: environment,
            homeDirectory: homeDirectory,
            requiresSessionLinkForLoadedUnboundThreads: requiresSessionLinkForLoadedUnboundThreads
        )
        // SettingsStore needs the configuration applied; AppStores.make builds a
        // default settings store, so we reload the configuration onto it (matching
        // the pre-rewrite AppModel which took configuration at init).
        let stores = await AppStores.make(environment: appEnvironment)
        if configuration != YAAWConfiguration() {
            stores.settings.reloadConfiguration(configuration)
        }
        if systemAppearanceIsDark != true {
            stores.settings.updateSystemAppearance(isDark: systemAppearanceIsDark)
        }
        // Session-link reconciliation now runs in a background task off the load
        // path (so a large catalog never blocks startup); await it here so tests
        // observe the reconciled state deterministically.
        await stores.workspace.awaitLoadReconciliation()
        await stores.workspace.flushPersistence()
        return StoreHarness(
            stores: stores,
            store: store,
            surfaceManager: surfaceManager,
            notificationDispatcher: notificationDispatcher,
            badgeUpdater: badgeUpdater,
            diagnosticRecorder: diagnosticRecorder
        )
    }
}

/// A reusable two-thread project fixture mirroring the pre-rewrite
/// `AppModelFixture`: one codex thread ("First", selected) and one claude thread
/// ("Second"), both rooted at the temporary directory.
@MainActor
struct StoreFixture {
    let projectID = UUID()
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let root = FileManager.default.temporaryDirectory

    func makeStore() -> InMemoryYAAWStore {
        InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: firstThreadID, displayName: "First", projectID: projectID,
                        workingDirectory: root, agentCLI: .codex),
                    AgentThread(
                        id: secondThreadID, displayName: "Second", projectID: projectID,
                        workingDirectory: root, agentCLI: .claude),
                ],
                selectedProjectID: projectID,
                selectedThreadID: firstThreadID,
                rightPanelModesByThreadID: [firstThreadID: .files, secondThreadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
    }
}

// MARK: - Recording doubles

final class RecordingRenderSurfaceManager: RenderSurfaceManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<RenderSurfaceRole> = []
    private var launchLog: [RenderSurfaceLaunch] = []
    private var shutdownLog: [RenderSurfaceRole] = []

    @discardableResult
    func activate(_ launch: RenderSurfaceLaunch) -> Bool {
        lock.withLock {
            active.insert(launch.role)
            launchLog.append(launch)
        }
        return true
    }

    func shutdown(role: RenderSurfaceRole) {
        lock.withLock {
            active.remove(role)
            shutdownLog.append(role)
        }
    }

    func isActive(role: RenderSurfaceRole) -> Bool { lock.withLock { active.contains(role) } }

    var launches: [RenderSurfaceLaunch] { lock.withLock { launchLog } }
    var shutdowns: [RenderSurfaceRole] { lock.withLock { shutdownLog } }
}

final class RecordingThreadActivityNotificationDispatcher:
    ThreadActivityNotificationDispatching, @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [ThreadActivityNotification] = []
    var notifications: [ThreadActivityNotification] { lock.withLock { storage } }
    func dispatch(_ notification: ThreadActivityNotification) {
        lock.withLock { storage.append(notification) }
    }
}

final class RecordingThreadActivityBadgeUpdater: ThreadActivityBadgeUpdating, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    var counts: [Int] { lock.withLock { storage } }
    func updateUnreadThreadActivityCount(_ count: Int) { lock.withLock { storage.append(count) } }
}

/// Synchronous file indexer used by tests so a refresh completes within the
/// awaited Task (mirrors the pre-rewrite `ImmediateTestFileIndexer`).
final class ImmediateTestFileIndexer: FileIndexing, @unchecked Sendable {
    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        completion(
            Result {
                try BackgroundFileIndexer.buildIndex(
                    threadID: threadID, root: root, ignoreRules: ignoreRules)
            })
    }

    func indexSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        completion(
            Result {
                try BackgroundFileIndexer.buildSubtreeIndex(
                    threadID: threadID, root: root, relativeSubpath: relativeSubpath,
                    ignoreRules: ignoreRules)
            })
    }
}

@MainActor
func storeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("YAAWStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
