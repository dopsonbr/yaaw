import Foundation

/// The dependency container that constructs and wires the five stores. Replaces
/// the pre-rewrite `AppModel`'s scattered init parameters. Lives in `YAAWKit` and
/// uses protocol abstractions for app-layer collaborators (`RenderSurfaceManaging`,
/// the notification/badge dispatchers), so `YAAWKit` never depends on the app
/// target. The already-built async actors (`SQLiteYAAWStore`/`InMemoryYAAWStore`,
/// `FileIndexActor`, `SessionBindingActor`) are injected directly.
///
/// `@MainActor` because the stores it builds are `@MainActor`; the actors it holds
/// are `Sendable` and crossed with `await`.
@MainActor
public struct AppEnvironment {
    /// The durable persistence store (SQLite in production, in-memory in tests).
    public let persistenceStore: any YAAWStore
    /// The actor that builds and caches per-thread file-browser indexes.
    public let fileIndexActor: FileIndexActor
    /// The actor that resolves and persists per-thread agent session bindings.
    public let sessionBindingActor: SessionBindingActor
    /// Drives terminal/browser surfaces on behalf of the stores.
    public let renderSurfaceManager: any RenderSurfaceManaging
    /// Supplies the catalog of available agent CLI launch options.
    public let agentCLIOptionCatalogService: any AgentCLIOptionCatalogServicing
    /// Resolves external tool executables (e.g. agent CLIs) on `PATH`.
    public let externalToolResolver: any AgentCLIExecutableResolving
    /// Dispatches user notifications for thread-activity transitions.
    public let notificationDispatcher: any ThreadActivityNotificationDispatching
    /// Updates the app's Dock badge in response to thread activity.
    public let badgeUpdater: any ThreadActivityBadgeUpdating
    /// Records diagnostic events for logging and telemetry-free debugging.
    public let diagnosticRecorder: any DiagnosticEventRecording
    /// Reports whether the application is currently the active (frontmost) app.
    public let isApplicationActive: @Sendable () -> Bool
    /// The process environment variables used when launching CLIs.
    public let environment: [String: String]
    /// The current user's home directory.
    public let homeDirectory: URL
    /// Whether loaded unbound threads must be explicitly session-linked. SQLite
    /// (durable, real state) defaults to `true`; in-memory tests default to
    /// `false` unless overridden — matching the pre-rewrite AppModel.
    public let requiresSessionLinkForLoadedUnboundThreads: Bool

    /// Creates the dependency container, defaulting app-layer collaborators to
    /// their no-op implementations so `YAAWKit` and the bare binary can run
    /// without the app target. `requiresSessionLinkForLoadedUnboundThreads`
    /// defaults based on whether `persistenceStore` is the durable SQLite store.
    public init(
        persistenceStore: any YAAWStore,
        fileIndexActor: FileIndexActor,
        sessionBindingActor: SessionBindingActor = SessionBindingActor(),
        renderSurfaceManager: any RenderSurfaceManaging = NoopRenderSurfaceManager(),
        agentCLIOptionCatalogService: any AgentCLIOptionCatalogServicing =
            AgentCLIOptionCatalogService(),
        externalToolResolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        notificationDispatcher: any ThreadActivityNotificationDispatching =
            NoopThreadActivityNotificationDispatcher(),
        badgeUpdater: any ThreadActivityBadgeUpdating = NoopThreadActivityBadgeUpdater(),
        diagnosticRecorder: any DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared,
        isApplicationActive: @escaping @Sendable () -> Bool = { false },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requiresSessionLinkForLoadedUnboundThreads: Bool? = nil
    ) {
        self.persistenceStore = persistenceStore
        self.fileIndexActor = fileIndexActor
        self.sessionBindingActor = sessionBindingActor
        self.renderSurfaceManager = renderSurfaceManager
        self.agentCLIOptionCatalogService = agentCLIOptionCatalogService
        self.externalToolResolver = externalToolResolver
        self.notificationDispatcher = notificationDispatcher
        self.badgeUpdater = badgeUpdater
        self.diagnosticRecorder = diagnosticRecorder
        self.isApplicationActive = isApplicationActive
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.requiresSessionLinkForLoadedUnboundThreads =
            requiresSessionLinkForLoadedUnboundThreads ?? (persistenceStore is SQLiteYAAWStore)
    }
}

/// The complete set of stores, constructed together so they share one loaded
/// snapshot, one `AppEnvironment`, and cross-references (e.g. Activity reads the
/// Workspace's selection). Build via ``make(environment:)``.
@MainActor
public final class AppStores {
    /// The store owning projects, threads, and selection.
    public let workspace: WorkspaceStore
    /// The store owning window/pane layout state.
    public let layout: LayoutStore
    /// The store owning per-thread activity state and notifications.
    public let activity: ActivityStore
    /// The store owning user settings (YAML-backed).
    public let settings: SettingsStore
    /// The store owning per-thread right-panel mode and state.
    public let rightPanel: RightPanelStore

    init(
        workspace: WorkspaceStore,
        layout: LayoutStore,
        activity: ActivityStore,
        settings: SettingsStore,
        rightPanel: RightPanelStore
    ) {
        self.workspace = workspace
        self.layout = layout
        self.activity = activity
        self.settings = settings
        self.rightPanel = rightPanel
    }

    /// Loads the snapshot once and builds the full store set from `environment`.
    public static func make(environment: AppEnvironment) async -> AppStores {
        let snapshot = await environment.persistenceStore.load()
        let context = StoreLoadContext(environment: environment, snapshot: snapshot)

        let settings = SettingsStore(context: context)
        let layout = LayoutStore(context: context)
        let rightPanel = RightPanelStore(context: context)
        let workspace = WorkspaceStore(context: context, settings: settings)
        let activity = ActivityStore(
            context: context, workspace: workspace, settings: settings, rightPanel: rightPanel)

        workspace.attach(activity: activity, rightPanel: rightPanel, layout: layout)
        await workspace.finishLoad()
        await activity.finishLoad()
        return AppStores(
            workspace: workspace,
            layout: layout,
            activity: activity,
            settings: settings,
            rightPanel: rightPanel
        )
    }
}

/// The slice of state every store needs at construction: the environment plus the
/// freshly loaded snapshot. Passed to each store's `init`.
@MainActor
struct StoreLoadContext {
    let environment: AppEnvironment
    let snapshot: YAAWSnapshot
}
