// swiftlint:disable file_length
import Combine
import Foundation

public enum AppModelError: Error, Equatable {
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

private enum FileBrowserPresentationLimits {
    static let maxSearchResults = 1_000
    static let maxBrowseEntries = 10_000
    static let largeIndexDiagnosticThreshold = 50_000
    static let slowSearchDiagnosticThresholdMS = 100
    static let slowTreeBuildDiagnosticThresholdMS = 50
    // Defensive ceiling for the diagnostic "limited" flag — see RootView.FileBrowserPanelConstants.
    static let treeRowDiagnosticThreshold = 50_000
}

private struct AgentCLIPollRequest: Sendable {
    var thread: AgentThread
    var offset: UInt64
    var generation: Int
}

private struct AgentCLIPollResult: Sendable {
    var request: AgentCLIPollRequest
    var captured: AgentCLICapturedOutput
}

private enum AgentCLISessionSyncRequest: Sendable {
    case exactLink(thread: AgentThread)
    case catalogMetadata(thread: AgentThread)
}

private enum AgentCLISessionSyncResult: Sendable {
    case exactLink(threadID: UUID, candidate: SessionLinkCandidate?)
    case catalogMetadata(threadID: UUID, metadata: AgentCLISessionMetadata?)
}

private struct FileBrowserPresentationCacheEntry {
    var cacheKey: String
    var sourceEntryCount: Int
    var entries: [FileBrowserEntry]
}

public final class AppModel: ObservableObject, @unchecked Sendable {
    @Published public private(set) var projects: [Project]
    @Published public private(set) var threads: [AgentThread]
    @Published public private(set) var selectedProjectID: UUID
    @Published public private(set) var selectedThreadID: UUID?
    @Published public private(set) var rightPanelModesByThreadID: [UUID: RightPanelMode]
    @Published public private(set) var rightPanelStatesByThreadID: [UUID: RightPanelState]
    @Published public private(set) var bottomTerminalExpandedThreadIDs: Set<UUID>
    @Published public private(set) var layoutState: LayoutState
    @Published public private(set) var fileBrowserState: FileBrowserState
    @Published public private(set) var selectedFileRelativePath: String?
    @Published public private(set) var browserUnavailableMessagesByThreadID: [UUID: String]
    @Published public private(set) var configuration: YAAWConfiguration
    @Published public private(set) var systemAppearanceIsDark: Bool
    @Published public private(set) var agentCLIOptionCatalog: AgentCLIOptionCatalog
    @Published public private(set) var expandedProjectIDs: Set<UUID>
    @Published public private(set) var expandedArchivedProjectIDs: Set<UUID>
    @Published public private(set) var threadActivityByThreadID: [UUID: ThreadActivityState]
    @Published public private(set) var sessionLinkRequiredThreadIDs: Set<UUID>

    public let projectTerminal: TerminalSurfaceDescriptor
    public private(set) var navigationHistory: NavigationHistory
    private let store: YAAWStore
    private let terminalManager: TerminalSessionManaging
    private let agentCLIBindings: AgentCLISessionBindingService
    private let agentCLIOptionCatalogService: any AgentCLIOptionCatalogServicing
    private let fileIndexer: FileIndexing
    private let fileIndexCacheCoordinator: FileIndexCacheCoordinator
    private let fileIndexDirectoryWatcher: FileIndexDirectoryWatcher
    private let externalToolResolver: any AgentCLIExecutableResolving
    private let diagnosticRecorder: DiagnosticEventRecording
    private let notificationDispatcher: any ThreadActivityNotificationDispatching
    private let badgeUpdater: any ThreadActivityBadgeUpdating
    private let isApplicationActive: () -> Bool
    private let environment: [String: String]
    private let homeDirectory: URL
    private var fileIndexMetadataByThreadID: [UUID: FileIndexMetadata]
    private var fileBrowserEntriesByThreadID: [UUID: [FileBrowserEntry]] = [:]
    private var fileBrowserPresentationByThreadID: [UUID: FileBrowserPresentationCacheEntry] = [:]
    private var latestFileBrowserRequestIDByThreadID: [UUID: UUID] = [:]
    private var pendingSubtreeLoadsByThreadID: [UUID: Set<String>] = [:]
    // In-memory, per-thread file-browser open state. Not persisted: it survives thread
    // and right-panel-tab switches within a session and resets on relaunch.
    private var expandedFoldersByThreadID: [UUID: Set<String>] = [:]
    private var selectedFileByThreadID: [UUID: String] = [:]
    private var nvimRelativePathsByThreadID: [UUID: String] = [:]
    private var nvimRelaunchTokensByThreadID: [UUID: UUID] = [:]
    private var nvimRelaunchTokensByTabKey: [String: UUID] = [:]
    private var activeProjectLaunchDescriptorsByThreadID: [UUID: AgentTerminalLaunchDescriptor] =
        [:]
    private var captureReadOffsetsByThreadID: [UUID: UInt64] = [:]
    private var activityReadOffsetsByThreadID: [UUID: UInt64] = [:]
    private var activityPartialLinesByThreadID: [UUID: String] = [:]
    private var pendingTerminalTitlesByThreadID: [UUID: String] = [:]
    private var sessionLinkSkippedThreadIDs: Set<UUID> = []
    private var focusedProjectTerminalThreadID: UUID?
    private var threadIndexByID: [UUID: Int] = [:]
    private var cachedActiveThreadsByProject: [UUID: [AgentThread]] = [:]
    private var cachedArchivedThreadsByProject: [UUID: [AgentThread]] = [:]
    private let agentCLIPollQueue = DispatchQueue(
        label: "dev.dopsonbr.yaaw.agent-cli-poll", qos: .utility)
    // Capture/activity polling and the (potentially slow) session-catalog scan are coalesced
    // independently so a stalled catalog read can never block the latency-sensitive capture poll.
    private var isAgentCLICapturePollInFlight = false
    private var isAgentCLISessionSyncInFlight = false
    // Bumped whenever a thread's read offsets are reset (terminal close, link, new session) so an
    // in-flight background read whose result lands after such a reset is discarded instead of
    // resurrecting stale output for a torn-down/relinked session.
    private var agentCLIPollGenerationByThreadID: [UUID: Int] = [:]

    public init(
        store: YAAWStore = InMemoryYAAWStore.helloWorld(),
        terminalManager: TerminalSessionManaging = PlaceholderTerminalSessionManager(),
        agentCLIBindings: AgentCLISessionBindingService = AgentCLISessionBindingService(),
        agentCLIOptionCatalogService: any AgentCLIOptionCatalogServicing =
            AgentCLIOptionCatalogService(),
        fileIndexer: FileIndexing = BackgroundFileIndexer(),
        externalToolResolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        configuration: YAAWConfiguration = YAAWConfiguration(),
        systemAppearanceIsDark: Bool = true,
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared,
        notificationDispatcher: any ThreadActivityNotificationDispatching =
            NoopThreadActivityNotificationDispatcher(),
        badgeUpdater: any ThreadActivityBadgeUpdating = NoopThreadActivityBadgeUpdater(),
        isApplicationActive: @escaping () -> Bool = { false },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requiresSessionLinkForLoadedUnboundThreads: Bool? = nil
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.agentCLIBindings = agentCLIBindings
        self.agentCLIOptionCatalogService = agentCLIOptionCatalogService
        self.fileIndexer = fileIndexer
        self.fileIndexCacheCoordinator = FileIndexCacheCoordinator(
            store: store, fileIndexer: fileIndexer)
        self.fileIndexDirectoryWatcher = FileIndexDirectoryWatcher()
        self.externalToolResolver = externalToolResolver
        self.diagnosticRecorder = diagnosticRecorder
        self.notificationDispatcher = notificationDispatcher
        self.badgeUpdater = badgeUpdater
        self.isApplicationActive = isApplicationActive
        let validatedConfiguration = configuration.validated(diagnosticRecorder: diagnosticRecorder)
        self.configuration = validatedConfiguration
        self.systemAppearanceIsDark = systemAppearanceIsDark
        self.agentCLIOptionCatalog = agentCLIOptionCatalogService.loadCatalog()
        self.environment = environment
        self.homeDirectory = homeDirectory
        let snapshot = store.load()
        let globalChatsDirectory = Self.globalChatsDirectory(
            for: validatedConfiguration,
            homeDirectory: homeDirectory
        )
        Self.ensureGlobalChatsDirectoryExists(
            globalChatsDirectory,
            diagnosticRecorder: diagnosticRecorder
        )
        let loadedProjects = snapshot.projects.map { project in
            guard Self.isGlobalProject(project) else { return project }
            var project = project
            project.rootDirectory = globalChatsDirectory
            return project
        }
        let sortedProjects = Self.sortedProjects(loadedProjects)
        let requiresLinks =
            requiresSessionLinkForLoadedUnboundThreads ?? (store is SQLiteYAAWStore)
        self.projects = sortedProjects
        self.threads = snapshot.threads
        self.sessionLinkRequiredThreadIDs = []
        self.fileIndexMetadataByThreadID = snapshot.fileIndexMetadataByThreadID
        self.threadActivityByThreadID = snapshot.threadActivityByThreadID.mapValues {
            $0.downgradedForLaunch()
        }
        for (index, thread) in snapshot.threads.enumerated() {
            threadIndexByID[thread.id] = index
            if thread.isArchived {
                cachedArchivedThreadsByProject[thread.projectID, default: []].append(thread)
            } else {
                cachedActiveThreadsByProject[thread.projectID, default: []].append(thread)
            }
        }
        for projectID in cachedActiveThreadsByProject.keys {
            cachedActiveThreadsByProject[projectID]?.sort(by: Self.threadPrecedes)
        }
        for projectID in cachedArchivedThreadsByProject.keys {
            cachedArchivedThreadsByProject[projectID]?.sort(by: Self.threadPrecedes)
        }
        let fallbackProjectID =
            sortedProjects.first { !Self.isGlobalProject($0) && !$0.isArchived }?.id
            ?? sortedProjects.first { !$0.isArchived }?.id
            ?? sortedProjects[0].id
        let selectedProjectID =
            sortedProjects.contains { $0.id == snapshot.selectedProjectID && !$0.isArchived }
            ? snapshot.selectedProjectID
            : fallbackProjectID
        let selectedProjectIsGlobal =
            sortedProjects.first { $0.id == selectedProjectID }.map {
                Self.isGlobalProject($0)
            } ?? false
        let selectedThreadID: UUID?
        if selectedProjectIsGlobal {
            selectedThreadID = nil
        } else if let snapshotSelectedThreadID = snapshot.selectedThreadID,
            let selectedThread = snapshot.threads.first(where: { $0.id == snapshotSelectedThreadID }
            ),
            selectedThread.projectID == selectedProjectID,
            !selectedThread.isArchived
        {
            selectedThreadID = snapshotSelectedThreadID
        } else {
            selectedThreadID =
                snapshot.threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
        }
        self.selectedProjectID = selectedProjectID
        self.selectedThreadID = selectedThreadID
        var expandedProjectIDs = snapshot.expandedProjectIDs
        expandedProjectIDs.insert(selectedProjectID)
        self.expandedProjectIDs = expandedProjectIDs
        self.expandedArchivedProjectIDs = snapshot.expandedArchivedProjectIDs
        self.bottomTerminalExpandedThreadIDs = snapshot.bottomTerminalExpandedThreadIDs
        var rightPanelModesByThreadID = snapshot.rightPanelModesByThreadID
        if let selectedThreadID, rightPanelModesByThreadID[selectedThreadID] == nil {
            rightPanelModesByThreadID[selectedThreadID] = snapshot.selectedRightPanelMode
        }
        self.rightPanelModesByThreadID = rightPanelModesByThreadID
        var rightPanelStatesByThreadID = snapshot.rightPanelStatesByThreadID
        for thread in snapshot.threads where rightPanelStatesByThreadID[thread.id] == nil {
            let mode =
                rightPanelModesByThreadID[thread.id]
                ?? (thread.id == selectedThreadID ? snapshot.selectedRightPanelMode : .files)
            rightPanelStatesByThreadID[thread.id] = RightPanelState.defaultState(selectedMode: mode)
        }
        self.rightPanelStatesByThreadID = rightPanelStatesByThreadID
        self.layoutState = snapshot.layoutState
        self.fileBrowserState = FileBrowserState(
            rootPath: selectedThreadID.flatMap { threadID in
                snapshot.threads.first { $0.id == threadID }?.workingDirectory.path
            },
            metadata: selectedThreadID.flatMap { snapshot.fileIndexMetadataByThreadID[$0] }
        )
        self.selectedFileRelativePath = nil
        self.browserUnavailableMessagesByThreadID = [:]
        self.navigationHistory = NavigationHistory(
            initial: AppSelection(projectID: selectedProjectID, threadID: selectedThreadID)
        )
        self.projectTerminal = TerminalSurfaceDescriptor(
            kind: .project,
            title: "Project Terminal",
            placeholderText: "Terminal placeholder for the selected thread"
        )
        reconcileLoadedUnboundSessionLinks(requiresLinks: requiresLinks)
        persistLaunchDowngradedThreadActivity(snapshot.threadActivityByThreadID)
        updateDockBadge()
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

    /// Projects shown in the main sidebar list (everything not archived).
    public var activeProjects: [Project] {
        projects.filter { !$0.isArchived }
    }

    /// Archived projects, surfaced in the bottom "Archived" section.
    public var archivedProjects: [Project] {
        projects.filter { $0.isArchived }
    }

    private func rebuildThreadIndexes() {
        threadIndexByID.removeAll(keepingCapacity: true)
        cachedActiveThreadsByProject.removeAll(keepingCapacity: true)
        cachedArchivedThreadsByProject.removeAll(keepingCapacity: true)
        for (index, thread) in threads.enumerated() {
            threadIndexByID[thread.id] = index
            if thread.isArchived {
                cachedArchivedThreadsByProject[thread.projectID, default: []].append(thread)
            } else {
                cachedActiveThreadsByProject[thread.projectID, default: []].append(thread)
            }
        }
        for projectID in cachedActiveThreadsByProject.keys {
            cachedActiveThreadsByProject[projectID]?.sort(by: Self.threadPrecedes)
        }
        for projectID in cachedArchivedThreadsByProject.keys {
            cachedArchivedThreadsByProject[projectID]?.sort(by: Self.threadPrecedes)
        }
    }

    private func mutateThreads(_ block: (inout [AgentThread]) -> Void) {
        block(&threads)
        rebuildThreadIndexes()
    }

    private func mutateThread(at index: Int, _ block: (inout AgentThread) -> Void) {
        let previousThread = threads[index]
        block(&threads[index])
        let updatedThread = threads[index]
        if previousThread.id != updatedThread.id {
            threadIndexByID.removeValue(forKey: previousThread.id)
        }
        threadIndexByID[updatedThread.id] = index
        updateCachedThread(previousThread: previousThread, updatedThread: updatedThread)
    }

    private func updateCachedThread(previousThread: AgentThread, updatedThread: AgentThread) {
        if previousThread.projectID == updatedThread.projectID,
            previousThread.isArchived == updatedThread.isArchived
        {
            replaceCachedThread(updatedThread, matching: previousThread)
        } else {
            removeCachedThread(previousThread)
            insertCachedThread(updatedThread)
        }
    }

    private func replaceCachedThread(_ thread: AgentThread, matching previousThread: AgentThread) {
        if thread.isArchived {
            replaceCachedThread(
                thread, matching: previousThread, in: &cachedArchivedThreadsByProject)
        } else {
            replaceCachedThread(thread, matching: previousThread, in: &cachedActiveThreadsByProject)
        }
    }

    private func replaceCachedThread(
        _ thread: AgentThread,
        matching previousThread: AgentThread,
        in cache: inout [UUID: [AgentThread]]
    ) {
        let projectID = thread.projectID
        guard let currentIndex = cache[projectID]?.firstIndex(where: { $0.id == previousThread.id })
        else {
            insertCachedThread(thread, into: &cache)
            return
        }

        cache[projectID]?.remove(at: currentIndex)
        let insertionIndex =
            cache[projectID]?.firstIndex { Self.threadPrecedes(thread, $0) }
            ?? cache[projectID]?.endIndex
            ?? 0
        cache[projectID]?.insert(thread, at: insertionIndex)
    }

    private func removeCachedThread(_ thread: AgentThread) {
        if thread.isArchived {
            removeCachedThread(thread, from: &cachedArchivedThreadsByProject)
        } else {
            removeCachedThread(thread, from: &cachedActiveThreadsByProject)
        }
    }

    private func removeCachedThread(_ thread: AgentThread, from cache: inout [UUID: [AgentThread]])
    {
        guard var projectThreads = cache[thread.projectID] else { return }
        projectThreads.removeAll { $0.id == thread.id }
        if projectThreads.isEmpty {
            cache.removeValue(forKey: thread.projectID)
        } else {
            cache[thread.projectID] = projectThreads
        }
    }

    private func insertCachedThread(_ thread: AgentThread) {
        if thread.isArchived {
            insertCachedThread(thread, into: &cachedArchivedThreadsByProject)
        } else {
            insertCachedThread(thread, into: &cachedActiveThreadsByProject)
        }
    }

    private func insertCachedThread(_ thread: AgentThread, into cache: inout [UUID: [AgentThread]])
    {
        var projectThreads = cache[thread.projectID] ?? []
        projectThreads.removeAll { $0.id == thread.id }
        let insertionIndex =
            projectThreads.firstIndex { Self.threadPrecedes(thread, $0) } ?? projectThreads.endIndex
        projectThreads.insert(thread, at: insertionIndex)
        cache[thread.projectID] = projectThreads
    }

    private func thread(withID threadID: UUID) -> AgentThread? {
        threadIndexByID[threadID].map { threads[$0] }
    }

    private func firstActiveThreadID(forProject projectID: UUID) -> UUID? {
        cachedActiveThreadsByProject[projectID]?.first?.id
    }

    private static func globalChatsDirectory(
        for configuration: YAAWConfiguration,
        homeDirectory: URL
    ) -> URL {
        configuration.projects.resolvedGlobalChatsDirectory(homeDirectory: homeDirectory)
    }

    private static func ensureGlobalChatsDirectoryExists(
        _ directory: URL,
        diagnosticRecorder: DiagnosticEventRecording?
    ) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            diagnosticRecorder?.record(
                DiagnosticEvent(
                    category: "Projects",
                    name: "global_chats_directory_create_failed",
                    metadata: [
                        "path": directory.path,
                        "error": String(describing: error),
                    ]
                )
            )
        }
    }

