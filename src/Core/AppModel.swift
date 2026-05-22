import Combine
import Foundation

public enum AppModelError: Error, Equatable {
    case emptyProjectName
    case missingProjectDirectory(String)
    case selectedProjectMissing
    case missingAgentCLI
    case threadNotFound
    case agentCLIChangeNotAllowed
}

private enum FileBrowserPresentationLimits {
    static let maxPublishedEntries = 10_000
    static let maxSearchResults = 1_000
    static let largeIndexDiagnosticThreshold = 50_000
    static let slowSearchDiagnosticThresholdMS = 100
    static let slowTreeBuildDiagnosticThresholdMS = 50
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
    @Published public private(set) var expandedProjectIDs: Set<UUID>
    @Published public private(set) var expandedArchivedProjectIDs: Set<UUID>
    @Published public private(set) var threadActivityByThreadID: [UUID: ThreadActivityState]

    public let projectTerminal: TerminalSurfaceDescriptor
    public private(set) var navigationHistory: NavigationHistory
    private let store: YAAWStore
    private let terminalManager: TerminalSessionManaging
    private let agentCLIBindings: AgentCLISessionBindingService
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
    private var latestFileBrowserRequestIDByThreadID: [UUID: UUID] = [:]
    private var nvimRelativePathsByThreadID: [UUID: String] = [:]
    private var nvimRelaunchTokensByThreadID: [UUID: UUID] = [:]
    private var nvimRelaunchTokensByTabKey: [String: UUID] = [:]
    private var activeProjectLaunchCommandsByThreadID: [UUID: [String]] = [:]
    private var captureReadOffsetsByThreadID: [UUID: UInt64] = [:]
    private var activityReadOffsetsByThreadID: [UUID: UInt64] = [:]
    private var activityPartialLinesByThreadID: [UUID: String] = [:]
    private var pendingTerminalTitlesByThreadID: [UUID: String] = [:]
    private var focusedProjectTerminalThreadID: UUID?
    private var threadIndexByID: [UUID: Int] = [:]
    private var cachedActiveThreadsByProject: [UUID: [AgentThread]] = [:]
    private var cachedArchivedThreadsByProject: [UUID: [AgentThread]] = [:]

    public init(
        store: YAAWStore = InMemoryYAAWStore.helloWorld(),
        terminalManager: TerminalSessionManaging = PlaceholderTerminalSessionManager(),
        agentCLIBindings: AgentCLISessionBindingService = AgentCLISessionBindingService(),
        fileIndexer: FileIndexing = BackgroundFileIndexer(),
        externalToolResolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        configuration: YAAWConfiguration = YAAWConfiguration(),
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared,
        notificationDispatcher: any ThreadActivityNotificationDispatching =
            NoopThreadActivityNotificationDispatcher(),
        badgeUpdater: any ThreadActivityBadgeUpdating = NoopThreadActivityBadgeUpdater(),
        isApplicationActive: @escaping () -> Bool = { false },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.agentCLIBindings = agentCLIBindings
        self.fileIndexer = fileIndexer
        self.fileIndexCacheCoordinator = FileIndexCacheCoordinator(
            store: store, fileIndexer: fileIndexer)
        self.fileIndexDirectoryWatcher = FileIndexDirectoryWatcher()
        self.externalToolResolver = externalToolResolver
        self.diagnosticRecorder = diagnosticRecorder
        self.notificationDispatcher = notificationDispatcher
        self.badgeUpdater = badgeUpdater
        self.isApplicationActive = isApplicationActive
        self.configuration = configuration.validated(diagnosticRecorder: diagnosticRecorder)
        self.environment = environment
        self.homeDirectory = homeDirectory
        let snapshot = store.load()
        self.projects = Self.sortedProjects(snapshot.projects)
        self.threads = snapshot.threads
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
        let selectedProjectID =
            snapshot.projects.contains { $0.id == snapshot.selectedProjectID }
            ? snapshot.selectedProjectID
            : snapshot.projects[0].id
        let selectedThreadID =
            snapshot.threads.contains { $0.id == snapshot.selectedThreadID }
            ? snapshot.selectedThreadID
            : snapshot.threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
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
    }

    public var selectedThread: AgentThread? {
        guard let selectedThreadID, let index = threadIndexByID[selectedThreadID] else {
            return nil
        }
        return threads[index]
    }

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
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

