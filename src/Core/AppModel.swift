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
    @Published public private(set) var configuration: YAAWConfiguration

    public let projectTerminal: TerminalSurfaceDescriptor
    public private(set) var navigationHistory: NavigationHistory
    private let store: YAAWStore
    private let terminalManager: TerminalSessionManaging
    private let agentCLIBindings: AgentCLISessionBindingService
    private let fileIndexer: FileIndexing
    private let externalToolResolver: any AgentCLIExecutableResolving
    private let diagnosticRecorder: DiagnosticEventRecording
    private let environment: [String: String]
    private let homeDirectory: URL
    private var fileIndexMetadataByThreadID: [UUID: FileIndexMetadata]
    private var latestFileBrowserRequestIDByThreadID: [UUID: UUID] = [:]
    private var nvimRelativePathsByThreadID: [UUID: String] = [:]
    private var nvimRelaunchTokensByThreadID: [UUID: UUID] = [:]
    private var nvimRelaunchTokensByTabKey: [String: UUID] = [:]
    private var activeProjectLaunchCommandsByThreadID: [UUID: [String]] = [:]
    private var captureReadOffsetsByThreadID: [UUID: UInt64] = [:]
    private var pendingTerminalTitlesByThreadID: [UUID: String] = [:]
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.agentCLIBindings = agentCLIBindings
        self.fileIndexer = fileIndexer
        self.externalToolResolver = externalToolResolver
        self.configuration = configuration.validated()
        self.diagnosticRecorder = diagnosticRecorder
        self.environment = environment
        self.homeDirectory = homeDirectory
        let snapshot = store.load()
        self.projects = snapshot.projects
        self.threads = snapshot.threads
        self.fileIndexMetadataByThreadID = snapshot.fileIndexMetadataByThreadID
        for (index, thread) in snapshot.threads.enumerated() {
            threadIndexByID[thread.id] = index
            if thread.isArchived {
                cachedArchivedThreadsByProject[thread.projectID, default: []].append(thread)
            } else {
                cachedActiveThreadsByProject[thread.projectID, default: []].append(thread)
            }
        }
        let selectedProjectID = snapshot.projects.contains { $0.id == snapshot.selectedProjectID }
            ? snapshot.selectedProjectID
            : snapshot.projects[0].id
        let selectedThreadID = snapshot.threads.contains { $0.id == snapshot.selectedThreadID }
            ? snapshot.selectedThreadID
            : snapshot.threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
        self.selectedProjectID = selectedProjectID
        self.selectedThreadID = selectedThreadID
        self.bottomTerminalExpandedThreadIDs = snapshot.bottomTerminalExpandedThreadIDs
        var rightPanelModesByThreadID = snapshot.rightPanelModesByThreadID
        if let selectedThreadID, rightPanelModesByThreadID[selectedThreadID] == nil {
            rightPanelModesByThreadID[selectedThreadID] = snapshot.selectedRightPanelMode
        }
        self.rightPanelModesByThreadID = rightPanelModesByThreadID
        var rightPanelStatesByThreadID = snapshot.rightPanelStatesByThreadID
        for thread in snapshot.threads where rightPanelStatesByThreadID[thread.id] == nil {
            let mode = rightPanelModesByThreadID[thread.id] ?? (thread.id == selectedThreadID ? snapshot.selectedRightPanelMode : .files)
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
        self.navigationHistory = NavigationHistory(
            initial: AppSelection(projectID: selectedProjectID, threadID: selectedThreadID)
        )
        self.projectTerminal = TerminalSurfaceDescriptor(
            kind: .project,
            title: "Project Terminal",
            placeholderText: "Terminal placeholder for the selected thread"
        )
        recordDiagnostic(
            category: "Lifecycle",
            name: "app_model_loaded",
            metadata: [
                "project_count": "\(projects.count)",
                "thread_count": "\(threads.count)"
            ]
        )
    }

    public var selectedThread: AgentThread? {
        guard let selectedThreadID, let index = threadIndexByID[selectedThreadID] else { return nil }
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
    }

    private func mutateThreads(_ block: (inout [AgentThread]) -> Void) {
        block(&threads)
        rebuildThreadIndexes()
    }

    private func thread(withID threadID: UUID) -> AgentThread? {
        threadIndexByID[threadID].map { threads[$0] }
    }

    private func firstActiveThreadID(forProject projectID: UUID) -> UUID? {
        cachedActiveThreadsByProject[projectID]?.first?.id
    }

    public var windowTitle: String {
        guard let project = selectedProject else { return "YAAW" }
        guard let thread = selectedThread else { return "\(project.displayName) - YAAW" }
        return "\(project.displayName) - \(thread.displayName)"
    }

    public var defaultAgentCLI: AgentCLIKind {
        configuration.defaultAgentCLI
    }

    public func keyboardShortcutDefinition(for action: KeyboardShortcutAction) -> KeyboardShortcutDefinition {
        configuration.shortcut(for: action)
    }

    public func reloadConfiguration(_ configuration: YAAWConfiguration) {
        self.configuration = configuration.validated()
        activeProjectLaunchCommandsByThreadID.removeAll()
        recordDiagnostic(
            category: "Configuration",
            name: "settings_yaml_reloaded",
            metadata: [
                "theme": self.configuration.themeName,
                "default_agent": self.configuration.defaultAgentCLI.rawValue
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

    public var selectedRightPanelMode: RightPanelMode {
        guard let selectedThreadID else { return .files }
        return rightPanelStatesByThreadID[selectedThreadID]?.selectedMode
            ?? rightPanelModesByThreadID[selectedThreadID]
            ?? .files
    }

    public var selectedRightPanelState: RightPanelState {
        guard let selectedThreadID else { return RightPanelState() }
        return rightPanelStatesByThreadID[selectedThreadID] ?? RightPanelState.defaultState(
            selectedMode: rightPanelModesByThreadID[selectedThreadID] ?? .files
        )
    }

    public var selectedRightPanelTab: RightPanelTab {
        selectedRightPanelState.selectedTab
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

    public var hasArchivedThreadsForSelectedProject: Bool {
        !archivedThreadsForSelectedProject.isEmpty
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
                "expanded": "\(bottomTerminalExpandedThreadIDs.contains(selectedThreadID))"
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

    public func setSidebarWidth(_ width: Double) {
        layoutState.sidebarWidth = LayoutState.clamp(
            width,
            minimum: LayoutState.minimumSidebarWidth,
            maximum: LayoutState.maximumSidebarWidth
        )
        persistLayout()
    }

    public func setRightPanelWidth(_ width: Double) {
        layoutState.rightPanelWidth = LayoutState.clamp(
            width,
            minimum: LayoutState.minimumRightPanelWidth,
            maximum: LayoutState.maximumRightPanelWidth
        )
        persistLayout()
    }

    public func setGlobalTerminalHeight(_ height: Double) {
        layoutState.globalTerminalHeight = LayoutState.clamp(
            height,
            minimum: LayoutState.minimumGlobalTerminalHeight,
            maximum: LayoutState.maximumGlobalTerminalHeight
        )
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
            guard let tab = rightPanelStatesByThreadID[threadID]?.tabs.first(where: { $0.id == tabID }),
                  tab.kind == .nvim else {
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
                relaunchToken: nvimRelaunchTokensByTabKey[nvimTabKey(threadID: threadID, tabID: tabID)],
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
                "surface": role.surfaceKind.rawValue
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
        case .files:
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
              ) else {
            return
        }
        if metadata.reportedName == nil,
           metadata.title == nil,
           let pendingTitle = pendingTerminalTitlesByThreadID[threadID] {
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
                || threads[index].canonicalSessionName == identity else { return }
        let metadata = agentCLIBindings.metadata(
            fromExistingIdentity: identity,
            terminalTitle: title
        )
        applyAgentCLIMetadata(metadata, toThreadAt: index)
    }

    public func pollSelectedAgentCLICaptureLog() {
        guard let thread = selectedThread,
              let captured = agentCLIBindings.capturedOutput(
                for: thread,
                after: captureReadOffsetsByThreadID[thread.id] ?? 0
              ) else {
            return
        }
        captureReadOffsetsByThreadID[thread.id] = captured.nextOffset
        recordAgentCLIOutput(threadID: thread.id, output: captured.output)
    }

    public func refreshSelectedFileBrowser() {
        guard let thread = selectedThread else {
            fileBrowserState = FileBrowserState()
            return
        }
        refreshFileBrowser(for: thread)
    }

    public func updateFileSearchQuery(_ query: String) {
        fileBrowserState.searchQuery = query
        fileBrowserState.visibleEntries = FuzzyFileMatcher.rankedEntries(
            fileBrowserState.entries,
            query: query
        )
    }

    public func openFileInNvim(relativePath: String) {
        guard let selectedThreadID else { return }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        guard !normalizedPath.isEmpty else { return }
        var state = selectedRightPanelState
        let existingTabID = RightPanelTab.nvimTabID(relativePath: normalizedPath)
        let alreadyOpen = state.tabs.contains { $0.id == existingTabID }
        let tab = state.openNvimTab(relativePath: normalizedPath)
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = .nvim
        if !alreadyOpen {
            nvimRelaunchTokensByTabKey[nvimTabKey(threadID: selectedThreadID, tabID: tab.id)] = UUID()
            terminateTerminal(role: .nvimTab(threadID: selectedThreadID, tabID: tab.id))
        }
        nvimRelativePathsByThreadID[selectedThreadID] = normalizedPath
        nvimRelaunchTokensByThreadID[selectedThreadID] = UUID()
        persistRightPanelMode(threadID: selectedThreadID)
        persistRightPanelState(threadID: selectedThreadID)
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
            lastOpenedAt: now
        )
        projects.append(project)
        selectedProjectID = project.id
        selectedThreadID = nil
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Projects",
            name: "project_created",
            metadata: ["project_id": project.id.uuidString]
        )
        persistProject(project)
        persistSelection()
        return project.id
    }

    @discardableResult
    public func createThread(
        agentCLI: AgentCLIKind?,
        displayName: String? = nil,
        workingDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> UUID {
        let agentCLI = agentCLI ?? configuration.defaultAgentCLI
        guard let project = selectedProject else {
            throw AppModelError.selectedProjectMissing
        }
        let resolvedWorkingDirectory = workingDirectory ?? project.rootDirectory
        guard isExistingDirectory(resolvedWorkingDirectory) else {
            throw AppModelError.missingProjectDirectory(resolvedWorkingDirectory.path)
        }

        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName = trimmedDisplayName?.isEmpty == false
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
        selectedThreadID = thread.id
        rightPanelModesByThreadID[thread.id] = .files
        rightPanelStatesByThreadID[thread.id] = RightPanelState.defaultState()
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Threads",
            name: "thread_created",
            metadata: [
                "thread_id": thread.id.uuidString,
                "agent_cli": thread.agentCLI.rawValue
            ]
        )
        persistThread(thread)
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

    public func selectProject(id projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        guard selectedProjectID != projectID else { return }
        selectedProjectID = projectID
        selectedThreadID = firstActiveThreadID(forProject: projectID)
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Projects",
            name: "project_selected",
            metadata: ["project_id": projectID.uuidString]
        )
        persistSelection()
    }

    public func selectThread(id threadID: UUID) {
        guard let thread = thread(withID: threadID) else { return }
        selectedProjectID = thread.projectID
        selectedThreadID = thread.id
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Threads",
            name: "thread_selected",
            metadata: [
                "thread_id": thread.id.uuidString,
                "agent_cli": thread.agentCLI.rawValue
            ]
        )
        persistSelection()
    }

    public func archiveThread(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        let projectID = threads[index].projectID
        mutateThreads { $0[index].isArchived = true }
        if selectedThreadID == threadID {
            selectedThreadID = firstActiveThreadID(forProject: projectID)
            resetFileBrowserForSelectedThread()
        }
        pushCurrentSelection()
        persistThread(threads[index])
        persistSelection()
    }

    public func unarchiveThread(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThreads { $0[index].isArchived = false }
        selectThread(id: threadID)
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
        navigationHistory.push(AppSelection(projectID: selectedProjectID, threadID: selectedThreadID))
    }

    private func apply(_ selection: AppSelection) {
        guard projects.contains(where: { $0.id == selection.projectID }) else { return }
        selectedProjectID = selection.projectID
        selectedThreadID = selection.threadID
        resetFileBrowserForSelectedThread()
    }

    private func activeThread(id threadID: UUID) -> AgentThread? {
        guard let index = threadIndexByID[threadID], !threads[index].isArchived else { return nil }
        return threads[index]
    }

    private func applyAgentCLIMetadata(_ metadata: AgentCLISessionMetadata, toThreadAt index: Int) {
        mutateThreads { threads in
            threads[index].sessionIdentity = metadata.identity
            threads[index].canonicalSessionName = metadata.canonicalName
            threads[index].displayName = metadata.canonicalName
        }
        pendingTerminalTitlesByThreadID.removeValue(forKey: threads[index].id)
        persistThread(threads[index])
    }

    private func refreshFileBrowser(for thread: AgentThread) {
        let requestID = UUID()
        latestFileBrowserRequestIDByThreadID[thread.id] = requestID
        let metadata = fileIndexMetadataByThreadID[thread.id]
        guard isExistingDirectory(thread.workingDirectory) else {
            fileBrowserState = FileBrowserState(
                rootPath: thread.workingDirectory.path,
                searchQuery: fileBrowserState.searchQuery,
                metadata: metadata,
                errorMessage: "Missing working directory: \(thread.workingDirectory.path)"
            )
            recordDiagnostic(
                category: "Indexing",
                name: "file_index_failed",
                metadata: [
                    "thread_id": thread.id.uuidString,
                    "reason": "missing_root"
                ]
            )
            return
        }
        fileBrowserState = FileBrowserState(
            rootPath: thread.workingDirectory.path,
            searchQuery: fileBrowserState.searchQuery,
            entries: fileBrowserState.entries,
            visibleEntries: fileBrowserState.visibleEntries,
            isIndexing: true,
            metadata: metadata,
            errorMessage: nil
        )
        fileIndexer.indexFiles(
            threadID: thread.id,
            root: thread.workingDirectory,
            ignoreRules: configuration.ignoreRules
        ) { [weak self] result in
            self?.finishFileBrowserRefresh(threadID: thread.id, requestID: requestID, result: result)
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
            if selectedThreadID == threadID {
                fileBrowserState = FileBrowserState(
                    rootPath: result.metadata.rootPath,
                    searchQuery: fileBrowserState.searchQuery,
                    entries: result.entries,
                    visibleEntries: FuzzyFileMatcher.rankedEntries(
                        result.entries,
                        query: fileBrowserState.searchQuery
                    ),
                    isIndexing: false,
                    metadata: result.metadata,
                    errorMessage: nil
                )
            }
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
                    "error": sanitizedDiagnosticValue(String(describing: error))
                ]
            )
        }
    }

    private func resetFileBrowserForSelectedThread() {
        guard let selectedThread else {
            fileBrowserState = FileBrowserState()
            return
        }
        fileBrowserState = FileBrowserState(
            rootPath: selectedThread.workingDirectory.path,
            searchQuery: "",
            metadata: fileIndexMetadataByThreadID[selectedThread.id]
        )
    }

    private func directoryState(for url: URL) -> ProjectDirectoryState {
        isExistingDirectory(url)
            ? .available(path: url.path)
            : .missing(path: url.path)
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func defaultShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    private func externalToolCommand(named executableName: String, arguments: [String] = []) -> [String] {
        [
            externalToolResolver.executablePath(named: executableName, environment: environment) ?? executableName
        ] + arguments
    }

    private func externalToolCommand(preferredNames: [String], arguments: [String] = []) -> [String] {
        for name in preferredNames {
            if let path = externalToolResolver.executablePath(named: name, environment: environment) {
                return [path] + arguments
            }
        }
        return [preferredNames[0]] + arguments
    }

    private func gitToolCommand() -> [String] {
        let gitTool = configuration.tools.git.preferred
        if let resolvedGitTool = externalToolResolver.executablePath(named: gitTool, environment: environment) {
            return [resolvedGitTool]
        }
        let fallback = configuration.tools.diff.fallback
        guard let executable = fallback.first else { return ["git", "diff"] }
        let resolvedExecutable = externalToolResolver.executablePath(named: executable, environment: environment) ?? executable
        return [resolvedExecutable] + Array(fallback.dropFirst())
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

    private func persistFileIndexMetadata(_ metadata: FileIndexMetadata) {
        store.upsertFileIndexMetadata(metadata)
    }

    private func recordTerminalLaunchFailure(role: TerminalRole, path: String, reason: String) {
        recordDiagnostic(
            category: "Terminal",
            name: "terminal_launch_failed",
            metadata: [
                "role": role.diagnosticName,
                "surface": role.surfaceKind.rawValue,
                "reason": reason,
                "path": sanitizedDiagnosticValue(path)
            ]
        )
    }

    private func nvimTabKey(threadID: UUID, tabID: String) -> String {
        "\(threadID.uuidString)|\(tabID)"
    }

    private func recordDiagnostic(category: String, name: String, metadata: [String: String] = [:]) {
        diagnosticRecorder.record(DiagnosticEvent(category: category, name: name, metadata: metadata))
    }

    private func sanitizedDiagnosticValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private extension TerminalRole {
    var diagnosticName: String {
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
