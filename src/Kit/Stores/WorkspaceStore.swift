import Foundation
import Observation

/// Errors raised by workspace mutations. Re-homed verbatim from the pre-rewrite
/// `AppModelError`.
public enum WorkspaceStoreError: Error, Equatable, Sendable {
    case emptyProjectName
    case emptyThreadName
    case missingProjectDirectory(String)
    case selectedProjectMissing
    case projectRequiredForThreadCreation
    case missingAgentCLI
    case threadNotFound
    case agentCLIChangeNotAllowed
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
    public internal(set) var projects: [Project]
    public internal(set) var threads: [AgentThread]
    public internal(set) var selectedProjectID: UUID
    public internal(set) var selectedThreadID: UUID?
    public internal(set) var expandedProjectIDs: Set<UUID>
    public internal(set) var expandedArchivedProjectIDs: Set<UUID>
    public internal(set) var sessionLinkRequiredThreadIDs: Set<UUID>
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

    init(context: StoreLoadContext, settings: SettingsStore) {
        let environment = context.environment
        let snapshot = context.snapshot
        self.environment = environment
        self.settings = settings
        self.persistence = StorePersistenceQueue(store: environment.persistenceStore)

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
    func finishLoad() async {
        await reconcileLoadedUnboundSessionLinks(
            requiresLinks: environment.requiresSessionLinkForLoadedUnboundThreads)
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

    /// Resolves once every enqueued persistence write has completed (test seam).
    public func flushPersistence() async { await persistence.flush() }

    // MARK: - Computed

    public var selectedThread: AgentThread? {
        guard let selectedThreadID, let index = threadIndexByID[selectedThreadID] else {
            return nil
        }
        return threads[index]
    }

    public var selectedThreadRequiresSessionLink: Bool {
        selectedThreadID.map { sessionLinkRequiredThreadIDs.contains($0) } ?? false
    }

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    public var activeProjects: [Project] { projects.filter { !$0.isArchived } }
    public var archivedProjects: [Project] { projects.filter { $0.isArchived } }

    public var activeThreadsForSelectedProject: [AgentThread] {
        cachedActiveThreadsByProject[selectedProjectID] ?? []
    }

    public var archivedThreadsForSelectedProject: [AgentThread] {
        cachedArchivedThreadsByProject[selectedProjectID] ?? []
    }

    public func activeThreads(for projectID: UUID) -> [AgentThread] {
        cachedActiveThreadsByProject[projectID] ?? []
    }

    public func archivedThreads(for projectID: UUID) -> [AgentThread] {
        cachedArchivedThreadsByProject[projectID] ?? []
    }

    public var archivedThreads: [AgentThread] {
        projects.flatMap { cachedArchivedThreadsByProject[$0.id] ?? [] }
    }

    public var hasArchivedThreadsForSelectedProject: Bool {
        !archivedThreadsForSelectedProject.isEmpty
    }

    public var hasArchivedThreads: Bool { !archivedThreads.isEmpty }

    public var windowTitle: String {
        guard let project = selectedProject else { return "Agent IDE" }
        guard let thread = selectedThread else { return project.displayName }
        return "\(project.displayName) - \(thread.displayName)"
    }

    public func projectDisplayName(for projectID: UUID) -> String {
        projects.first { $0.id == projectID }?.displayName ?? "Unknown Project"
    }

    public func isProjectExpanded(_ projectID: UUID) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    public func isProjectArchiveExpanded(_ projectID: UUID) -> Bool {
        expandedArchivedProjectIDs.contains(projectID)
    }

    public var selectedProjectDirectoryState: ProjectDirectoryState? {
        selectedProject.map { directoryState(for: $0.rootDirectory) }
    }

    public var selectedThreadWorkingDirectoryState: ProjectDirectoryState? {
        selectedThread.map { directoryState(for: $0.workingDirectory) }
    }

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