    private static func isGlobalProject(_ project: Project) -> Bool {
        project.displayName == "Global"
    }

    private func isGlobalProject(_ project: Project) -> Bool {
        Self.isGlobalProject(project)
    }

    private var globalChatsDirectory: URL {
        Self.globalChatsDirectory(for: configuration, homeDirectory: homeDirectory)
    }

    private func ensureGlobalChatsDirectoryExists() {
        Self.ensureGlobalChatsDirectoryExists(
            globalChatsDirectory,
            diagnosticRecorder: diagnosticRecorder
        )
    }

    private func reconcileGlobalProjectDirectory(previousGlobalChatsDirectory: URL? = nil) {
        let directory = globalChatsDirectory
        ensureGlobalChatsDirectoryExists()
        var didChange = false
        for index in projects.indices where isGlobalProject(projects[index]) {
            let previousPath = projects[index].rootDirectory.standardizedFileURL.path
            guard previousPath != directory.standardizedFileURL.path else { continue }
            projects[index].rootDirectory = directory
            persistProject(projects[index])
            didChange = true
        }
        if didChange {
            projects = Self.sortedProjects(projects)
            if let selectedProject = selectedProject, isGlobalProject(selectedProject) {
                selectedThreadID = nil
                persistSelection()
            }
            recordDiagnostic(
                category: "Projects",
                name: "global_chats_directory_updated",
                metadata: [
                    "path": directory.path,
                    "previous_path": previousGlobalChatsDirectory?.path ?? "",
                ]
            )
        }
    }

