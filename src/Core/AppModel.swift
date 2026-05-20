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
    @Published public private(set) var layoutState: LayoutState
    @Published public private(set) var fileBrowserState: FileBrowserState

    public let projectTerminal: TerminalSurfaceDescriptor
    public private(set) var navigationHistory: NavigationHistory
    private let store: AgentIDEStore
    private let terminalManager: TerminalSessionManaging
    private let agentCLIBindings: AgentCLISessionBindingService
    private let fileIndexer: FileIndexing
    private let externalToolResolver: any AgentCLIExecutableResolving
    private let configuration: AgentIDEConfiguration
    private let diagnosticRecorder: DiagnosticEventRecording
    private let environment: [String: String]
    private let homeDirectory: URL
    private var fileIndexMetadataByThreadID: [UUID: FileIndexMetadata]
    private var latestFileBrowserRequestIDByThreadID: [UUID: UUID] = [:]
    private var nvimRelativePathsByThreadID: [UUID: String] = [:]
    private var nvimRelaunchTokensByThreadID: [UUID: UUID] = [:]
    private var activeProjectLaunchCommandsByThreadID: [UUID: [String]] = [:]
    private var captureReadOffsetsByThreadID: [UUID: UInt64] = [:]
    private var pendingTerminalTitlesByThreadID: [UUID: String] = [:]

    public init(
        store: AgentIDEStore = InMemoryAgentIDEStore.helloWorld(),
        terminalManager: TerminalSessionManaging = PlaceholderTerminalSessionManager(),
        agentCLIBindings: AgentCLISessionBindingService = AgentCLISessionBindingService(),
        fileIndexer: FileIndexing = BackgroundFileIndexer(),
        externalToolResolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        configuration: AgentIDEConfiguration = AgentIDEConfiguration(),
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.agentCLIBindings = agentCLIBindings
        self.fileIndexer = fileIndexer
        self.externalToolResolver = externalToolResolver
        self.configuration = configuration
        self.diagnosticRecorder = diagnosticRecorder
        self.environment = environment
        self.homeDirectory = homeDirectory
        let snapshot = store.load()
        self.projects = snapshot.projects
        self.threads = snapshot.threads
        self.fileIndexMetadataByThreadID = snapshot.fileIndexMetadataByThreadID
        let selectedProjectID = snapshot.projects.contains { $0.id == snapshot.selectedProjectID }
            ? snapshot.selectedProjectID
            : snapshot.projects[0].id
        let selectedThreadID = snapshot.threads.contains { $0.id == snapshot.selectedThreadID }
            ? snapshot.selectedThreadID
            : snapshot.threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
        self.selectedProjectID = selectedProjectID
        self.selectedThreadID = selectedThreadID
        var rightPanelModesByThreadID = snapshot.rightPanelModesByThreadID
        if let selectedThreadID, rightPanelModesByThreadID[selectedThreadID] == nil {
            rightPanelModesByThreadID[selectedThreadID] = snapshot.selectedRightPanelMode
        }
        self.rightPanelModesByThreadID = rightPanelModesByThreadID
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
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    public var windowTitle: String {
        guard let project = selectedProject else { return "Agent IDE" }
        guard let thread = selectedThread else { return "\(project.displayName) - Agent IDE" }
        return "\(project.displayName) - \(thread.displayName)"
    }

    public var selectedProjectDirectoryState: ProjectDirectoryState? {
        selectedProject.map { directoryState(for: $0.rootDirectory) }
    }

    public var selectedThreadWorkingDirectoryState: ProjectDirectoryState? {
        selectedThread.map { directoryState(for: $0.workingDirectory) }
    }

    public var selectedRightPanelMode: RightPanelMode {
        guard let selectedThreadID else { return .files }
        return rightPanelModesByThreadID[selectedThreadID] ?? .files
    }

    public var isGlobalTerminalExpanded: Bool {
        layoutState.isGlobalTerminalExpanded
    }

    public var activeThreadsForSelectedProject: [AgentThread] {
        threads.filter { $0.projectID == selectedProjectID && !$0.isArchived }
    }

    public var archivedThreadsForSelectedProject: [AgentThread] {
        threads.filter { $0.projectID == selectedProjectID && $0.isArchived }
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
        persist()
    }

    public func cycleRightPanelModeForward() {
        selectRightPanelMode(selectedRightPanelMode.next)
    }

    public func cycleRightPanelModeBackward() {
        selectRightPanelMode(selectedRightPanelMode.previous)
    }

    public func toggleGlobalTerminal() {
        layoutState.isGlobalTerminalExpanded.toggle()
        recordDiagnostic(
            category: "Layout",
            name: "global_terminal_toggled",
            metadata: ["expanded": "\(layoutState.isGlobalTerminalExpanded)"]
        )
        persist()
    }

    public func toggleSidebarCollapsed() {
        layoutState.isSidebarCollapsed.toggle()
        persist()
    }

    public func toggleRightPanelCollapsed() {
        layoutState.isRightPanelCollapsed.toggle()
        persist()
    }

    public func setSidebarWidth(_ width: Double) {
        layoutState.sidebarWidth = LayoutState.clamp(
            width,
            minimum: LayoutState.minimumSidebarWidth,
            maximum: LayoutState.maximumSidebarWidth
        )
        persist()
    }

    public func setRightPanelWidth(_ width: Double) {
        layoutState.rightPanelWidth = LayoutState.clamp(
            width,
            minimum: LayoutState.minimumRightPanelWidth,
            maximum: LayoutState.maximumRightPanelWidth
        )
        persist()
    }

    public func setGlobalTerminalHeight(_ height: Double) {
        layoutState.globalTerminalHeight = LayoutState.clamp(
            height,
            minimum: LayoutState.minimumGlobalTerminalHeight,
            maximum: LayoutState.maximumGlobalTerminalHeight
        )
        persist()
    }

    public func terminalLaunchRequest(for role: TerminalRole) -> TerminalLaunchRequest? {
        switch role {
        case .global:
            return TerminalLaunchRequest(
                role: .global,
                title: "Global Terminal",
                workingDirectory: homeDirectory,
                command: [defaultShellPath()]
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
                command = agentCLIBindings.terminalCommand(for: thread)
            }
            activeProjectLaunchCommandsByThreadID[threadID] = command
            return TerminalLaunchRequest(
                role: role,
                title: "\(thread.agentCLI.displayName) Terminal",
                workingDirectory: thread.workingDirectory,
                command: command
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
                command: externalToolCommand(named: "nvim", arguments: arguments),
                relaunchToken: nvimRelaunchTokensByThreadID[threadID]
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
                command: externalToolCommand(named: "lazygit")
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
    public func activateGlobalTerminal() -> TerminalSessionRecord? {
        activateTerminal(role: .global)
    }

    @discardableResult
    public func activateSelectedRightPanelTerminal() -> TerminalSessionRecord? {
        guard let selectedThreadID else { return nil }
        switch selectedRightPanelMode {
        case .files:
            return nil
        case .nvim:
            return activateTerminal(role: .nvim(threadID: selectedThreadID))
        case .git:
            return activateTerminal(role: .lazygit(threadID: selectedThreadID))
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
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
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
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
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
        nvimRelativePathsByThreadID[selectedThreadID] = normalizedPath
        nvimRelaunchTokensByThreadID[selectedThreadID] = UUID()
        terminateTerminal(role: .nvim(threadID: selectedThreadID))
        selectRightPanelMode(.nvim)
    }

    @discardableResult
    public func createProject(
        displayName: String,
        rootDirectory: URL,
        now: Date = Date()
    ) throws -> UUID {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AppModelError.emptyProjectName
        }
        guard isExistingDirectory(rootDirectory) else {
            throw AppModelError.missingProjectDirectory(rootDirectory.path)
        }

        let project = Project(
            displayName: trimmedName,
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
        persist()
        return project.id
    }

    @discardableResult
    public func createThread(
        agentCLI: AgentCLIKind?,
        displayName: String? = nil,
        workingDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> UUID {
        guard let agentCLI else {
            throw AppModelError.missingAgentCLI
        }
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
            : "New \(agentCLI.rawValue) thread"
        let thread = AgentThread(
            displayName: resolvedDisplayName,
            projectID: project.id,
            workingDirectory: resolvedWorkingDirectory,
            agentCLI: agentCLI,
            createdAt: now,
            lastOpenedAt: now
        )
        threads.append(thread)
        selectedThreadID = thread.id
        rightPanelModesByThreadID[thread.id] = .files
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
        persist()
        return thread.id
    }

    public func changeAgentCLI(for threadID: UUID, to agentCLI: AgentCLIKind) throws {
        guard threads.contains(where: { $0.id == threadID }) else {
            throw AppModelError.threadNotFound
        }
        throw AppModelError.agentCLIChangeNotAllowed
    }

    public func selectProject(id projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        guard selectedProjectID != projectID else { return }
        selectedProjectID = projectID
        selectedThreadID = threads.first { $0.projectID == projectID && !$0.isArchived }?.id
        resetFileBrowserForSelectedThread()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Projects",
            name: "project_selected",
            metadata: ["project_id": projectID.uuidString]
        )
        persist()
    }

    public func selectThread(id threadID: UUID) {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return }
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
        persist()
    }

    public func archiveThread(id threadID: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].isArchived = true
        if selectedThreadID == threadID {
            selectedThreadID = threads.first { $0.projectID == threads[index].projectID && !$0.isArchived }?.id
            resetFileBrowserForSelectedThread()
        }
        pushCurrentSelection()
        persist()
    }

    public func unarchiveThread(id threadID: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].isArchived = false
        selectThread(id: threadID)
    }

    public func navigateBack() {
        guard let selection = navigationHistory.goBack() else { return }
        apply(selection)
        persist()
    }

    public func navigateForward() {
        guard let selection = navigationHistory.goForward() else { return }
        apply(selection)
        persist()
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
        threads.first { $0.id == threadID && !$0.isArchived }
    }

    private func applyAgentCLIMetadata(_ metadata: AgentCLISessionMetadata, toThreadAt index: Int) {
        threads[index].sessionIdentity = metadata.identity
        threads[index].canonicalSessionName = metadata.canonicalName
        threads[index].displayName = metadata.canonicalName
        pendingTerminalTitlesByThreadID.removeValue(forKey: threads[index].id)
        persist()
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
            persist()
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

    private func persist() {
        store.save(
            AgentIDESnapshot(
                projects: projects,
                threads: threads,
                selectedProjectID: selectedProjectID,
                selectedThreadID: selectedThreadID,
                rightPanelModesByThreadID: rightPanelModesByThreadID,
                selectedRightPanelMode: selectedRightPanelMode,
                isGlobalTerminalExpanded: layoutState.isGlobalTerminalExpanded,
                layoutState: layoutState,
                fileIndexMetadataByThreadID: fileIndexMetadataByThreadID
            )
        )
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
        case .global:
            return "global"
        case .nvim:
            return "nvim"
        case .lazygit:
            return "lazygit"
        }
    }
}
