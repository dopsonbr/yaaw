import Foundation
import Observation

/// Errors raised by workspace mutations. Re-homed verbatim from the pre-rewrite
/// `AppModelError`.
public enum WorkspaceStoreError: Error, Equatable, Sendable {
    /// A project was created or renamed with a blank display name.
    case emptyProjectName
    /// A thread was created or renamed with a blank name.
    case emptyThreadName
    /// The project's root directory does not exist at the given path.
    case missingProjectDirectory(String)
    /// The operation needs a selected project but none is selected.
    case selectedProjectMissing
    /// A thread was requested without a project to host it.
    case projectRequiredForThreadCreation
    /// Thread creation lacked the required agent CLI selection.
    case missingAgentCLI
    /// No thread matches the requested identifier.
    case threadNotFound
    /// A thread's bound agent CLI family cannot be changed after creation.
    case agentCLIChangeNotAllowed
    /// Renaming the underlying CLI session is not supported.
    case sessionRenameNotSupported
}

/// Owns projects, threads, selection, navigation history, and session-link
/// prompts, plus the O(1) `threadIndexByID` and per-project sorted active/archived
/// caches. `@MainActor @Observable`. Every mutation persists via the injected
/// store actor (idempotent UPSERT); the caches are rebuilt/patched in lockstep so
/// `activeThreadsForSelectedProject` stays an O(1) keyed lookup at 10k threads.
@MainActor
@Observable
public final class WorkspaceStore {
    /// All projects, sorted by pin state and sort order.
    public internal(set) var projects: [Project]
    /// All threads across every project, active and archived.
    public internal(set) var threads: [AgentThread]
    /// Identifier of the currently selected project.
    public internal(set) var selectedProjectID: UUID
    /// Identifier of the currently selected thread, or `nil` when none is selected.
    public internal(set) var selectedThreadID: UUID?
    /// Projects whose active-thread list is expanded in the sidebar.
    public internal(set) var expandedProjectIDs: Set<UUID>
    /// Projects whose archived-thread list is expanded in the sidebar.
    public internal(set) var expandedArchivedProjectIDs: Set<UUID>
    /// Threads still awaiting a session-link prompt before they can resume.
    public internal(set) var sessionLinkRequiredThreadIDs: Set<UUID>
    /// Back/forward selection history for project and thread navigation.
    public internal(set) var navigationHistory: NavigationHistory

    @ObservationIgnored let persistence: StorePersistenceQueue
    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored weak var activity: ActivityStore?
    @ObservationIgnored weak var rightPanel: RightPanelStore?
    @ObservationIgnored weak var layout: LayoutStore?

    // O(1) caches — touched only by the cache-maintenance extension.
    @ObservationIgnored var threadIndexByID: [UUID: Int] = [:]
    @ObservationIgnored var cachedActiveThreadsByProject: [UUID: [AgentThread]] = [:]
    @ObservationIgnored var cachedArchivedThreadsByProject: [UUID: [AgentThread]] = [:]

    // Session/terminal bookkeeping (replaces the generation counters with Task
    // cancellation + offset/descriptor invalidation; see WorkspaceStore+Sessions).
    @ObservationIgnored var sessionLinkSkippedThreadIDs: Set<UUID> = []
    @ObservationIgnored var activeProjectLaunchDescriptorsByThreadID:
        [UUID: AgentCLITerminalLaunchDescriptor] = [:]
    @ObservationIgnored var captureReadOffsetsByThreadID: [UUID: UInt64] = [:]
    /// Background session-link reconciliation kicked off by ``finishLoad()`` so a
    /// large session catalog never blocks app startup; awaited via
    /// ``awaitLoadReconciliation()``.
    @ObservationIgnored private var loadReconciliationTask: Task<Void, Never>?