    private static func sortedProjects(_ projects: [Project]) -> [Project] {
        projects.sorted { lhs, rhs in
            let lhsIsGlobal = isGlobalProject(lhs)
            let rhsIsGlobal = isGlobalProject(rhs)
            if lhsIsGlobal != rhsIsGlobal {
                return !lhsIsGlobal && rhsIsGlobal
            }
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func threadPrecedes(_ lhs: AgentThread, _ rhs: AgentThread) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }
        if lhs.lastOpenedAt != rhs.lastOpenedAt {
            return lhs.lastOpenedAt > rhs.lastOpenedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private static func normalizedThreadName(_ name: String) -> String? {
        let normalized =
            name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    public var windowTitle: String {
        guard let project = selectedProject else { return "Agent IDE" }
        guard let thread = selectedThread else { return project.displayName }
        return "\(project.displayName) - \(thread.displayName)"
    }

    public var defaultAgentCLI: AgentCLIKind {
        configuration.defaultAgentCLI
    }

    public func permissionModes(for agentCLI: AgentCLIKind) -> [AgentPermissionMode] {
        agentCLIOptionCatalog.permissionPresets(for: agentCLI)
    }

    public func configuredLaunchOptions(for agentCLI: AgentCLIKind) -> AgentLaunchOptions {
        configuration.defaultLaunchOptions(for: agentCLI)
            .validated(for: agentCLI, permissionModes: permissionModes(for: agentCLI))
    }

    @discardableResult
    public func refreshAgentCLIOptionCatalog() -> AgentCLIOptionCatalog {
        let catalog = agentCLIOptionCatalogService.refreshCatalog(
            configuration: configuration,
            resolver: externalToolResolver,
            environment: environment
        )
        agentCLIOptionCatalog = catalog
        recordDiagnostic(
            category: "AgentCLIOptions",
            name: "catalog_refreshed",
            metadata: [
                "agent_count": "\(catalog.entries.count)"
            ]
        )
        return catalog
    }

    public func keyboardShortcutDefinition(for action: KeyboardShortcutAction)
        -> KeyboardShortcutDefinition
    {
        configuration.shortcut(for: action)
    }

    public func isKeyboardShortcutEnabled(for action: KeyboardShortcutAction) -> Bool {
        let definition = keyboardShortcutDefinition(for: action)
        return definition.isBound
            && !configuration.keyboardShortcuts.duplicateActions().contains(action)
    }

    public func reloadConfiguration(_ configuration: YAAWConfiguration) {
        let previousGlobalChatsDirectory = globalChatsDirectory
        self.configuration = configuration.validated(diagnosticRecorder: diagnosticRecorder)
        reconcileGlobalProjectDirectory(previousGlobalChatsDirectory: previousGlobalChatsDirectory)
        activeProjectLaunchDescriptorsByThreadID.removeAll()
        activityPartialLinesByThreadID.removeAll()
        recordDiagnostic(
            category: "Configuration",
            name: "settings_yaml_reloaded",
            metadata: [
                "theme": self.configuration.themeName,
                "default_agent": self.configuration.defaultAgentCLI.rawValue,
                "file_icon_pack": self.configuration.fileIconPack.rawValue,
                "interface_font_size": "\(self.configuration.fonts.interfaceSize)",
                "editor_font_size": "\(self.configuration.fonts.editorSize)",
                "terminal_font_size": "\(self.configuration.fonts.terminalSize)",
            ]
        )
        refreshSelectedFileBrowser()
    }

    /// The active theme, resolving the System pairing against the live macOS
    /// appearance pushed in by the app layer.
    public var resolvedTheme: ThemeDefinition {
        configuration.resolvedTheme(systemAppearanceIsDark: systemAppearanceIsDark)
    }

    public func updateSystemAppearance(isDark: Bool) {
        guard systemAppearanceIsDark != isDark else { return }
        systemAppearanceIsDark = isDark
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
        guard let project = selectedProject,
            isExistingDirectory(project.rootDirectory)
        else {
            return nil
        }
        return ExternalOpenTarget(url: project.rootDirectory, kind: .directory)
    }

    public func externalOpenFileTarget(relativePath: String) -> ExternalOpenTarget? {
        fileBrowserExternalOpenTarget(relativePath: relativePath, isDirectory: false)
    }

    public func fileBrowserExternalOpenTarget(relativePath: String, isDirectory: Bool)
        -> ExternalOpenTarget?
    {
        guard let url = fileBrowserURL(relativePath: relativePath) else { return nil }
        return ExternalOpenTarget(
            url: url,
            kind: isDirectory ? .directory : .file
        )
    }

    public func fileBrowserURL(relativePath: String) -> URL? {
        selectedThreadFileURL(relativePath: relativePath)?.url
    }

    private func selectedThreadFileURL(relativePath: String) -> (normalizedPath: String, url: URL)?
    {
        guard let thread = selectedThread,
            isExistingDirectory(thread.workingDirectory)
        else {
            return nil
        }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        guard !normalizedPath.isEmpty else { return nil }
        let root = thread.workingDirectory.standardizedFileURL
        let url = root.appendingPathComponent(normalizedPath).standardizedFileURL
        let rootPath = root.path
        let path = url.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return (normalizedPath, url)
    }

    public var selectedExternalOpenFileTarget: ExternalOpenTarget? {
        guard let selectedFileRelativePath else { return nil }
        return externalOpenFileTarget(relativePath: selectedFileRelativePath)
    }

    public var selectedRightPanelMode: RightPanelMode {
        guard let selectedThreadID else { return .files }
        return rightPanelStatesByThreadID[selectedThreadID]?.selectedMode
            ?? rightPanelModesByThreadID[selectedThreadID]
            ?? .files
    }

    public var selectedRightPanelState: RightPanelState {
        guard let selectedThreadID else { return RightPanelState() }
        return rightPanelStatesByThreadID[selectedThreadID]
            ?? RightPanelState.defaultState(
                selectedMode: rightPanelModesByThreadID[selectedThreadID] ?? .files
            )
    }

    public var selectedRightPanelTab: RightPanelTab {
        selectedRightPanelState.selectedTab
    }

    public var selectedBrowserUnavailableMessage: String? {
        selectedThreadID.flatMap { browserUnavailableMessagesByThreadID[$0] }
    }

    public var isBottomTerminalExpanded: Bool {
        selectedThreadID.map { bottomTerminalExpandedThreadIDs.contains($0) } ?? false
    }

    public var isGlobalTerminalExpanded: Bool {
        isBottomTerminalExpanded
    }

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

    public func lastInteractionDate(for thread: AgentThread) -> Date {
        guard let activity = threadActivityByThreadID[thread.id] else {
            return thread.lastOpenedAt
        }
        return max(thread.lastOpenedAt, activity.updatedAt)
    }

    public var archivedThreads: [AgentThread] {
        projects.flatMap { project in
            cachedArchivedThreadsByProject[project.id] ?? []
        }
    }

    public func projectDisplayName(for projectID: UUID) -> String {
        projects.first { $0.id == projectID }?.displayName ?? "Unknown Project"
    }

    public var unreadThreadActivityCount: Int {
        threadActivityByThreadID.values.filter(\.isUnread).count
    }

    public func threadActivity(for threadID: UUID) -> ThreadActivityState {
        threadActivityByThreadID[threadID] ?? ThreadActivityState(threadID: threadID)
    }

    public var hasArchivedThreadsForSelectedProject: Bool {
        !archivedThreadsForSelectedProject.isEmpty
    }

    public var hasArchivedThreads: Bool {
        !archivedThreads.isEmpty
    }

    public func isProjectExpanded(_ projectID: UUID) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    public func isProjectArchiveExpanded(_ projectID: UUID) -> Bool {
        expandedArchivedProjectIDs.contains(projectID)
    }

    public var terminalLifecycleEvents: [TerminalLifecycleEvent] {
        terminalManager.lifecycleEvents
    }

    public func selectRightPanelMode(_ mode: RightPanelMode) {
        guard let selectedThreadID else { return }
        rightPanelModesByThreadID[selectedThreadID] = mode
        var state = selectedRightPanelState
        state.selectMode(mode)
        rightPanelStatesByThreadID[selectedThreadID] = state
        persistRightPanelMode(threadID: selectedThreadID)
        persistRightPanelState(threadID: selectedThreadID)
    }

    public func selectRightPanelTab(id tabID: String) {
        guard let selectedThreadID else { return }
        var state = selectedRightPanelState
        state.selectTab(id: tabID)
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = state.selectedMode
        persistRightPanelMode(threadID: selectedThreadID)
        persistRightPanelState(threadID: selectedThreadID)
    }

    public func closeRightPanelTab(id tabID: String) {
        guard let selectedThreadID else { return }
        var state = selectedRightPanelState
        guard let closedTab = state.closeTab(id: tabID) else { return }
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = state.selectedMode
        switch closedTab.kind {
        case .browser:
            browserUnavailableMessagesByThreadID.removeValue(forKey: selectedThreadID)
        case .nvim:
            terminateTerminal(role: .nvimTab(threadID: selectedThreadID, tabID: closedTab.id))
            nvimRelaunchTokensByTabKey.removeValue(
                forKey: nvimTabKey(threadID: selectedThreadID, tabID: closedTab.id))
        case .files, .git:
            break
        }
        persistRightPanelMode(threadID: selectedThreadID)
        persistRightPanelState(threadID: selectedThreadID)
    }

    public func cycleRightPanelModeForward() {
        selectRightPanelMode(selectedRightPanelMode.next)
    }

    public func cycleRightPanelModeBackward() {
        selectRightPanelMode(selectedRightPanelMode.previous)
    }

    public func toggleBottomTerminal() {
        guard let selectedThreadID else { return }
        if bottomTerminalExpandedThreadIDs.contains(selectedThreadID) {
            bottomTerminalExpandedThreadIDs.remove(selectedThreadID)
        } else {
            bottomTerminalExpandedThreadIDs.insert(selectedThreadID)
        }
        recordDiagnostic(
            category: "Layout",
            name: "bottom_terminal_toggled",
            metadata: [
                "thread_id": selectedThreadID.uuidString,
                "expanded": "\(bottomTerminalExpandedThreadIDs.contains(selectedThreadID))",
            ]
        )
        persistBottomTerminalExpanded(threadID: selectedThreadID)
    }

    public func toggleGlobalTerminal() {
        toggleBottomTerminal()
    }

    public func toggleSidebarCollapsed() {
        layoutState.isSidebarCollapsed.toggle()
        persistLayout()
    }

    public func toggleRightPanelCollapsed() {
        layoutState.isRightPanelCollapsed.toggle()
        persistLayout()
    }

    public func toggleWorkspaceSwap() {
        layoutState.isWorkspaceSwapped.toggle()
        persistLayout()
    }

    public func setSidebarWidth(_ width: Double, persist: Bool = true) {
        layoutState.sidebarWidth = LayoutState.clamp(
            width,
            minimum: LayoutState.minimumSidebarWidth,
            maximum: LayoutState.maximumSidebarWidth
        )
        if persist {
            persistLayout()
        }
    }

    public func setRightPanelWidth(_ width: Double, persist: Bool = true) {
        layoutState.rightPanelWidth = LayoutState.clampMinimum(
            width,
            minimum: LayoutState.minimumRightPanelWidth
        )
        if persist {
            persistLayout()
        }
    }

    public func setGlobalTerminalHeight(
        _ height: Double,
        availableWindowHeight: Double? = nil,
        persist: Bool = true
    ) {
        layoutState.globalTerminalHeight = LayoutState.clampedGlobalTerminalHeight(
            height,
            availableWindowHeight: availableWindowHeight
        )
        if persist {
            persistLayout()
        }
    }

    public func resetSidebarWidth(persist: Bool = true) {
        layoutState.resetSidebarWidth()
        if persist {
            persistLayout()
        }
    }

    public func resetRightPanelWidth(persist: Bool = true) {
        layoutState.resetRightPanelWidth()
        if persist {
            persistLayout()
        }
    }

    public func resetGlobalTerminalHeight(persist: Bool = true) {
        layoutState.resetGlobalTerminalHeight()
        if persist {
            persistLayout()
        }
    }

    public func commitLayoutResize() {
        persistLayout()
    }

    public func terminalLaunchRequest(for role: TerminalRole) -> TerminalLaunchRequest? {
        switch role {
        case .bottom(let threadID):
            guard let thread = activeThread(id: threadID) else { return nil }
            guard isExistingDirectory(thread.workingDirectory) else {
                recordTerminalLaunchFailure(
                    role: role,
                    path: thread.workingDirectory.path,
                    reason: "missing_working_directory"
                )
                return nil
            }
            return TerminalLaunchRequest(
                role: role,
                title: "Bottom Terminal",
                workingDirectory: thread.workingDirectory,
                command: [defaultShellPath()],
                agentCLI: thread.agentCLI
            )
        case .project(let threadID):
            guard var thread = activeThread(id: threadID) else { return nil }
            if sessionLinkRequiredThreadIDs.contains(threadID),
                !autoLinkUnboundThreadIfExactMatch(
                    threadID: threadID,
                    diagnosticName: "session_auto_linked_before_launch"
                )
            {
                recordDiagnostic(
                    category: "AgentCLI",
                    name: "session_link_required",
                    metadata: [
                        "thread_id": threadID.uuidString,
                        "agent_cli": thread.agentCLI.rawValue,
                    ]
                )
                return nil
            }
            thread = activeThread(id: threadID) ?? thread
            guard isExistingDirectory(thread.workingDirectory) else {
                recordTerminalLaunchFailure(
                    role: role,
                    path: thread.workingDirectory.path,
                    reason: "missing_working_directory"
                )
                return nil
            }
            let launchDescriptor: AgentTerminalLaunchDescriptor
            if let activeLaunchDescriptor = activeProjectLaunchDescriptorsByThreadID[threadID] {
                launchDescriptor = activeLaunchDescriptor
            } else {
                captureReadOffsetsByThreadID.removeValue(forKey: threadID)
                bumpAgentCLIPollGeneration(for: threadID)
                launchDescriptor = agentCLIBindings.terminalLaunchDescriptor(
                    for: thread,
                    executableNameOverride: configuration.agentExecutableName(for: thread.agentCLI),
                    permissionModes: permissionModes(for: thread.agentCLI)
                )
            }
            activeProjectLaunchDescriptorsByThreadID[threadID] = launchDescriptor
            return TerminalLaunchRequest(
                role: role,
                title: "\(thread.agentCLI.displayName) Terminal",
                workingDirectory: thread.workingDirectory,
                command: launchDescriptor.command,
                backend: .agentPTY(launchDescriptor),
                agentCLI: thread.agentCLI
            )
        case .nvim(let threadID):
            guard let thread = activeThread(id: threadID) else { return nil }
            guard isExistingDirectory(thread.workingDirectory) else {
                recordTerminalLaunchFailure(
                    role: role,
                    path: thread.workingDirectory.path,
                    reason: "missing_working_directory"
                )
                return nil
            }
            let arguments = nvimRelativePathsByThreadID[threadID].map { [$0] } ?? []
            return TerminalLaunchRequest(
                role: role,
                title: "nvim",
                workingDirectory: thread.workingDirectory,
                command: externalToolCommand(
                    preferredNames: configuration.tools.editors.preferred,
                    arguments: arguments
                ),
                relaunchToken: nvimRelaunchTokensByThreadID[threadID],
                agentCLI: thread.agentCLI
            )
        case .nvimTab(let threadID, let tabID):
            guard let thread = activeThread(id: threadID) else { return nil }
            guard isExistingDirectory(thread.workingDirectory) else {
                recordTerminalLaunchFailure(
                    role: role,
                    path: thread.workingDirectory.path,
                    reason: "missing_working_directory"
                )
                return nil
            }
            guard
                let tab = rightPanelStatesByThreadID[threadID]?.tabs.first(where: { $0.id == tabID }
                ),
                tab.kind == .nvim
            else {
                return nil
            }
            let arguments = tab.relativePath.map { [$0] } ?? []
            return TerminalLaunchRequest(
                role: role,
                title: tab.title,
                workingDirectory: thread.workingDirectory,
                command: externalToolCommand(
                    preferredNames: configuration.tools.editors.preferred,
                    arguments: arguments
                ),
                relaunchToken: nvimRelaunchTokensByTabKey[
                    nvimTabKey(threadID: threadID, tabID: tabID)],
                agentCLI: thread.agentCLI
            )
        case .lazygit(let threadID):
            guard let thread = activeThread(id: threadID) else { return nil }
            guard isExistingDirectory(thread.workingDirectory) else {
                recordTerminalLaunchFailure(
                    role: role,
                    path: thread.workingDirectory.path,
                    reason: "missing_working_directory"
                )
                return nil
            }
            return TerminalLaunchRequest(
                role: role,
                title: "Git",
                workingDirectory: thread.workingDirectory,
                command: gitToolCommand(),
                agentCLI: thread.agentCLI
            )
        }
    }

    @discardableResult
    public func activateTerminal(role: TerminalRole) -> TerminalSessionRecord? {
        guard let request = terminalLaunchRequest(for: role) else { return nil }
        recordDiagnostic(
            category: "Terminal",
            name: "terminal_launch_requested",
            metadata: [
                "role": role.diagnosticName,
                "surface": role.surfaceKind.rawValue,
            ]
        )
        return terminalManager.activate(request)
    }

    @discardableResult
    public func activateSelectedProjectTerminal() -> TerminalSessionRecord? {
        guard let selectedThreadID else { return nil }
        return activateTerminal(role: .project(threadID: selectedThreadID))
    }

    @discardableResult
    public func activateSelectedBottomTerminal() -> TerminalSessionRecord? {
        guard let selectedThreadID else { return nil }
        return activateTerminal(role: .bottom(threadID: selectedThreadID))
    }

    public func activateGlobalTerminal() -> TerminalSessionRecord? {
        activateSelectedBottomTerminal()
    }

    @discardableResult
    public func activateSelectedRightPanelTerminal() -> TerminalSessionRecord? {
        guard let selectedThreadID else { return nil }
        let tab = selectedRightPanelTab
        switch tab.kind {
        case .files, .browser:
            return nil
        case .git:
            return activateTerminal(role: .lazygit(threadID: selectedThreadID))
        case .nvim:
            return activateTerminal(role: .nvimTab(threadID: selectedThreadID, tabID: tab.id))
        }
    }

    /// Set by the app layer to tear down an out-of-process terminal helper when
    /// its terminal is terminated. Keeps AppModel agnostic of the isolation
    /// runtime (which lives in the app target).
    public var onTerminalTerminated: ((TerminalRole) -> Void)?

    public func terminateTerminal(role: TerminalRole) {
        onTerminalTerminated?(role)
        terminalManager.terminate(role: role)
        if case .project(let threadID) = role {
            activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
            captureReadOffsetsByThreadID.removeValue(forKey: threadID)
            activityReadOffsetsByThreadID.removeValue(forKey: threadID)
            activityPartialLinesByThreadID.removeValue(forKey: threadID)
            recordAgentTerminalClosed(threadID: threadID)
        }
    }

    public func terminalSession(for role: TerminalRole) -> TerminalSessionRecord? {
        terminalManager.session(for: role)
    }

    public func recordAgentCLIOutput(
        threadID: UUID,
        output: String,
        terminalTitle: String? = nil
    ) {
        guard let index = threadIndexByID[threadID] else {
            return
        }
        applyInferredTerminalOutputActivity(threadID: threadID, output: output)
        if var metadata = agentCLIBindings.metadata(
            for: threads[index].agentCLI,
            output: output,
            terminalTitle: terminalTitle
        ) {
            if metadata.reportedName == nil,
                metadata.title == nil,
                let pendingTitle = pendingTerminalTitlesByThreadID[threadID]
            {
                metadata.title = pendingTitle
            }
            applyAgentCLIMetadata(metadata, toThreadAt: index)
        }
    }

    public func recordAgentCLITerminalTitle(threadID: UUID, title: String) {
        guard let index = threadIndexByID[threadID] else {
            return
        }
        pendingTerminalTitlesByThreadID[threadID] = title
        // For CLIs whose terminal title is transient tool activity (e.g. Claude shows
        // "Bash"/"Read"), surface it as the activity subtitle and keep the thread name
        // stable instead of letting the title rename the thread.
        if !agentCLIBindings.usesTerminalTitleAsSessionName(for: threads[index].agentCLI) {
            // When the title just echoes the thread name (Claude does this when idle), the
            // subtitle is redundant — clear it so only the name shows.
            let normalizedTitle = ThreadActivityText.sanitized(title)
            let isRedundant =
                normalizedTitle == threads[index].displayName
                || normalizedTitle == threads[index].canonicalSessionName
            applyThreadActivity(
                ThreadActivityEvent(
                    threadID: threadID,
                    status: nil,
                    title: isRedundant ? nil : title,
                    body: nil,
                    source: .terminalLifecycle
                ),
                isUnread: false,
                shouldNotify: false
            )
            return
        }
        guard let identity = threads[index].sessionIdentity,
            threads[index].canonicalSessionName == nil
                || threads[index].canonicalSessionName == identity
        else { return }
        let metadata = agentCLIBindings.metadata(
            fromExistingIdentity: identity,
            terminalTitle: title
        )
        applyAgentCLIMetadata(metadata, toThreadAt: index)
    }

    public func recordAgentTerminalFocus(threadID: UUID, focused: Bool) {
        if focused {
            focusedProjectTerminalThreadID = threadID
            markThreadActivityRead(threadID: threadID)
        } else if focusedProjectTerminalThreadID == threadID {
            focusedProjectTerminalThreadID = nil
        }
    }

    public func recordAgentTerminalNotification(threadID: UUID, title: String, body: String) {
        let status = ThreadActivityText.inferredStatus(title: title, body: body)
        applyThreadActivity(
            ThreadActivityEvent(
                threadID: threadID,
                status: status,
                title: title,
                body: body,
                source: .terminalNotification
            ),
            isUnread: true,
            shouldNotify: true
        )
    }

    private func applyInferredTerminalOutputActivity(threadID: UUID, output: String) {
        guard let status = ThreadActivityText.inferredStatus(fromTerminalOutput: output) else {
            return
        }
        applyThreadActivity(
            ThreadActivityEvent(
                threadID: threadID,
                status: status,
                title: nil,
                body: nil,
                source: .terminalLifecycle
            ),
            isUnread: false,
            shouldNotify: false
        )
    }

    public func recordAgentTerminalClosed(threadID: UUID) {
        activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
        captureReadOffsetsByThreadID.removeValue(forKey: threadID)
        activityReadOffsetsByThreadID.removeValue(forKey: threadID)
        activityPartialLinesByThreadID.removeValue(forKey: threadID)
        bumpAgentCLIPollGeneration(for: threadID)
        applyThreadActivity(
            ThreadActivityEvent(
                threadID: threadID,
                status: .inactive,
                title: "Terminal closed",
                body: nil,
                source: .terminalLifecycle
            ),
            isUnread: false,
            shouldNotify: false
        )
        if focusedProjectTerminalThreadID == threadID {
            focusedProjectTerminalThreadID = nil
        }
    }

    public func recordAgentCommandFinished(threadID: UUID, exitCode: Int?) {
        let body = exitCode.map { "Command exited with status \($0)" } ?? "Command finished"
        applyThreadActivity(
            ThreadActivityEvent(
                threadID: threadID,
                status: .complete,
                title: "Command finished",
                body: body,
                source: .terminalLifecycle
            ),
            isUnread: false,
            shouldNotify: false
        )
    }

    public func pollSelectedAgentCLICaptureLog() {
        guard let thread = selectedThread,
            let captured = agentCLIBindings.capturedOutput(
                for: thread,
                after: captureReadOffsetsByThreadID[thread.id] ?? 0
            )
        else {
            return
        }
        applyAgentCLICaptureResult(threadID: thread.id, captured: captured)
    }

    public func pollAgentCLIActivityLogs() {
        for threadID in threadIDsForAgentCLIActivityPolling() {
            guard let thread = activeThread(id: threadID),
                let captured = agentCLIBindings.capturedActivityEvents(
                    for: thread,
                    after: activityReadOffsetsByThreadID[thread.id] ?? 0
                )
            else {
                continue
            }
            applyAgentCLIActivityResult(threadID: thread.id, captured: captured)
        }
    }

    // Shared application logic for a capture read, used by both the synchronous poll (tests/E2E) and
    // the off-main background poll, so there is a single source of truth for offset bookkeeping.
    private func applyAgentCLICaptureResult(threadID: UUID, captured: AgentCLICapturedOutput) {
        captureReadOffsetsByThreadID[threadID] = captured.nextOffset
        recordAgentCLIOutput(threadID: threadID, output: captured.output)
    }

    // Shared application logic for an activity-log read (see applyAgentCLICaptureResult).
    private func applyAgentCLIActivityResult(threadID: UUID, captured: AgentCLICapturedOutput) {
        let previousOffset = activityReadOffsetsByThreadID[threadID] ?? 0
        if captured.startOffset != previousOffset {
            activityPartialLinesByThreadID.removeValue(forKey: threadID)
        }
        activityReadOffsetsByThreadID[threadID] = captured.nextOffset
        let completeOutput = completeActivityLogOutput(threadID: threadID, output: captured.output)
        for event in ThreadActivityEvent.helperEvents(from: completeOutput) {
            applyThreadActivity(
                event,
                isUnread: event.status != .working && event.status != .inactive,
                shouldNotify: true
            )
        }
    }

    public func pollAgentCLIStateInBackground() {
        pollAgentCLICaptureAndActivityInBackground()
        pollAgentCLISessionSyncInBackground()
    }

    private func pollAgentCLICaptureAndActivityInBackground() {
        guard !isAgentCLICapturePollInFlight else { return }

        let captureRequest = selectedThread.map { thread in
            AgentCLIPollRequest(
                thread: thread,
                offset: captureReadOffsetsByThreadID[thread.id] ?? 0,
                generation: agentCLIPollGeneration(for: thread.id)
            )
        }
        let activityRequests = threadIDsForAgentCLIActivityPolling().compactMap {
            threadID -> AgentCLIPollRequest? in
            activeThread(id: threadID).map { thread in
                AgentCLIPollRequest(
                    thread: thread,
                    offset: activityReadOffsetsByThreadID[thread.id] ?? 0,
                    generation: agentCLIPollGeneration(for: thread.id)
                )
            }
        }
        guard captureRequest != nil || !activityRequests.isEmpty else { return }
        isAgentCLICapturePollInFlight = true
        let agentCLIBindings = agentCLIBindings

        agentCLIPollQueue.async { [agentCLIBindings] in
            let captureResult = captureRequest.flatMap { request -> AgentCLIPollResult? in
                agentCLIBindings.capturedOutput(for: request.thread, after: request.offset)
                    .map { AgentCLIPollResult(request: request, captured: $0) }
            }
            let activityResults = activityRequests.compactMap { request -> AgentCLIPollResult? in
                agentCLIBindings.capturedActivityEvents(for: request.thread, after: request.offset)
                    .map { AgentCLIPollResult(request: request, captured: $0) }
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishAgentCLICaptureAndActivityPoll(
                    captureResult: captureResult,
                    activityResults: activityResults
                )
            }
        }
    }

    private func pollAgentCLISessionSyncInBackground() {
        guard !isAgentCLISessionSyncInFlight,
            let syncRequest = selectedThreadSessionSyncRequest()
        else { return }
        isAgentCLISessionSyncInFlight = true
        let agentCLIBindings = agentCLIBindings

        agentCLIPollQueue.async { [agentCLIBindings] in
            let syncResult: AgentCLISessionSyncResult
            switch syncRequest {
            case .exactLink(let thread):
                syncResult = .exactLink(
                    threadID: thread.id,
                    candidate: agentCLIBindings.exactSessionLinkCandidate(for: thread)
                )
            case .catalogMetadata(let thread):
                syncResult = .catalogMetadata(
                    threadID: thread.id,
                    metadata: agentCLIBindings.catalogMetadata(for: thread)
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishAgentCLISessionSyncPoll(syncResult)
            }
        }
    }

    private func finishAgentCLICaptureAndActivityPoll(
        captureResult: AgentCLIPollResult?,
        activityResults: [AgentCLIPollResult]
    ) {
        isAgentCLICapturePollInFlight = false

        if let captureResult {
            let request = captureResult.request
            let threadID = request.thread.id
            if captureReadOffsetsByThreadID[threadID] ?? 0 == request.offset,
                agentCLIPollGeneration(for: threadID) == request.generation
            {
                applyAgentCLICaptureResult(threadID: threadID, captured: captureResult.captured)
            }
        }

        for result in activityResults {
            let request = result.request
            let threadID = request.thread.id
            guard activityReadOffsetsByThreadID[threadID] ?? 0 == request.offset,
                agentCLIPollGeneration(for: threadID) == request.generation
            else { continue }
            applyAgentCLIActivityResult(threadID: threadID, captured: result.captured)
        }
    }

    private func finishAgentCLISessionSyncPoll(_ result: AgentCLISessionSyncResult) {
        isAgentCLISessionSyncInFlight = false
        applySessionSyncResult(result)
    }

    public func syncSelectedThreadSessionMetadata() {
        guard let request = selectedThreadSessionSyncRequest() else { return }
        let result: AgentCLISessionSyncResult
        switch request {
        case .exactLink(let thread):
            result = .exactLink(
                threadID: thread.id,
                candidate: agentCLIBindings.exactSessionLinkCandidate(for: thread)
            )
        case .catalogMetadata(let thread):
            result = .catalogMetadata(
                threadID: thread.id,
                metadata: agentCLIBindings.catalogMetadata(for: thread)
            )
        }
        applySessionSyncResult(result)
    }

    private func agentCLIPollGeneration(for threadID: UUID) -> Int {
        agentCLIPollGenerationByThreadID[threadID] ?? 0
    }

    private func bumpAgentCLIPollGeneration(for threadID: UUID) {
        agentCLIPollGenerationByThreadID[threadID, default: 0] += 1
    }

    private func selectedThreadSessionSyncRequest() -> AgentCLISessionSyncRequest? {
        guard let selectedThreadID,
            let index = threadIndexByID[selectedThreadID]
        else { return nil }
        let thread = threads[index]
        if thread.sessionIdentity == nil,
            !sessionLinkSkippedThreadIDs.contains(selectedThreadID)
        {
            return .exactLink(thread: thread)
        }
        guard !sessionLinkRequiredThreadIDs.contains(selectedThreadID),
            thread.sessionIdentity != nil
        else { return nil }
        return .catalogMetadata(thread: thread)
    }

    private func applySessionSyncResult(_ result: AgentCLISessionSyncResult) {
        switch result {
        case .exactLink(let threadID, let candidate):
            guard selectedThreadID == threadID,
                let index = threadIndexByID[threadID],
                threads[index].sessionIdentity == nil,
                !sessionLinkSkippedThreadIDs.contains(threadID),
                let candidate
            else { return }
            applySessionLink(candidate, toThreadAt: index, preserveRunningTerminal: true)
            recordDiagnostic(
                category: "AgentCLI",
                name: "session_auto_linked_during_sync",
                metadata: [
                    "thread_id": threadID.uuidString,
                    "agent_cli": candidate.agentCLI.rawValue,
                    "source": candidate.source,
                ]
            )
        case .catalogMetadata(let threadID, let metadata):
            guard selectedThreadID == threadID,
                !sessionLinkRequiredThreadIDs.contains(threadID),
                let index = threadIndexByID[threadID],
                let metadata,
                // The catalog was looked up by the thread's identity at snapshot time; if it no
                // longer matches, the thread was re-linked/renamed during the poll window and this
                // result is stale, so applying it would clobber the newer identity.
                threads[index].sessionIdentity == metadata.identity
            else { return }
            applyAgentCLIMetadata(metadata, toThreadAt: index)
        }
    }

    private func threadIDsForAgentCLIActivityPolling() -> [UUID] {
        var seen = Set<UUID>()
        var threadIDs: [UUID] = []

        func append(_ threadID: UUID?) {
            guard let threadID, seen.insert(threadID).inserted else { return }
            threadIDs.append(threadID)
        }

        append(selectedThreadID)
        append(focusedProjectTerminalThreadID)
        for threadID in activeProjectLaunchDescriptorsByThreadID.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            append(threadID)
        }
        return threadIDs
    }

    private func completeActivityLogOutput(threadID: UUID, output: String) -> String {
        let combinedOutput = (activityPartialLinesByThreadID[threadID] ?? "") + output
        guard let lastNewlineIndex = combinedOutput.lastIndex(where: \.isNewline) else {
            activityPartialLinesByThreadID[threadID] = combinedOutput
            return ""
        }

        let completeOutput = String(combinedOutput[...lastNewlineIndex])
        let tailStart = combinedOutput.index(after: lastNewlineIndex)
        let tail = String(combinedOutput[tailStart...])
        if tail.isEmpty {
            activityPartialLinesByThreadID.removeValue(forKey: threadID)
        } else {
            activityPartialLinesByThreadID[threadID] = tail
        }
        return completeOutput
    }

    private func setBrowserUnavailableMessage(_ message: String, threadID: UUID) {
        browserUnavailableMessagesByThreadID[threadID] = message
    }

    private static func normalizedBrowserURLString(_ urlString: String?) -> String? {
        guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
            !urlString.isEmpty
        else {
            return nil
        }
        if urlString.contains("://") || urlString.hasPrefix("file:") {
            return urlString
        }
        if urlString.hasPrefix("localhost") || urlString.hasPrefix("127.0.0.1")
            || urlString.hasPrefix("[::1]")
        {
            return "http://\(urlString)"
        }
        return "https://\(urlString)"
    }

    public func refreshSelectedFileBrowser() {
        guard let thread = selectedThread else {
            fileBrowserState = FileBrowserState()
            selectedFileRelativePath = nil
            return
        }
        refreshFileBrowser(for: thread)
    }

    public func updateFileSearchQuery(_ query: String) {
        let startedAt = Date()
        let fullEntries =
            selectedThreadID.flatMap { fileBrowserEntriesByThreadID[$0] }
            ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: FuzzyFileMatcher.Result
        if trimmed.isEmpty {
            result = FuzzyFileMatcher.Result(
                entries: fileBrowserState.entries,
                totalMatches: fullEntries.count,
                isLimitApplied: fileBrowserState.isBrowseEntryLimitApplied
            )
        } else {
            result = FuzzyFileMatcher.rankedResult(
                fullEntries,
                query: query,
                limit: Self.fileBrowserVisibleLimit(for: query)
            )
        }
        fileBrowserState.searchQuery = query
        fileBrowserState.visibleEntries = result.entries
        fileBrowserState.isVisibleEntryLimitApplied = result.isLimitApplied
        updateSelectedFileAfterVisibleEntriesChanged()
        recordSearchDiagnosticIfNeeded(
            query: query,
            sourceCount: fullEntries.count,
            matchCount: result.totalMatches,
            visibleCount: result.entries.count,
            durationMS: Self.elapsedMilliseconds(since: startedAt)
        )
    }

    /// The set of expanded folders remembered for the given thread (in-session only).
    public func expandedFolders(forThreadID id: UUID) -> Set<String> {
        expandedFoldersByThreadID[id] ?? []
    }

    public func setExpandedFolders(_ folders: Set<String>, forThreadID id: UUID) {
        expandedFoldersByThreadID[id] = folders
        // Watch the newly expanded directories so files created inside a folder you've
        // opened surface automatically.
        if id == selectedThreadID, let thread = selectedThread,
            isExistingDirectory(thread.workingDirectory)
        {
            updateFileBrowserDirectoryWatch(for: thread)
        }
    }

    /// Watches the working directory plus the currently-expanded directories. A new file is
    /// only visible when its parent is the root or is expanded, so this is exactly the set
    /// where a new entry should appear; the debounced callback triggers a refresh.
    private func updateFileBrowserDirectoryWatch(for thread: AgentThread) {
        var directories: Set<String> = [thread.workingDirectory.standardizedFileURL.path]
        for relativePath in expandedFoldersByThreadID[thread.id] ?? [] {
            let url = thread.workingDirectory.appendingPathComponent(relativePath)
                .standardizedFileURL
            if isExistingDirectory(url) {
                directories.insert(url.path)
            }
        }
        fileIndexDirectoryWatcher.watch(directories: directories) { [weak self] in
            self?.refreshSelectedFileBrowser()
        }
    }

    /// Sets the published selection and records it as the selected thread's remembered file
    /// so it can be restored after a thread/tab switch within the session.
    private func setSelectedFile(_ relativePath: String?) {
        selectedFileRelativePath = relativePath
        if let selectedThreadID {
            selectedFileByThreadID[selectedThreadID] = relativePath
        }
    }

    public func selectFile(relativePath: String?) {
        guard let relativePath else {
            setSelectedFile(nil)
            return
        }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        let fullEntries =
            selectedThreadID.flatMap { fileBrowserEntriesByThreadID[$0] }
            ?? []
        guard fullEntries.contains(where: { $0.relativePath == normalizedPath }) else { return }
        setSelectedFile(normalizedPath)
    }

    public func recordFileBrowserTreeBuilt(entryCount: Int, rowCount: Int, durationMS: Int) {
        guard
            entryCount >= FileBrowserPresentationLimits.largeIndexDiagnosticThreshold
                || durationMS >= FileBrowserPresentationLimits.slowTreeBuildDiagnosticThresholdMS
        else { return }
        recordDiagnostic(
            category: "Indexing",
            name: "file_browser_tree_built",
            metadata: [
                "entry_count": "\(entryCount)",
                "visible_row_count": "\(rowCount)",
                "duration_ms": "\(durationMS)",
                "limited":
                    "\(rowCount >= FileBrowserPresentationLimits.treeRowDiagnosticThreshold)",
            ]
        )
    }

    public func selectAdjacentFile(direction: ProjectMoveDirection) {
        let entries = fileBrowserState.visibleEntries.filter { !$0.isDirectory }
        guard !entries.isEmpty else {
            selectedFileRelativePath = nil
            return
        }
        let currentIndex =
            selectedFileRelativePath.flatMap { selectedPath in
                entries.firstIndex { $0.relativePath == selectedPath }
            } ?? -1
        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(0, currentIndex - 1)
        case .down:
            nextIndex = min(entries.count - 1, currentIndex + 1)
        }
        setSelectedFile(entries[nextIndex].relativePath)
    }

    public func openSelectedFileInNvim() {
        guard let selectedFileRelativePath else { return }
        openFileInNvim(relativePath: selectedFileRelativePath)
    }

    public func openFileInNvim(relativePath: String) {
        guard let selectedThreadID else { return }
        guard let resolvedFile = selectedThreadFileURL(relativePath: relativePath) else { return }
        let normalizedPath = resolvedFile.normalizedPath
        setSelectedFile(normalizedPath)
        var state = selectedRightPanelState
        let existingTabID = RightPanelTab.nvimTabID(relativePath: normalizedPath)
        let alreadyOpen = state.tabs.contains { $0.id == existingTabID }
        let tab = state.openNvimTab(relativePath: normalizedPath)
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .nvim
        if !alreadyOpen {
            nvimRelaunchTokensByTabKey[nvimTabKey(threadID: selectedThreadID, tabID: tab.id)] =
                UUID()
            terminateTerminal(role: .nvimTab(threadID: selectedThreadID, tabID: tab.id))
        }
        nvimRelativePathsByThreadID[selectedThreadID] = normalizedPath
        nvimRelaunchTokensByThreadID[selectedThreadID] = UUID()
        persistRightPanelMode(threadID: selectedThreadID)
        persistRightPanelState(threadID: selectedThreadID)
    }

    public func openFileFromBrowserPrimary(relativePath: String) {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        guard
            configuration.fileBrowser.markdownAndHTMLDefault == .browserPreview,
            Self.isMarkdownOrHTML(relativePath: normalizedPath),
            openFileInBrowser(relativePath: normalizedPath)
        else {
            openFileInNvim(relativePath: relativePath)
            return
        }
    }

    public func openBrowserTab(urlString: String? = nil) {
        guard let selectedThreadID else { return }
        var state = selectedRightPanelState
        _ = state.openBrowserTab(urlString: Self.normalizedBrowserURLString(urlString))
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .browser
        browserUnavailableMessagesByThreadID.removeValue(forKey: selectedThreadID)
        persistRightPanelMode(threadID: selectedThreadID)
        persistRightPanelState(threadID: selectedThreadID)
    }

    public func updateSelectedBrowserTab(urlString: String) {
        guard let selectedThreadID else { return }
        var state = selectedRightPanelState
        guard state.selectedTab.kind == .browser else { return }
        state.updateBrowserTab(
            id: state.selectedTabID, urlString: Self.normalizedBrowserURLString(urlString))
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .browser
        browserUnavailableMessagesByThreadID.removeValue(forKey: selectedThreadID)
        persistRightPanelMode(threadID: selectedThreadID)
        persistRightPanelState(threadID: selectedThreadID)
    }

    @discardableResult
    public func openFileInBrowser(relativePath: String) -> Bool {
        guard let selectedThreadID, let thread = selectedThread else { return false }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            setBrowserUnavailableMessage(
                "Browser preview requires a file path.", threadID: selectedThreadID)
            return false
        }
        guard Self.isBrowserPreviewSupported(relativePath: normalizedPath) else {
            setBrowserUnavailableMessage(
                "Unsupported browser preview type: \(normalizedPath)", threadID: selectedThreadID)
            return false
        }
        guard !normalizedPath.split(separator: "/").contains("..") else {
            setBrowserUnavailableMessage(
                "Browser preview is limited to files under the selected thread.",
                threadID: selectedThreadID)
            return false
        }

        let root = thread.workingDirectory.standardizedFileURL
        let fileURL = root.appendingPathComponent(normalizedPath).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard fileURL.path.hasPrefix(rootPath) else {
            setBrowserUnavailableMessage(
                "Browser preview is limited to files under the selected thread.",
                threadID: selectedThreadID)
            return false
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            setBrowserUnavailableMessage(
                "Browser preview file does not exist: \(normalizedPath)", threadID: selectedThreadID
            )
            return false
        }

        setSelectedFile(normalizedPath)
        var state = selectedRightPanelState
        _ = state.openBrowserTab(urlString: fileURL.absoluteString, relativePath: normalizedPath)
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .browser
        browserUnavailableMessagesByThreadID.removeValue(forKey: selectedThreadID)
        persistRightPanelMode(threadID: selectedThreadID)
        persistRightPanelState(threadID: selectedThreadID)
        return true
    }

    public static func isBrowserPreviewSupported(relativePath: String) -> Bool {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        let supportedExtensions: Set<String> = [
            "html", "htm", "svg", "pdf", "png", "jpg", "jpeg", "gif", "webp", "txt", "json", "xml",
            "md", "markdown",
        ]
        return supportedExtensions.contains(
            URL(fileURLWithPath: normalizedPath).pathExtension.lowercased())
    }

    public static func isMarkdownOrHTML(relativePath: String) -> Bool {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        return ["md", "markdown", "html", "htm"].contains(
            URL(fileURLWithPath: normalizedPath).pathExtension.lowercased()
        )
    }

    @discardableResult
    public func createProject(
        displayName: String,
        rootDirectory: URL,
        now: Date = Date()
    ) throws -> UUID {
        guard isExistingDirectory(rootDirectory) else {
            throw AppModelError.missingProjectDirectory(rootDirectory.path)
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = rootDirectory.standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? directoryName : trimmedName
        guard !resolvedName.isEmpty else {
            throw AppModelError.emptyProjectName
        }

        let project = Project(
            displayName: resolvedName,
            rootDirectory: rootDirectory,
            createdAt: now,
            lastOpenedAt: now,
            sortOrder: nextProjectSortOrder(isPinned: false)
        )
        projects.append(project)
        projects = Self.sortedProjects(projects)
        selectedProjectID = project.id
        selectedThreadID = nil
        expandedProjectIDs.insert(project.id)
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Projects",
            name: "project_created",
            metadata: ["project_id": project.id.uuidString]
        )
        persistProject(project)
        persistProjectExpanded(projectID: project.id)
        persistSelection()
        return project.id
    }

    @discardableResult
    public func createThread(
        projectID: UUID? = nil,
        agentCLI: AgentCLIKind?,
        displayName: String? = nil,
        launchOptions: AgentLaunchOptions = AgentLaunchOptions(),
        workingDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> UUID {
        let agentCLI = agentCLI ?? configuration.defaultAgentCLI
        var candidateLaunchOptions =
            launchOptions.isEmpty ? configuredLaunchOptions(for: agentCLI) : launchOptions
        if candidateLaunchOptions.executableName == nil {
            candidateLaunchOptions.executableName = configuration.agentExecutableName(for: agentCLI)
        }
        let resolvedLaunchOptions = candidateLaunchOptions.validated(
            for: agentCLI,
            permissionModes: permissionModes(for: agentCLI)
        )
        let isImplicitProjectSelection = projectID == nil
        let resolvedProjectID = projectID ?? selectedProjectID
        guard let project = projects.first(where: { $0.id == resolvedProjectID }) else {
            throw AppModelError.selectedProjectMissing
        }
        if isImplicitProjectSelection, isGlobalProject(project) {
            throw AppModelError.projectRequiredForThreadCreation
        }
        if isGlobalProject(project) {
            ensureGlobalChatsDirectoryExists()
        }
        let resolvedWorkingDirectory =
            workingDirectory
            ?? (isGlobalProject(project) ? globalChatsDirectory : project.rootDirectory)
        guard isExistingDirectory(resolvedWorkingDirectory) else {
            throw AppModelError.missingProjectDirectory(resolvedWorkingDirectory.path)
        }

        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName =
            trimmedDisplayName?.isEmpty == false
            ? trimmedDisplayName ?? ""
            : "Starting \(agentCLI.displayName)..."
        let pendingSessionRename =
            trimmedDisplayName?.isEmpty == false
                && agentCLIBindings.canApplySessionNameOnLaunch(for: agentCLI)
            ? trimmedDisplayName
            : nil
        let thread = AgentThread(
            displayName: resolvedDisplayName,
            projectID: project.id,
            workingDirectory: resolvedWorkingDirectory,
            agentCLI: agentCLI,
            launchOptions: resolvedLaunchOptions,
            pendingSessionRename: pendingSessionRename,
            createdAt: now,
            lastOpenedAt: now
        )
        mutateThreads { $0.append(thread) }
        markProjectOpened(project.id, now: now)
        selectedThreadID = thread.id
        selectedProjectID = project.id
        expandedProjectIDs.insert(project.id)
        rightPanelModesByThreadID[thread.id] = .files
        rightPanelStatesByThreadID[thread.id] = RightPanelState.defaultState()
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Threads",
            name: "thread_created",
            metadata: [
                "thread_id": thread.id.uuidString,
                "agent_cli": thread.agentCLI.rawValue,
                "custom_launch_options": thread.launchOptions.isEmpty ? "false" : "true",
            ]
        )
        persistThread(thread)
        persistProject(projects.first { $0.id == project.id } ?? project)
        persistProjectExpanded(projectID: project.id)
        persistRightPanelMode(threadID: thread.id)
        persistRightPanelState(threadID: thread.id)
        persistSelection()
        _ = activateTerminal(role: .project(threadID: thread.id))
        return thread.id
    }

    public func changeAgentCLI(for threadID: UUID, to agentCLI: AgentCLIKind) throws {
        guard threadIndexByID[threadID] != nil else {
            throw AppModelError.threadNotFound
        }
        throw AppModelError.agentCLIChangeNotAllowed
    }

    public func toggleProjectPinned(id projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].isPinned.toggle()
        projects[index].sortOrder = nextProjectSortOrder(isPinned: projects[index].isPinned)
        normalizeProjectSortOrders()
        persistProject(projects.first { $0.id == projectID }!)
    }