    private static func sortedProjects(_ projects: [Project]) -> [Project] {
        projects.sorted { lhs, rhs in
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

    public var windowTitle: String {
        guard let project = selectedProject else { return "Agent IDE" }
        guard let thread = selectedThread else { return project.displayName }
        return "\(project.displayName) - \(thread.displayName)"
    }

    public var defaultAgentCLI: AgentCLIKind {
        configuration.defaultAgentCLI
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
        self.configuration = configuration.validated(diagnosticRecorder: diagnosticRecorder)
        activeProjectLaunchCommandsByThreadID.removeAll()
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
        layoutState.rightPanelWidth = LayoutState.clamp(
            width,
            minimum: LayoutState.minimumRightPanelWidth,
            maximum: LayoutState.maximumRightPanelWidth
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
            guard let thread = activeThread(id: threadID) else { return nil }
            guard isExistingDirectory(thread.workingDirectory) else {
                recordTerminalLaunchFailure(
                    role: role,
                    path: thread.workingDirectory.path,
                    reason: "missing_working_directory"
                )
                return nil
            }
            let command: [String]
            if let activeCommand = activeProjectLaunchCommandsByThreadID[threadID] {
                command = activeCommand
            } else {
                captureReadOffsetsByThreadID.removeValue(forKey: threadID)
                command = agentCLIBindings.terminalCommand(
                    for: thread,
                    executableNameOverride: configuration.agentExecutableName(for: thread.agentCLI)
                )
            }
            activeProjectLaunchCommandsByThreadID[threadID] = command
            return TerminalLaunchRequest(
                role: role,
                title: "\(thread.agentCLI.displayName) Terminal",
                workingDirectory: thread.workingDirectory,
                command: command,
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

    public func terminateTerminal(role: TerminalRole) {
        terminalManager.terminate(role: role)
        if case .project(let threadID) = role {
            activeProjectLaunchCommandsByThreadID.removeValue(forKey: threadID)
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
        guard let index = threadIndexByID[threadID],
            var metadata = agentCLIBindings.metadata(
                for: threads[index].agentCLI,
                output: output,
                terminalTitle: terminalTitle
            )
        else {
            return
        }
        if metadata.reportedName == nil,
            metadata.title == nil,
            let pendingTitle = pendingTerminalTitlesByThreadID[threadID]
        {
            metadata.title = pendingTitle
        }
        applyAgentCLIMetadata(metadata, toThreadAt: index)
    }

    public func recordAgentCLITerminalTitle(threadID: UUID, title: String) {
        guard let index = threadIndexByID[threadID] else {
            return
        }
        pendingTerminalTitlesByThreadID[threadID] = title
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

    public func recordAgentTerminalClosed(threadID: UUID) {
        activeProjectLaunchCommandsByThreadID.removeValue(forKey: threadID)
        captureReadOffsetsByThreadID.removeValue(forKey: threadID)
        activityReadOffsetsByThreadID.removeValue(forKey: threadID)
        activityPartialLinesByThreadID.removeValue(forKey: threadID)
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
        captureReadOffsetsByThreadID[thread.id] = captured.nextOffset
        recordAgentCLIOutput(threadID: thread.id, output: captured.output)
    }

    public func pollAgentCLIActivityLogs() {
        for threadID in threadIDsForAgentCLIActivityPolling() {
            guard let thread = activeThread(id: threadID) else { continue }
            let previousOffset = activityReadOffsetsByThreadID[thread.id] ?? 0
            guard
                let captured = agentCLIBindings.capturedActivityEvents(
                    for: thread,
                    after: previousOffset
                )
            else {
                continue
            }
            if captured.startOffset != previousOffset {
                activityPartialLinesByThreadID.removeValue(forKey: thread.id)
            }
            activityReadOffsetsByThreadID[thread.id] = captured.nextOffset
            let completeOutput = completeActivityLogOutput(
                threadID: thread.id, output: captured.output)
            for event in ThreadActivityEvent.helperEvents(from: completeOutput) {
                applyThreadActivity(
                    event,
                    isUnread: event.status != .working && event.status != .inactive,
                    shouldNotify: true
                )
            }
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
        for threadID in activeProjectLaunchCommandsByThreadID.keys.sorted(by: {
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
            ?? fileBrowserState.entries
        let result = Self.visibleFileEntries(
            from: fullEntries,
            query: query,
            limit: Self.fileBrowserVisibleLimit(for: query)
        )
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

    public func selectFile(relativePath: String?) {
        guard let relativePath else {
            selectedFileRelativePath = nil
            return
        }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        let fullEntries =
            selectedThreadID.flatMap { fileBrowserEntriesByThreadID[$0] }
            ?? fileBrowserState.entries
        guard fullEntries.contains(where: { $0.relativePath == normalizedPath }) else { return }
        selectedFileRelativePath = normalizedPath
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
                "limited": "\(rowCount >= FileBrowserPresentationLimits.maxPublishedEntries)",
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
        selectedFileRelativePath = entries[nextIndex].relativePath
    }

    public func openSelectedFileInNvim() {
        guard let selectedFileRelativePath else { return }
        openFileInNvim(relativePath: selectedFileRelativePath)
    }

    public func openFileInNvim(relativePath: String) {
        guard let selectedThreadID else { return }
        guard let resolvedFile = selectedThreadFileURL(relativePath: relativePath) else { return }
        let normalizedPath = resolvedFile.normalizedPath
        selectedFileRelativePath = normalizedPath
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

        selectedFileRelativePath = normalizedPath
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
        workingDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> UUID {
        let agentCLI = agentCLI ?? configuration.defaultAgentCLI
        let resolvedProjectID = projectID ?? selectedProjectID
        guard let project = projects.first(where: { $0.id == resolvedProjectID }) else {
            throw AppModelError.selectedProjectMissing
        }
        let resolvedWorkingDirectory = workingDirectory ?? project.rootDirectory
        guard isExistingDirectory(resolvedWorkingDirectory) else {
            throw AppModelError.missingProjectDirectory(resolvedWorkingDirectory.path)
        }

        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName =
            trimmedDisplayName?.isEmpty == false
            ? trimmedDisplayName ?? ""
            : "Starting \(agentCLI.displayName)..."
        let thread = AgentThread(
            displayName: resolvedDisplayName,
            projectID: project.id,
            workingDirectory: resolvedWorkingDirectory,
            agentCLI: agentCLI,
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
        guard projects.contains(where: { $0.id == projectID }) else { return }
        guard selectedProjectID != projectID else { return }
        markProjectOpened(projectID)
        selectedProjectID = projectID
        selectedThreadID = firstActiveThreadID(forProject: projectID)
        expandedProjectIDs.insert(projectID)
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Projects",
            name: "project_selected",
            metadata: ["project_id": projectID.uuidString]
        )
        persistProject(projects.first { $0.id == projectID }!)
        persistProjectExpanded(projectID: projectID)
        persistSelection()
    }

    public func selectThread(id threadID: UUID) {
        guard let thread = thread(withID: threadID) else { return }
        markProjectOpened(thread.projectID)
        markThreadOpened(threadID)
        selectedProjectID = thread.projectID
        selectedThreadID = thread.id
        expandedProjectIDs.insert(thread.projectID)
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Threads",
            name: "thread_selected",
            metadata: [
                "thread_id": thread.id.uuidString,
                "agent_cli": thread.agentCLI.rawValue,
            ]
        )
        persistProject(projects.first { $0.id == thread.projectID }!)
        persistThread(threads[threadIndexByID[threadID]!])
        persistProjectExpanded(projectID: thread.projectID)
        persistSelection()
    }

    public func archiveThread(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        let projectID = threads[index].projectID
        mutateThread(at: index) { $0.isArchived = true }
        if selectedThreadID == threadID {
            selectedThreadID = firstActiveThreadID(forProject: projectID)
            resetFileBrowserForSelectedThread()
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

    public func navigateBack() {
        guard let selection = navigationHistory.goBack() else { return }
        apply(selection)
        persistSelection()
    }

    public func navigateForward() {
        guard let selection = navigationHistory.goForward() else { return }
        apply(selection)
        persistSelection()
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
        persistProjectExpanded(projectID: selection.projectID)
        resetFileBrowserForSelectedThread()
    }

    private func activeThread(id threadID: UUID) -> AgentThread? {
        guard let index = threadIndexByID[threadID], !threads[index].isArchived else { return nil }
        return threads[index]
    }

    private func applyAgentCLIMetadata(_ metadata: AgentCLISessionMetadata, toThreadAt index: Int) {
        mutateThread(at: index) {
            $0.sessionIdentity = metadata.identity
            $0.canonicalSessionName = metadata.canonicalName
            $0.displayName = metadata.canonicalName
        }
        pendingTerminalTitlesByThreadID.removeValue(forKey: threads[index].id)
        persistThread(threads[index])
    }

    private func refreshFileBrowser(for thread: AgentThread) {
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
        fileIndexDirectoryWatcher.watch(root: thread.workingDirectory) { [weak self] in
            self?.refreshSelectedFileBrowser()
        }
        let cacheKey = fileIndexCacheCoordinator.cacheKey(
            root: thread.workingDirectory,
            ignoreRules: configuration.ignoreRules
        )
        let cachedResult = fileIndexCacheCoordinator.cachedIndex(threadID: thread.id, key: cacheKey)
        let entries =
            cachedResult?.entries
            ?? fileBrowserEntriesByThreadID[thread.id]
            ?? (fileBrowserState.rootPath == thread.workingDirectory.path
                ? fileBrowserState.entries : [])
        fileBrowserEntriesByThreadID[thread.id] = entries
        let visibleResult = Self.visibleFileEntries(
            from: entries,
            query: fileBrowserState.searchQuery,
            limit: Self.fileBrowserVisibleLimit(for: fileBrowserState.searchQuery)
        )
        let metadata = cachedResult?.metadata ?? fileIndexMetadataByThreadID[thread.id]
        fileBrowserState = FileBrowserState(
            rootPath: thread.workingDirectory.path,
            searchQuery: fileBrowserState.searchQuery,
            entries: Self.publishedTreeEntries(from: entries),
            visibleEntries: visibleResult.entries,
            isVisibleEntryLimitApplied: visibleResult.isLimitApplied,
            isIndexing: true,
            metadata: metadata,
            errorMessage: nil
        )
        updateSelectedFileAfterVisibleEntriesChanged()
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
        switch result {
        case .success(let result):
            fileIndexMetadataByThreadID[threadID] = result.metadata
            fileBrowserEntriesByThreadID[threadID] = result.entries
            let visibleResult = Self.visibleFileEntries(
                from: result.entries,
                query: fileBrowserState.searchQuery,
                limit: Self.fileBrowserVisibleLimit(for: fileBrowserState.searchQuery)
            )
            if selectedThreadID == threadID {
                fileBrowserState = FileBrowserState(
                    rootPath: result.metadata.rootPath,
                    searchQuery: fileBrowserState.searchQuery,
                    entries: Self.publishedTreeEntries(from: result.entries),
                    visibleEntries: visibleResult.entries,
                    isVisibleEntryLimitApplied: visibleResult.isLimitApplied,
                    isIndexing: false,
                    metadata: result.metadata,
                    errorMessage: nil
                )
                updateSelectedFileAfterVisibleEntriesChanged()
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
        let cachedResult: FileIndexResult?
        if isExistingDirectory(selectedThread.workingDirectory) {
            let cacheKey = fileIndexCacheCoordinator.cacheKey(
                root: selectedThread.workingDirectory,
                ignoreRules: configuration.ignoreRules
            )
            cachedResult = fileIndexCacheCoordinator.cachedIndex(
                threadID: selectedThread.id, key: cacheKey)
        } else {
            cachedResult = nil
        }
        let entries = cachedResult?.entries ?? fileBrowserEntriesByThreadID[selectedThread.id] ?? []
        fileBrowserEntriesByThreadID[selectedThread.id] = entries
        let visibleResult = Self.visibleFileEntries(
            from: entries,
            query: "",
            limit: FileBrowserPresentationLimits.maxPublishedEntries
        )
        fileBrowserState = FileBrowserState(
            rootPath: selectedThread.workingDirectory.path,
            searchQuery: "",
            entries: Self.publishedTreeEntries(from: entries),
            visibleEntries: visibleResult.entries,
            isVisibleEntryLimitApplied: visibleResult.isLimitApplied,
            metadata: cachedResult?.metadata ?? fileIndexMetadataByThreadID[selectedThread.id]
        )
        updateSelectedFileAfterVisibleEntriesChanged()
    }

    private func updateSelectedFileAfterVisibleEntriesChanged() {
        let fileEntries = fileBrowserState.visibleEntries.filter { !$0.isDirectory }
        guard !fileEntries.isEmpty else {
            selectedFileRelativePath = nil
            return
        }
        if let selectedFileRelativePath,
            fileEntries.contains(where: { $0.relativePath == selectedFileRelativePath })
        {
            return
        }
        selectedFileRelativePath = fileEntries.first?.relativePath
    }

    private static func publishedTreeEntries(from entries: [FileBrowserEntry]) -> [FileBrowserEntry]
    {
        FileBrowserTreeBuilder.presentationEntries(
            from: entries,
            limit: FileBrowserPresentationLimits.maxPublishedEntries
        )
    }

    private static func fileBrowserVisibleLimit(for query: String) -> Int {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? FileBrowserPresentationLimits.maxPublishedEntries
            : FileBrowserPresentationLimits.maxSearchResults
    }

    private static func visibleFileEntries(
        from entries: [FileBrowserEntry],
        query: String,
        limit: Int
    ) -> FuzzyFileMatcher.Result {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let visibleEntries = FileBrowserTreeBuilder.presentationEntries(
                from: entries, limit: limit)
            return FuzzyFileMatcher.Result(
                entries: visibleEntries,
                totalMatches: entries.count,
                isLimitApplied: visibleEntries.count < entries.count
            )
        }
        return FuzzyFileMatcher.rankedResult(entries, query: query, limit: limit)
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