    init(context: StoreLoadContext, settings: SettingsStore) {
        let environment = context.environment
        let snapshot = context.snapshot
        self.environment = environment
        self.settings = settings
        self.persistence = context.persistenceQueue

        let globalChatsDirectory = Self.globalChatsDirectory(
            for: settings.configuration, homeDirectory: environment.homeDirectory)
        Self.ensureGlobalChatsDirectoryExists(
            globalChatsDirectory, diagnosticRecorder: environment.diagnosticRecorder)
        let loadedProjects = snapshot.projects.map { project -> Project in
            guard Self.isGlobalProject(project) else { return project }
            var project = project
            project.rootDirectory = globalChatsDirectory
            return project
        }
        let sortedProjects = Self.sortedProjects(loadedProjects)
        self.projects = sortedProjects
        self.threads = snapshot.threads
        self.sessionLinkRequiredThreadIDs = []

        let fallbackProjectID =
            sortedProjects.first { !Self.isGlobalProject($0) && !$0.isArchived }?.id
            ?? sortedProjects.first { !$0.isArchived }?.id
            ?? sortedProjects[0].id
        let selectedProjectID =
            sortedProjects.contains { $0.id == snapshot.selectedProjectID && !$0.isArchived }
            ? snapshot.selectedProjectID
            : fallbackProjectID
        let selectedProjectIsGlobal =
            sortedProjects.first { $0.id == selectedProjectID }.map(Self.isGlobalProject) ?? false
        let selectedThreadID = Self.resolveSelectedThread(
            snapshot: snapshot,
            selectedProjectID: selectedProjectID,
            selectedProjectIsGlobal: selectedProjectIsGlobal
        )
        self.selectedProjectID = selectedProjectID
        self.selectedThreadID = selectedThreadID

        var expandedProjectIDs = snapshot.expandedProjectIDs
        expandedProjectIDs.insert(selectedProjectID)
        self.expandedProjectIDs = expandedProjectIDs
        self.expandedArchivedProjectIDs = snapshot.expandedArchivedProjectIDs
        self.navigationHistory = NavigationHistory(
            initial: AppSelection(projectID: selectedProjectID, threadID: selectedThreadID))

        rebuildThreadIndexes()
    }

    /// Resolves which thread should be selected on load: nil for the Global
    /// project, the snapshot's selection if valid, else the first active thread.
    private static func resolveSelectedThread(
        snapshot: YAAWSnapshot,
        selectedProjectID: UUID,
        selectedProjectIsGlobal: Bool
    ) -> UUID? {
        if selectedProjectIsGlobal { return nil }
        if let snapshotSelectedThreadID = snapshot.selectedThreadID,
            let selectedThread = snapshot.threads.first(where: { $0.id == snapshotSelectedThreadID }
            ),
            selectedThread.projectID == selectedProjectID,
            !selectedThread.isArchived
        {
            return snapshotSelectedThreadID
        }
        return snapshot.threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
    }

    func attach(activity: ActivityStore, rightPanel: RightPanelStore, layout: LayoutStore) {
        self.activity = activity
        self.rightPanel = rightPanel
        self.layout = layout
        rightPanel.selectedThreadWorkingDirectory = { [weak self] in
            self?.selectedThread?.workingDirectory
        }
        settings.onReload { [weak self] configuration in
            self?.handleConfigurationReload(configuration)
        }
    }

    /// Post-init load work that touches other stores / the async actors:
    /// session-link reconciliation, the initial file-browser publish, and the
    /// global-directory reconciliation diagnostic.
    ///
    /// Session-link reconciliation reads + parses every CLI session catalog for
    /// each unbound thread, which is unbounded in a large workspace (e.g.
    /// order-up). It therefore runs in a background `Task` rather than on the load
    /// path, so the UI never sits behind "Loading…" while catalogs are parsed; the
    /// 1 Hz session-sync poll performs ongoing linking, and `awaitLoadReconciliation`
    /// is the deterministic seam tests use. The cheap diagnostics + global-directory
    /// reconcile stay synchronous.
    func finishLoad() async {
        let requiresLinks = environment.requiresSessionLinkForLoadedUnboundThreads
        // `.background` priority so this one-time catalog-parsing burst (large on a
        // many-worktree workspace like order-up) yields to higher-priority work —
        // notably the selected thread's file-index refresh, which otherwise gets
        // starved on launch and leaves the Files panel stuck "Indexing…" (#25/#27).
        loadReconciliationTask = Task(priority: .background) { [weak self] in
            await self?.reconcileLoadedUnboundSessionLinks(requiresLinks: requiresLinks)
        }
        recordDiagnostic(
            category: "Lifecycle",
            name: "app_model_loaded",
            metadata: [
                "project_count": "\(projects.count)",
                "thread_count": "\(threads.count)",
            ]
        )
        reconcileGlobalProjectDirectory()
    }

    /// Awaits the background session-link reconciliation kicked off by
    /// ``finishLoad()``. The deterministic seam for tests / acceptance setup.
    public func awaitLoadReconciliation() async {
        await loadReconciliationTask?.value
    }

    /// Resolves once every enqueued persistence write has completed (test seam).
    public func flushPersistence() async { await persistence.flush() }

    // MARK: - Computed

    /// The currently selected thread, or `nil` when none is selected.
    public var selectedThread: AgentThread? {
        guard let selectedThreadID, let index = threadIndexByID[selectedThreadID] else {
            return nil
        }
        return threads[index]
    }