    public func toggleSelectedProjectPinned() {
        toggleProjectPinned(id: selectedProjectID)
    }

    public func toggleThreadPinned(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThread(at: index) { $0.isPinned.toggle() }
        persistThread(threads[index])
    }

    public func toggleSelectedThreadPinned() {
        guard let selectedThreadID else { return }
        toggleThreadPinned(id: selectedThreadID)
    }

    public func canRequestThreadRename(id threadID: UUID) -> Bool {
        guard let thread = thread(withID: threadID) else { return false }
        return agentCLIBindings.supportsSessionRename(for: thread.agentCLI)
    }

    public func requestThreadRename(id threadID: UUID, to rawName: String) throws {
        guard let index = threadIndexByID[threadID] else {
            throw AppModelError.threadNotFound
        }
        guard agentCLIBindings.supportsSessionRename(for: threads[index].agentCLI) else {
            throw AppModelError.sessionRenameNotSupported
        }
        guard let name = Self.normalizedThreadName(rawName) else {
            throw AppModelError.emptyThreadName
        }
        let hadStoredIdentity = threads[index].sessionIdentity != nil
        let wasArchived = threads[index].isArchived
        mutateThread(at: index) {
            $0.pendingSessionRename = name
        }
        persistThread(threads[index])
        activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
        captureReadOffsetsByThreadID.removeValue(forKey: threadID)
        bumpAgentCLIPollGeneration(for: threadID)
        recordDiagnostic(
            category: "AgentCLI",
            name: "thread_rename_requested",
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": threads[index].agentCLI.rawValue,
            ]
        )

