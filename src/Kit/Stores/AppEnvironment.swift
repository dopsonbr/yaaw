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
    public let persistenceStore: any YAAWStore
    public let fileIndexActor: FileIndexActor
    public let sessionBindingActor: SessionBindingActor
    public let renderSurfaceManager: any RenderSurfaceManaging
    public let agentCLIOptionCatalogService: any AgentCLIOptionCatalogServicing
    public let externalToolResolver: any AgentCLIExecutableResolving
    public let notificationDispatcher: any ThreadActivityNotificationDispatching
    public let badgeUpdater: any ThreadActivityBadgeUpdating
    public let diagnosticRecorder: any DiagnosticEventRecording
    public let isApplicationActive: @Sendable () -> Bool
    public let environment: [String: String]
    public let homeDirectory: URL
    /// Whether loaded unbound threads must be explicitly session-linked. SQLite
    /// (durable, real state) defaults to `true`; in-memory tests default to
    /// `false` unless overridden — matching the pre-rewrite AppModel.
    public let requiresSessionLinkForLoadedUnboundThreads: Bool

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
    public let workspace: WorkspaceStore
    public let layout: LayoutStore
    public let activity: ActivityStore
    public let settings: SettingsStore
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