    /// Whether the selected thread is awaiting a session-link prompt before it can resume.
    public var selectedThreadRequiresSessionLink: Bool {
        selectedThreadID.map { sessionLinkRequiredThreadIDs.contains($0) } ?? false
    }

    /// The currently selected project, or `nil` if it cannot be found.
    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    /// Projects that are not archived.
    public var activeProjects: [Project] { projects.filter { !$0.isArchived } }
    /// Projects that have been archived.
    public var archivedProjects: [Project] { projects.filter { $0.isArchived } }

    /// Active threads for the selected project, from the O(1) cache.
    public var activeThreadsForSelectedProject: [AgentThread] {
        cachedActiveThreadsByProject[selectedProjectID] ?? []
    }

    /// Archived threads for the selected project, from the O(1) cache.
    public var archivedThreadsForSelectedProject: [AgentThread] {
        cachedArchivedThreadsByProject[selectedProjectID] ?? []
    }

    /// Active threads for the given project, from the O(1) cache.
    public func activeThreads(for projectID: UUID) -> [AgentThread] {
        cachedActiveThreadsByProject[projectID] ?? []
    }

    /// Archived threads for the given project, from the O(1) cache.
    public func archivedThreads(for projectID: UUID) -> [AgentThread] {
        cachedArchivedThreadsByProject[projectID] ?? []
    }

    /// Archived threads across every project.
    public var archivedThreads: [AgentThread] {
        projects.flatMap { cachedArchivedThreadsByProject[$0.id] ?? [] }
    }

    /// Whether the selected project has any archived threads.
    public var hasArchivedThreadsForSelectedProject: Bool {
        !archivedThreadsForSelectedProject.isEmpty
    }

    /// Whether any project has archived threads.
    public var hasArchivedThreads: Bool { !archivedThreads.isEmpty }

    /// Title for the app window, combining the selected project and thread names.
    public var windowTitle: String {
        guard let project = selectedProject else { return "Agent IDE" }
        guard let thread = selectedThread else { return project.displayName }
        return "\(project.displayName) - \(thread.displayName)"
    }

    /// Display name for the given project, or a placeholder if it is unknown.
    public func projectDisplayName(for projectID: UUID) -> String {
        projects.first { $0.id == projectID }?.displayName ?? "Unknown Project"
    }

    /// Whether the given project's active-thread list is expanded.
    public func isProjectExpanded(_ projectID: UUID) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    /// Whether the given project's archived-thread list is expanded.
    public func isProjectArchiveExpanded(_ projectID: UUID) -> Bool {
        expandedArchivedProjectIDs.contains(projectID)
    }

    /// Availability state of the selected project's root directory on disk.
    public var selectedProjectDirectoryState: ProjectDirectoryState? {
        selectedProject.map { directoryState(for: $0.rootDirectory) }
    }

    /// Availability state of the selected thread's working directory on disk.
    public var selectedThreadWorkingDirectoryState: ProjectDirectoryState? {
        selectedThread.map { directoryState(for: $0.workingDirectory) }
    }

    /// The directory the selected thread or project should open in an external
    /// app (Finder/editor), or `nil` when no existing directory is available.
    public var selectedExternalOpenDirectoryTarget: ExternalOpenTarget? {
        if let thread = selectedThread {
            guard isExistingDirectory(thread.workingDirectory) else { return nil }
            return ExternalOpenTarget(url: thread.workingDirectory, kind: .directory)
        }
        guard let project = selectedProject, isExistingDirectory(project.rootDirectory) else {
            return nil
        }
        return ExternalOpenTarget(url: project.rootDirectory, kind: .directory)
    }

    // MARK: - Lookups

    func thread(withID threadID: UUID) -> AgentThread? {
        threadIndexByID[threadID].map { threads[$0] }
    }

    func activeThread(id threadID: UUID) -> AgentThread? {
        guard let index = threadIndexByID[threadID], !threads[index].isArchived else { return nil }
        return threads[index]
    }

    func firstActiveThreadID(forProject projectID: UUID) -> UUID? {
        cachedActiveThreadsByProject[projectID]?.first?.id
    }

    func directoryState(for url: URL) -> ProjectDirectoryState {
        isExistingDirectory(url) ? .available(path: url.path) : .missing(path: url.path)
    }

    func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func recordDiagnostic(category: String, name: String, metadata: [String: String] = [:]) {
        environment.diagnosticRecorder.record(
            DiagnosticEvent(category: category, name: name, metadata: metadata))
    }
}