        guard selectedThreadID == threadID,
            !wasArchived,
            hadStoredIdentity,
            !sessionLinkRequiredThreadIDs.contains(threadID)
        else { return }
        terminalManager.terminate(role: .project(threadID: threadID))
        _ = activateTerminal(role: .project(threadID: threadID))
    }

    public func sessionLinkCandidates(for threadID: UUID) -> [SessionLinkCandidate] {
        guard let thread = thread(withID: threadID) else { return [] }
        return agentCLIBindings.sessionLinkCandidates(for: thread)
    }

    public func linkSession(threadID: UUID, candidate: SessionLinkCandidate) {
        guard let index = threadIndexByID[threadID],
            threads[index].agentCLI == candidate.agentCLI
        else { return }
        applySessionLink(candidate, toThreadAt: index)
        recordDiagnostic(
            category: "AgentCLI",
            name: "session_linked",
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": candidate.agentCLI.rawValue,
                "source": candidate.source,
            ]
        )
    }

    public func startNewSessionForUnlinkedThread(threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThread(at: index) {
            $0.sessionIdentity = nil
            $0.canonicalSessionName = nil
        }
        sessionLinkRequiredThreadIDs.remove(threadID)
        sessionLinkSkippedThreadIDs.insert(threadID)
        activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
        captureReadOffsetsByThreadID.removeValue(forKey: threadID)
        bumpAgentCLIPollGeneration(for: threadID)
        persistThread(threads[index])
        recordDiagnostic(
            category: "AgentCLI",
            name: "session_link_skipped",
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": threads[index].agentCLI.rawValue,
            ]
        )
    }

    private func reconcileLoadedUnboundSessionLinks(requiresLinks: Bool) {
        guard requiresLinks else { return }
        let threadIDs = threads.filter { $0.sessionIdentity == nil }.map(\.id)
        for threadID in threadIDs {
            if autoLinkUnboundThreadIfExactMatch(
                threadID: threadID,
                diagnosticName: "session_auto_linked_on_load"
            ) {
                continue
            }
            sessionLinkRequiredThreadIDs.insert(threadID)
        }
    }

    @discardableResult
    private func autoLinkUnboundThreadIfExactMatch(
        threadID: UUID,
        diagnosticName: String
    ) -> Bool {
        guard let index = threadIndexByID[threadID],
            threads[index].sessionIdentity == nil,
            let candidate = agentCLIBindings.exactSessionLinkCandidate(for: threads[index])
        else { return false }
        applySessionLink(candidate, toThreadAt: index)
        recordDiagnostic(
            category: "AgentCLI",
            name: diagnosticName,
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": candidate.agentCLI.rawValue,
                "source": candidate.source,
            ]
        )
        return true
    }

    private func applySessionLink(
        _ candidate: SessionLinkCandidate,
        toThreadAt index: Int,
        preserveRunningTerminal: Bool = false
    ) {
        let threadID = threads[index].id
        mutateThread(at: index) {
            $0.sessionIdentity = candidate.identity
            $0.canonicalSessionName = candidate.displayName
            $0.displayName = candidate.displayName
            $0.pendingSessionRename = nil
        }
        sessionLinkRequiredThreadIDs.remove(threadID)
        sessionLinkSkippedThreadIDs.remove(threadID)
        // When the agent CLI registers its own session, polling auto-links it to
        // the running thread. Invalidating the cached launch descriptor here would
        // change the launch request from `--name` to `--resume`, tearing down and
        // relaunching the live process — which discards the user's in-flight first
        // message. Keep the running terminal's descriptor untouched; the identity is
        // still persisted, so a future cold launch resumes the bound session.
        let hasRunningTerminal = activeProjectLaunchDescriptorsByThreadID[threadID] != nil
        if !(preserveRunningTerminal && hasRunningTerminal) {
            activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
            captureReadOffsetsByThreadID.removeValue(forKey: threadID)
            bumpAgentCLIPollGeneration(for: threadID)
        }
        persistThread(threads[index])
    }

    public func moveProject(id projectID: UUID, direction: ProjectMoveDirection) {
        projects = Self.sortedProjects(projects)
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let candidateIndex: Int
        switch direction {
        case .up:
            candidateIndex = index - 1
        case .down:
            candidateIndex = index + 1
        }
        guard projects.indices.contains(candidateIndex),
            projects[index].isPinned == projects[candidateIndex].isPinned
        else {
            return
        }
        projects.swapAt(index, candidateIndex)
        normalizeProjectSortOrders(preservingCurrentOrder: true)
    }

    public func reorderProject(id projectID: UUID, before targetProjectID: UUID) {
        guard projectID != targetProjectID else { return }
        projects = Self.sortedProjects(projects)
        guard let sourceIndex = projects.firstIndex(where: { $0.id == projectID }),
            let targetIndex = projects.firstIndex(where: { $0.id == targetProjectID }),
            projects[sourceIndex].isPinned == projects[targetIndex].isPinned
        else {
            return
        }
        let project = projects.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        projects.insert(project, at: insertionIndex)
        normalizeProjectSortOrders(preservingCurrentOrder: true)
    }

    public func moveSelectedProject(direction: ProjectMoveDirection) {
        moveProject(id: selectedProjectID, direction: direction)
    }

    public func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if isExpanded {
            expandedProjectIDs.insert(projectID)
        } else {
            expandedProjectIDs.remove(projectID)
        }
        persistProjectExpanded(projectID: projectID)
    }

    public func toggleSelectedProjectExpanded() {
        setProjectExpanded(selectedProjectID, isExpanded: !isProjectExpanded(selectedProjectID))
    }

    public func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if isExpanded {
            expandedArchivedProjectIDs.insert(projectID)
        } else {
            expandedArchivedProjectIDs.remove(projectID)
        }
        persistProjectArchiveExpanded(projectID: projectID)
    }

    public func toggleSelectedProjectArchiveExpanded() {
        setProjectArchiveExpanded(
            selectedProjectID, isExpanded: !isProjectArchiveExpanded(selectedProjectID))
    }

    public func selectProject(id projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        guard selectedProjectID != projectID else { return }
        markProjectOpened(projectID)
        selectedProjectID = projectID
        selectedThreadID =
            isGlobalProject(project) ? nil : firstActiveThreadID(forProject: projectID)
        expandedProjectIDs.insert(projectID)
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Projects",
            name: "project_selected",
            metadata: ["project_id": projectID.uuidString]
        )
        persistSelectionChange(
            touchedProject: projects.first { $0.id == projectID },
            expandedProjectID: projectID
        )
    }

    public func selectThread(id threadID: UUID) {
        guard let thread = thread(withID: threadID) else { return }
        markProjectOpened(thread.projectID)
        markThreadOpened(threadID)
        selectedProjectID = thread.projectID
        selectedThreadID = thread.id
        expandedProjectIDs.insert(thread.projectID)
        resetFileBrowserForSelectedThread()
        refreshFileBrowser(for: thread, publishCachedSnapshot: false, forceReindex: false)
        pushCurrentSelection()
        recordDiagnostic(
            category: "Threads",
            name: "thread_selected",
            metadata: [
                "thread_id": thread.id.uuidString,
                "agent_cli": thread.agentCLI.rawValue,
            ]
        )
        persistSelectionChange(
            touchedProject: projects.first { $0.id == thread.projectID },
            touchedThread: threadIndexByID[threadID].map { threads[$0] },
            expandedProjectID: thread.projectID
        )
    }

    public func archiveThread(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        let projectID = threads[index].projectID
        mutateThread(at: index) { $0.isArchived = true }
        if selectedThreadID == threadID {
            selectedThreadID = firstActiveThreadID(forProject: projectID)
            resetFileBrowserForSelectedThread()
            if let selectedThread {
                refreshFileBrowser(for: selectedThread, publishCachedSnapshot: false)
            }
        }
        pushCurrentSelection()
        persistThread(threads[index])
        persistSelection()
    }

    public func archiveSelectedThread() {
        guard let selectedThreadID else { return }
        archiveThread(id: selectedThreadID)
    }

    public func unarchiveThread(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThread(at: index) {
            $0.isArchived = false
            $0.lastOpenedAt = Date()
        }
        selectThread(id: threadID)
    }

    public func unarchiveSelectedThread() {
        guard let selectedThreadID else { return }
        unarchiveThread(id: selectedThreadID)
    }

    /// Whether a project may be archived. The Global project is excluded.
    public func canArchiveProject(id projectID: UUID) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }) else { return false }
        return !isGlobalProject(project)
    }

    public func archiveProject(id projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        // The Global project is always present and cannot be archived.
        guard !isGlobalProject(projects[index]) else { return }
        projects[index].isArchived = true
        let archivedProject = projects[index]
        if selectedProjectID == projectID {
            let fallback =
                activeProjects.first { !isGlobalProject($0) }?.id
                ?? activeProjects.first?.id
            if let fallback {
                selectProject(id: fallback)
            }
        }
        persistProject(archivedProject)
    }

    public func archiveSelectedProject() {
        archiveProject(id: selectedProjectID)
    }

    public func unarchiveProject(id projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].isArchived = false
        projects[index].lastOpenedAt = Date()
        persistProject(projects[index])
        selectProject(id: projectID)
    }

    public func navigateBack() {
        guard let selection = navigationHistory.goBack() else { return }
        apply(selection)
        persistSelectionChange(expandedProjectID: selection.projectID)
    }

    public func navigateForward() {
        guard let selection = navigationHistory.goForward() else { return }
        apply(selection)
        persistSelectionChange(expandedProjectID: selection.projectID)
    }

    private func pushCurrentSelection() {
        navigationHistory.push(
            AppSelection(projectID: selectedProjectID, threadID: selectedThreadID))
    }

    private func apply(_ selection: AppSelection) {
        guard projects.contains(where: { $0.id == selection.projectID }) else { return }
        selectedProjectID = selection.projectID
        selectedThreadID = selection.threadID
        expandedProjectIDs.insert(selection.projectID)
        resetFileBrowserForSelectedThread()
        if let selectedThread {
            refreshFileBrowser(for: selectedThread, publishCachedSnapshot: false)
        }
    }

    private func activeThread(id threadID: UUID) -> AgentThread? {
        guard let index = threadIndexByID[threadID], !threads[index].isArchived else { return nil }
        return threads[index]
    }

    private func applyAgentCLIMetadata(_ metadata: AgentCLISessionMetadata, toThreadAt index: Int) {
        let threadID = threads[index].id
        let pendingRename = threads[index].pendingSessionRename
        let canonicalName = metadata.canonicalName
        let isPendingRenameConfirmed =
            pendingRename.map { $0 == canonicalName } ?? true
        // A `reportedName` comes from the session catalog and is authoritative. Metadata
        // whose name comes only from the terminal title is transient — for CLIs like Claude
        // the title is tool activity ("Bash", "Read"), so it must never name the thread, and
        // for any CLI it must never overwrite an already-established name.
        let nameIsAuthoritative = metadata.reportedName != nil
        let established = threads[index].canonicalSessionName
        let hasEstablishedName = established != nil && established != metadata.identity
        let canApplyTitleName = agentCLIBindings.usesTerminalTitleAsSessionName(
            for: threads[index].agentCLI)
        let mayApplyName =
            nameIsAuthoritative ? true : (hasEstablishedName ? false : canApplyTitleName)
        var updatedThread = threads[index]
        updatedThread.sessionIdentity = metadata.identity
        if isPendingRenameConfirmed && mayApplyName {
            updatedThread.canonicalSessionName = canonicalName
            updatedThread.displayName = canonicalName
            updatedThread.pendingSessionRename = nil
        }
        let threadChanged = updatedThread != threads[index]
        let linkStateChanged =
            sessionLinkRequiredThreadIDs.contains(threadID)
            || sessionLinkSkippedThreadIDs.contains(threadID)
            || pendingTerminalTitlesByThreadID[threadID] != nil
        guard threadChanged || linkStateChanged else { return }
        if threadChanged {
            mutateThread(at: index) {
                $0 = updatedThread
            }
        }
        sessionLinkRequiredThreadIDs.remove(threadID)
        sessionLinkSkippedThreadIDs.remove(threadID)
        pendingTerminalTitlesByThreadID.removeValue(forKey: threadID)
        if threadChanged {
            persistThread(threads[index])
        }
    }

    /// Lazily indexes a pruned (ignore-matched) directory's contents when the user
    /// expands it, then merges the results into the published index so the folder
    /// fills in and its files become searchable. No-op for ordinary directories.
    public func expandPrunedDirectory(relativePath: String) {
        guard let thread = selectedThread else { return }
        let threadID = thread.id
        guard let entries = fileBrowserEntriesByThreadID[threadID],
            let entry = entries.first(where: { $0.relativePath == relativePath }),
            entry.isDirectory, entry.isPruned
        else { return }
        guard !(pendingSubtreeLoadsByThreadID[threadID]?.contains(relativePath) ?? false) else {
            return
        }
        guard isExistingDirectory(thread.workingDirectory) else { return }

        pendingSubtreeLoadsByThreadID[threadID, default: []].insert(relativePath)
        // Show the indexing spinner while the subtree loads; cleared once the last
        // pending expand for this thread finishes (see finishSubtreeExpansion).
        if selectedThreadID == threadID {
            fileBrowserState.isIndexing = true
        }
        let requestID = latestFileBrowserRequestIDByThreadID[threadID]
        let cacheKey = fileIndexCacheCoordinator.cacheKey(
            root: thread.workingDirectory,
            ignoreRules: configuration.ignoreRules
        )
        fileIndexCacheCoordinator.refreshSubtree(
            threadID: threadID,
            root: thread.workingDirectory,
            relativeSubpath: relativePath,
            ignoreRules: configuration.ignoreRules,
            key: cacheKey
        ) { [weak self] result in
            self?.finishSubtreeExpansion(
                threadID: threadID,
                relativePath: relativePath,
                requestID: requestID,
                result: result
            )
        }
    }

    /// After a full reindex re-prunes ignore-listed directories, re-load the ones the user
    /// had expanded so they keep their contents and surface any newly created files. The
    /// indexSubtree walk is recursive, so re-loading a top-level pruned directory (e.g.
    /// `worktrees`) also refills any nested expansions beneath it.
    private func reloadExpandedPrunedSubtrees(threadID: UUID) {
        guard selectedThreadID == threadID,
            let entries = fileBrowserEntriesByThreadID[threadID]
        else { return }
        let expanded = expandedFoldersByThreadID[threadID] ?? []
        guard !expanded.isEmpty else { return }
        for entry in entries
        where entry.isDirectory && entry.isPruned && expanded.contains(entry.relativePath) {
            expandPrunedDirectory(relativePath: entry.relativePath)
        }
    }

    private func finishSubtreeExpansion(
        threadID: UUID,
        relativePath: String,
        requestID: UUID?,
        result: Result<FileIndexResult, Error>
    ) {
        pendingSubtreeLoadsByThreadID[threadID]?.remove(relativePath)
        // Keep the spinner up while other expands for this thread are still in flight.
        let stillIndexing = !(pendingSubtreeLoadsByThreadID[threadID]?.isEmpty ?? true)
        // A full reindex or thread switch since the expand bumps the request ID;
        // discard stale subtree results so we never merge into a replaced index.
        guard latestFileBrowserRequestIDByThreadID[threadID] == requestID else {
            clearSubtreeIndexingIndicatorIfIdle(threadID: threadID)
            return
        }
        guard case .success(let subtreeResult) = result,
            let existingEntries = fileBrowserEntriesByThreadID[threadID]
        else {
            clearSubtreeIndexingIndicatorIfIdle(threadID: threadID)
            return
        }

        let mergedEntries = FileBrowserTreeBuilder.merging(
            existingEntries, withSubtree: subtreeResult.entries,
            replacingPrunedPath: relativePath)
        fileBrowserEntriesByThreadID[threadID] = mergedEntries
        fileBrowserPresentationByThreadID.removeValue(forKey: threadID)

        var metadata = fileIndexMetadataByThreadID[threadID]
        if var metadata {
            metadata.fileCount = mergedEntries.count
            metadata.ignoredDirectoryCount =
                mergedEntries.filter { $0.isPruned }.count
            fileIndexMetadataByThreadID[threadID] = metadata
        }
        metadata = fileIndexMetadataByThreadID[threadID]

        guard selectedThreadID == threadID, let index = threadIndexByID[threadID] else { return }
        publishFileBrowserState(
            for: threads[index],
            entries: mergedEntries,
            metadata: metadata,
            cacheKeyValue: metadata?.cacheKey,
            searchQuery: fileBrowserState.searchQuery,
            isIndexing: stillIndexing,
            allowCachedPresentation: false
        )
    }

    /// Clears the file-browser spinner on a subtree-expand exit path that doesn't publish
    /// fresh state, but only once no expands remain in flight for the selected thread.
    private func clearSubtreeIndexingIndicatorIfIdle(threadID: UUID) {
        guard selectedThreadID == threadID else { return }
        if pendingSubtreeLoadsByThreadID[threadID]?.isEmpty ?? true {
            fileBrowserState.isIndexing = false
        }
    }

    private func refreshFileBrowser(
        for thread: AgentThread,
        publishCachedSnapshot: Bool = true,
        forceReindex: Bool = true
    ) {
        let requestID = UUID()
        latestFileBrowserRequestIDByThreadID[thread.id] = requestID
        guard isExistingDirectory(thread.workingDirectory) else {
            fileIndexDirectoryWatcher.stop()
            selectedFileRelativePath = nil
            fileBrowserState = FileBrowserState(
                rootPath: thread.workingDirectory.path,
                searchQuery: fileBrowserState.searchQuery,
                metadata: fileIndexMetadataByThreadID[thread.id],
                errorMessage: "Missing working directory: \(thread.workingDirectory.path)"
            )
            recordDiagnostic(
                category: "Indexing",
                name: "file_index_failed",
                metadata: [
                    "thread_id": thread.id.uuidString,
                    "reason": "missing_root",
                ]
            )
            return
        }
        updateFileBrowserDirectoryWatch(for: thread)
        let cacheKey = fileIndexCacheCoordinator.cacheKey(
            root: thread.workingDirectory,
            ignoreRules: configuration.ignoreRules
        )
        // Re-opening a thread that already has a fresh cached (and possibly subtree-merged)
        // index reuses it instead of forcing a full re-enumeration, so re-opens — and
        // re-expanding lazily-loaded subtrees like worktrees — are instant. The directory
        // watcher, git-identity cache key, and the Refresh button still trigger real
        // reindexes when something actually changed. resetFileBrowserForSelectedThread has
        // already published the cached entries before this call.
        if !forceReindex,
            fileIndexCacheCoordinator.cachedIndex(threadID: thread.id, key: cacheKey) != nil
        {
            return
        }
        if publishCachedSnapshot {
            let cachedResult = fileIndexCacheCoordinator.cachedIndex(
                threadID: thread.id, key: cacheKey)
            let entries = cachedResult?.entries ?? fileBrowserEntriesByThreadID[thread.id] ?? []
            publishFileBrowserState(
                for: thread,
                entries: entries,
                metadata: cachedResult?.metadata ?? fileIndexMetadataByThreadID[thread.id],
                cacheKeyValue: cacheKey.value,
                searchQuery: fileBrowserState.searchQuery,
                isIndexing: true,
                allowCachedPresentation: true
            )
        } else if selectedThreadID == thread.id {
            fileBrowserState.isIndexing = true
            fileBrowserState.errorMessage = nil
        }
        fileIndexCacheCoordinator.refreshIndex(
            threadID: thread.id,
            root: thread.workingDirectory,
            ignoreRules: configuration.ignoreRules,
            key: cacheKey
        ) { [weak self] result in
            self?.finishFileBrowserRefresh(
                threadID: thread.id, requestID: requestID, result: result)
        }
    }

    private func finishFileBrowserRefresh(
        threadID: UUID,
        requestID: UUID,
        result: Result<FileIndexResult, Error>
    ) {
        guard latestFileBrowserRequestIDByThreadID[threadID] == requestID else { return }
        // A fresh full index re-collapses pruned directories. Any in-flight lazy-expand for
        // this thread is superseded; we re-load currently-expanded pruned subtrees below so
        // they keep their contents (and pick up new files).
        pendingSubtreeLoadsByThreadID.removeValue(forKey: threadID)
        switch result {
        case .success(let result):
            fileIndexMetadataByThreadID[threadID] = result.metadata
            if selectedThreadID == threadID {
                guard let index = threadIndexByID[threadID] else { return }
                publishFileBrowserState(
                    for: threads[index],
                    entries: result.entries,
                    metadata: result.metadata,
                    cacheKeyValue: result.metadata.cacheKey,
                    searchQuery: fileBrowserState.searchQuery,
                    isIndexing: false,
                    allowCachedPresentation: false
                )
                reloadExpandedPrunedSubtrees(threadID: threadID)
            } else {
                fileBrowserEntriesByThreadID[threadID] = result.entries
                fileBrowserPresentationByThreadID.removeValue(forKey: threadID)
            }
            recordIndexDiagnosticIfNeeded(result: result)
            persistFileIndexMetadata(result.metadata)
        case .failure(let error):
            if selectedThreadID == threadID {
                fileBrowserState.isIndexing = false
                fileBrowserState.errorMessage = String(describing: error)
            }
            recordDiagnostic(
                category: "Indexing",
                name: "file_index_failed",
                metadata: [
                    "thread_id": threadID.uuidString,
                    "error": sanitizedDiagnosticValue(String(describing: error)),
                ]
            )
        }
    }

    private func resetFileBrowserForSelectedThread() {
        guard let selectedThread else {
            fileIndexDirectoryWatcher.stop()
            fileBrowserState = FileBrowserState()
            selectedFileRelativePath = nil
            return
        }
        // Restore the thread's remembered selection before publishing so the index load
        // doesn't auto-select the first file over a file the user previously opened.
        selectedFileRelativePath = selectedFileByThreadID[selectedThread.id]
        let entries: [FileBrowserEntry]
        let metadata: FileIndexMetadata?
        let presentationCacheKeyValue: String?
        if let rememberedEntries = fileBrowserEntriesByThreadID[selectedThread.id] {
            entries = rememberedEntries
            metadata = fileIndexMetadataByThreadID[selectedThread.id]
            presentationCacheKeyValue = metadata?.cacheKey
        } else if isExistingDirectory(selectedThread.workingDirectory) {
            let resolvedCacheKey = fileIndexCacheCoordinator.cacheKey(
                root: selectedThread.workingDirectory,
                ignoreRules: configuration.ignoreRules
            )
            if let cachedResult = fileIndexCacheCoordinator.cachedIndex(
                threadID: selectedThread.id,
                key: resolvedCacheKey
            ) {
                entries = cachedResult.entries
                metadata = cachedResult.metadata
                presentationCacheKeyValue = cachedResult.metadata.cacheKey ?? resolvedCacheKey.value
            } else if let sharedSnapshot = sharedFileBrowserSnapshot(
                for: selectedThread,
                cacheKey: resolvedCacheKey
            ) {
                entries = sharedSnapshot.entries
                metadata = sharedSnapshot.metadata
                presentationCacheKeyValue = sharedSnapshot.metadata.cacheKey
            } else {
                entries = []
                metadata = nil
                presentationCacheKeyValue = resolvedCacheKey.value
            }
        } else {
            entries = []
            metadata = nil
            presentationCacheKeyValue = nil
        }
        publishFileBrowserState(
            for: selectedThread,
            entries: entries,
            metadata: metadata,
            cacheKeyValue: presentationCacheKeyValue,
            searchQuery: "",
            isIndexing: false,
            allowCachedPresentation: true
        )
    }

    private func sharedFileBrowserSnapshot(
        for thread: AgentThread,
        cacheKey: FileIndexCacheKey
    ) -> (entries: [FileBrowserEntry], metadata: FileIndexMetadata)? {
        let rootPath = thread.workingDirectory.standardizedFileURL.path
        for candidate in threads
        where candidate.id != thread.id
            && candidate.workingDirectory.standardizedFileURL.path == rootPath
        {
            guard let entries = fileBrowserEntriesByThreadID[candidate.id],
                let metadata = fileIndexMetadataByThreadID[candidate.id],
                metadata.cacheKey == cacheKey.value
            else {
                continue
            }
            return (entries, metadata.forThread(thread.id))
        }
        return nil
    }

    private func publishFileBrowserState(
        for thread: AgentThread,
        entries: [FileBrowserEntry],
        metadata: FileIndexMetadata?,
        cacheKeyValue: String?,
        searchQuery: String,
        isIndexing: Bool,
        allowCachedPresentation: Bool
    ) {
        fileBrowserEntriesByThreadID[thread.id] = entries
        if let metadata {
            fileIndexMetadataByThreadID[thread.id] = metadata
        }
        let browseResult = browseFileEntries(
            for: thread.id,
            entries: entries,
            cacheKeyValue: cacheKeyValue,
            allowCached: allowCachedPresentation
        )
        let visibleResult = Self.visibleFileEntries(
            browseEntries: browseResult.entries,
            originalEntries: entries,
            browseLimitApplied: browseResult.isLimitApplied,
            query: searchQuery,
            limit: Self.fileBrowserVisibleLimit(for: searchQuery)
        )
        fileBrowserState = FileBrowserState(
            rootPath: thread.workingDirectory.path,
            searchQuery: searchQuery,
            indexedEntryCount: entries.count,
            entries: browseResult.entries,
            visibleEntries: visibleResult.entries,
            isBrowseEntryLimitApplied: browseResult.isLimitApplied,
            isVisibleEntryLimitApplied: visibleResult.isLimitApplied,
            isIndexing: isIndexing,
            metadata: metadata,
            errorMessage: nil
        )
        updateSelectedFileAfterVisibleEntriesChanged()
    }

    private func browseFileEntries(
        for threadID: UUID,
        entries: [FileBrowserEntry],
        cacheKeyValue: String?,
        allowCached: Bool
    ) -> (entries: [FileBrowserEntry], isLimitApplied: Bool) {
        let presentationCacheKey = cacheKeyValue ?? "thread:\(threadID.uuidString)"
        if allowCached,
            let cached = fileBrowserPresentationByThreadID[threadID],
            cached.cacheKey == presentationCacheKey,
            cached.sourceEntryCount == entries.count
        {
            return (cached.entries, cached.entries.count < entries.count)
        }

        let browseEntries = Self.browseFileEntries(from: entries)
        fileBrowserPresentationByThreadID[threadID] = FileBrowserPresentationCacheEntry(
            cacheKey: presentationCacheKey,
            sourceEntryCount: entries.count,
            entries: browseEntries
        )
        return (browseEntries, browseEntries.count < entries.count)
    }

    private func updateSelectedFileAfterVisibleEntriesChanged() {
        let fileEntries = fileBrowserState.visibleEntries.filter { !$0.isDirectory }
        guard !fileEntries.isEmpty else {
            // Clear the published value but keep the per-thread memory so a later index
            // load (e.g. an expanded subtree) can restore the remembered selection.
            selectedFileRelativePath = nil
            return
        }
        if let selectedFileRelativePath,
            fileEntries.contains(where: { $0.relativePath == selectedFileRelativePath })
        {
            return
        }
        // Honor a remembered selection for this thread rather than jumping to the first
        // file, even when it isn't visible yet (e.g. it lives inside an unexpanded subtree).
        if let selectedThreadID, let remembered = selectedFileByThreadID[selectedThreadID] {
            selectedFileRelativePath = remembered
            return
        }
        setSelectedFile(fileEntries.first?.relativePath)
    }

    private static func publishedTreeEntries(from entries: [FileBrowserEntry]) -> [FileBrowserEntry]
    {
        entries.sorted(by: FileBrowserTreeBuilder.sortEntriesForTree)
    }

    private static func browseFileEntries(from entries: [FileBrowserEntry]) -> [FileBrowserEntry] {
        // Publish the full index for browsing. The tree view renders lazily —
        // it only materializes rows for paths whose ancestors are expanded and
        // caps rendered rows defensively — so there is no need to drop entries
        // up front. A presentation cap here used to silently omit deep files
        // (e.g. docs/**/*.md in a large monorepo) that were never selected into
        // the bounded set, leaving expanded folders looking empty.
        publishedTreeEntries(from: entries)
    }

    private static func fileBrowserVisibleLimit(for query: String) -> Int {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? FileBrowserPresentationLimits.maxBrowseEntries
            : FileBrowserPresentationLimits.maxSearchResults
    }

    private static func visibleFileEntries(
        browseEntries: [FileBrowserEntry],
        originalEntries: [FileBrowserEntry],
        browseLimitApplied: Bool,
        query: String,
        limit: Int
    ) -> FuzzyFileMatcher.Result {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FuzzyFileMatcher.Result(
                entries: browseEntries,
                totalMatches: originalEntries.count,
                isLimitApplied: browseLimitApplied
            )
        }
        return FuzzyFileMatcher.rankedResult(originalEntries, query: query, limit: limit)
    }

    private func recordSearchDiagnosticIfNeeded(
        query: String,
        sourceCount: Int,
        matchCount: Int,
        visibleCount: Int,
        durationMS: Int
    ) {
        guard
            sourceCount >= FileBrowserPresentationLimits.largeIndexDiagnosticThreshold
                || durationMS >= FileBrowserPresentationLimits.slowSearchDiagnosticThresholdMS
        else { return }
        recordDiagnostic(
            category: "Indexing",
            name: "file_browser_search_completed",
            metadata: [
                "query_length": "\(query.count)",
                "source_count": "\(sourceCount)",
                "match_count": "\(matchCount)",
                "visible_count": "\(visibleCount)",
                "duration_ms": "\(durationMS)",
                "limited": "\(visibleCount < matchCount)",
            ]
        )
    }

    private func recordIndexDiagnosticIfNeeded(result: FileIndexResult) {
        let durationMS = Self.elapsedMilliseconds(since: result.metadata.indexedAt)
        guard
            result.metadata.fileCount >= FileBrowserPresentationLimits.largeIndexDiagnosticThreshold
                || durationMS >= FileBrowserPresentationLimits.slowSearchDiagnosticThresholdMS
        else { return }
        recordDiagnostic(
            category: "Indexing",
            name: "file_index_completed",
            metadata: [
                "root": sanitizedDiagnosticValue(result.metadata.rootPath),
                "file_count": "\(result.metadata.fileCount)",
                "ignored_directory_count": "\(result.metadata.ignoredDirectoryCount)",
                "duration_ms": "\(durationMS)",
            ]
        )
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private func directoryState(for url: URL) -> ProjectDirectoryState {
        isExistingDirectory(url)
            ? .available(path: url.path)
            : .missing(path: url.path)
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func defaultShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    private func externalToolCommand(named executableName: String, arguments: [String] = [])
        -> [String]
    {
        [
            externalToolResolver.executablePath(named: executableName, environment: environment)
                ?? executableName
        ] + arguments
    }

    private func externalToolCommand(preferredNames: [String], arguments: [String] = []) -> [String]
    {
        for name in preferredNames {
            if let path = externalToolResolver.executablePath(named: name, environment: environment)
            {
                return [path] + arguments
            }
        }
        return [preferredNames[0]] + arguments
    }

    private func gitToolCommand() -> [String] {
        let gitTool = configuration.tools.git.preferred
        if let resolvedGitTool = externalToolResolver.executablePath(
            named: gitTool, environment: environment)
        {
            return [resolvedGitTool]
        }
        let fallback = configuration.tools.diff.fallback
        if isGitDiffFallback(fallback) {
            let gitExecutable = fallback.first ?? "git"
            let resolvedGit =
                externalToolResolver.executablePath(named: gitExecutable, environment: environment)
                ?? gitExecutable
            return [resolvedGit, "--no-pager", "diff"]
        }
        guard let executable = fallback.first else { return ["git", "--no-pager", "diff"] }
        let resolvedExecutable =
            externalToolResolver.executablePath(named: executable, environment: environment)
            ?? executable
        return [resolvedExecutable] + Array(fallback.dropFirst())
    }

    private func isGitDiffFallback(_ command: [String]) -> Bool {
        command.count == 2
            && URL(fileURLWithPath: command[0]).lastPathComponent == "git"
            && command[1] == "diff"
    }

    private func nextProjectSortOrder(isPinned: Bool) -> Int {
        (projects.filter { $0.isPinned == isPinned }.map(\.sortOrder).max() ?? -1) + 1
    }

    private func normalizeProjectSortOrders(preservingCurrentOrder: Bool = false) {
        if !preservingCurrentOrder {
            projects = Self.sortedProjects(projects)
        }
        var pinnedOrder = 0
        var unpinnedOrder = 0
        for index in projects.indices {
            if projects[index].isPinned {
                projects[index].sortOrder = pinnedOrder
                pinnedOrder += 1
            } else {
                projects[index].sortOrder = unpinnedOrder
                unpinnedOrder += 1
            }
            persistProject(projects[index])
        }
        projects = Self.sortedProjects(projects)
    }

    private func markProjectOpened(_ projectID: UUID, now: Date = Date()) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].lastOpenedAt = now
    }

    private func markThreadOpened(_ threadID: UUID, now: Date = Date()) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThread(at: index) { $0.lastOpenedAt = now }
    }

    private func persistSelection() {
        store.setSelectedProject(selectedProjectID)
        store.setSelectedThread(selectedThreadID)
    }

    private func persistSelectionChange(
        touchedProject: Project? = nil,
        touchedThread: AgentThread? = nil,
        expandedProjectID: UUID? = nil
    ) {
        store.persistSelectionChange(
            selectedProjectID: selectedProjectID,
            selectedThreadID: selectedThreadID,
            touchedProject: touchedProject,
            touchedThread: touchedThread,
            expandedProjectID: expandedProjectID
        )
    }

    private func persistLayout() {
        store.setLayoutState(layoutState)
    }

    private func persistRightPanelMode(threadID: UUID) {
        store.setRightPanelMode(
            threadID: threadID,
            mode: rightPanelModesByThreadID[threadID] ?? .files
        )
    }

    private func persistRightPanelState(threadID: UUID) {
        guard let state = rightPanelStatesByThreadID[threadID] else { return }
        store.setRightPanelState(threadID: threadID, state: state)
    }

    private func persistBottomTerminalExpanded(threadID: UUID) {
        store.setBottomTerminalExpanded(
            threadID: threadID,
            isExpanded: bottomTerminalExpandedThreadIDs.contains(threadID)
        )
    }

    private func persistThread(_ thread: AgentThread) {
        store.upsertThread(thread)
    }

    private func persistProject(_ project: Project) {
        store.upsertProject(project)
    }

    private func persistProjectExpanded(projectID: UUID) {
        store.setProjectExpanded(projectID, isExpanded: expandedProjectIDs.contains(projectID))
    }

    private func persistProjectArchiveExpanded(projectID: UUID) {
        store.setProjectArchiveExpanded(
            projectID,
            isExpanded: expandedArchivedProjectIDs.contains(projectID)
        )
    }

    private func persistFileIndexMetadata(_ metadata: FileIndexMetadata) {
        store.upsertFileIndexMetadata(metadata)
    }

    private func persistThreadActivity(_ activity: ThreadActivityState) {
        store.upsertThreadActivity(activity)
    }

    private func persistLaunchDowngradedThreadActivity(_ loaded: [UUID: ThreadActivityState]) {
        for (threadID, loadedActivity) in loaded {
            guard let downgraded = threadActivityByThreadID[threadID],
                downgraded != loadedActivity
            else { continue }
            persistThreadActivity(downgraded)
        }
    }

    private func applyThreadActivity(
        _ event: ThreadActivityEvent,
        isUnread: Bool,
        shouldNotify: Bool
    ) {
        guard let threadIndex = threadIndexByID[event.threadID] else { return }
        let currentActivity = threadActivity(for: event.threadID)
        let status =
            event.status
            ?? ThreadActivityText.inferredStatus(title: event.title, body: event.body)
            ?? currentActivity.status
        let preview = ThreadActivityText.preview(title: event.title, body: event.body)
        let suppressNotification = shouldSuppressSystemNotification(for: event.threadID)
        let activity = ThreadActivityState(
            threadID: event.threadID,
            status: status,
            preview: preview,
            isUnread: isUnread && !suppressNotification,
            title: event.title,
            body: event.body,
            source: event.source,
            updatedAt: event.createdAt
        )
        // Skip republishing/persisting when only the timestamp differs: identical content arriving
        // every poll (e.g. a continuously "working" thread) would otherwise churn @Published state
        // and SQLite on the typing/hot path. As a deliberate consequence, repeated identical activity
        // does not advance lastOpenedAt/updatedAt; this is not user-visible because ThreadIdleAgeLabel
        // only renders for .inactive threads, which are reached via a distinct "Terminal closed" event.
        if Self.hasSamePublishedActivity(activity, as: currentActivity) {
            return
        }
        threadActivityByThreadID[event.threadID] = activity
        persistThreadActivity(activity)
        if threads[threadIndex].lastOpenedAt < event.createdAt {
            mutateThread(at: threadIndex) { thread in
                thread.lastOpenedAt = event.createdAt
            }
            if let updatedThreadIndex = threadIndexByID[event.threadID] {
                persistThread(threads[updatedThreadIndex])
            }
        }
        updateDockBadge()
        recordDiagnostic(
            category: "Threads",
            name: "thread_activity_updated",
            metadata: [
                "thread_id": event.threadID.uuidString,
                "status": status.rawValue,
                "source": event.source.rawValue,
            ]
        )
        if shouldNotify, activity.isUnread, !suppressNotification {
            dispatchSystemNotification(for: activity)
        }
    }

    private func markThreadActivityRead(threadID: UUID) {
        guard var activity = threadActivityByThreadID[threadID], activity.isUnread else { return }
        activity.isUnread = false
        threadActivityByThreadID[threadID] = activity
        persistThreadActivity(activity)
        updateDockBadge()
    }

    // Equality of everything the UI publishes, ignoring updatedAt — built on the synthesized
    // Equatable so it can't silently drift when a field is added to ThreadActivityState.
    private static func hasSamePublishedActivity(
        _ lhs: ThreadActivityState,
        as rhs: ThreadActivityState
    ) -> Bool {
        var normalized = lhs
        normalized.updatedAt = rhs.updatedAt
        return normalized == rhs
    }

    private func shouldSuppressSystemNotification(for threadID: UUID) -> Bool {
        isApplicationActive()
            && selectedThreadID == threadID
            && focusedProjectTerminalThreadID == threadID
    }

    private func dispatchSystemNotification(for activity: ThreadActivityState) {
        guard let thread = thread(withID: activity.threadID),
            let project = projects.first(where: { $0.id == thread.projectID })
        else { return }
        notificationDispatcher.dispatch(
            ThreadActivityNotification(
                threadID: activity.threadID,
                title: thread.displayName,
                subtitle: "\(project.displayName) - \(activity.status.cliValue)",
                body: activity.preview ?? activity.body ?? activity.title
                    ?? activity.status.cliValue
            )
        )
    }

    private func updateDockBadge() {
        badgeUpdater.updateUnreadThreadActivityCount(unreadThreadActivityCount)
    }

    private func recordTerminalLaunchFailure(role: TerminalRole, path: String, reason: String) {
        recordDiagnostic(
            category: "Terminal",
            name: "terminal_launch_failed",
            metadata: [
                "role": role.diagnosticName,
                "surface": role.surfaceKind.rawValue,
                "reason": reason,
                "path": sanitizedDiagnosticValue(path),
            ]
        )
    }

    private func nvimTabKey(threadID: UUID, tabID: String) -> String {
        "\(threadID.uuidString)|\(tabID)"
    }

    private func recordDiagnostic(category: String, name: String, metadata: [String: String] = [:])
    {
        diagnosticRecorder.record(
            DiagnosticEvent(category: category, name: name, metadata: metadata))
    }

    private func sanitizedDiagnosticValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

extension TerminalRole {
    fileprivate var diagnosticName: String {
        switch self {
        case .project:
            return "project"
        case .bottom:
            return "bottom"
        case .nvim, .nvimTab:
            return "nvim"
        case .lazygit:
            return "lazygit"
        }
    }
}
