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

public final class AppModel: ObservableObject {
    @Published public private(set) var projects: [Project]
    @Published public private(set) var threads: [AgentThread]
    @Published public private(set) var selectedProjectID: UUID
    @Published public private(set) var selectedThreadID: UUID?
    @Published public private(set) var rightPanelModesByThreadID: [UUID: RightPanelMode]
    @Published public private(set) var layoutState: LayoutState

    public let projectTerminal: TerminalSurfaceDescriptor
    public private(set) var navigationHistory: NavigationHistory
    private let store: AgentIDEStore
    private let terminalManager: TerminalSessionManaging
    private let agentCLIBindings: AgentCLISessionBindingService
    private let homeDirectory: URL
    private var activeProjectLaunchCommandsByThreadID: [UUID: [String]] = [:]
    private var captureReadOffsetsByThreadID: [UUID: UInt64] = [:]
    private var pendingTerminalTitlesByThreadID: [UUID: String] = [:]

    public init(
        store: AgentIDEStore = InMemoryAgentIDEStore.helloWorld(),
        terminalManager: TerminalSessionManaging = PlaceholderTerminalSessionManager(),
        agentCLIBindings: AgentCLISessionBindingService = AgentCLISessionBindingService(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.agentCLIBindings = agentCLIBindings
        self.homeDirectory = homeDirectory
        let snapshot = store.load()
        self.projects = snapshot.projects
        self.threads = snapshot.threads
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
        self.navigationHistory = NavigationHistory(
            initial: AppSelection(projectID: selectedProjectID, threadID: selectedThreadID)
        )
        self.projectTerminal = TerminalSurfaceDescriptor(
            kind: .project,
            title: "Project Terminal",
            placeholderText: "Terminal placeholder for the selected thread"
        )
    }

    public var selectedThread: AgentThread? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
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
            return TerminalLaunchRequest(
                role: role,
                title: "nvim",
                workingDirectory: thread.workingDirectory,
                command: ["nvim"]
            )
        case .lazygit(let threadID):
            guard let thread = activeThread(id: threadID) else { return nil }
            return TerminalLaunchRequest(
                role: role,
                title: "Git",
                workingDirectory: thread.workingDirectory,
                command: ["lazygit"]
            )
        }
    }

    @discardableResult
    public func activateTerminal(role: TerminalRole) -> TerminalSessionRecord? {
        guard let request = terminalLaunchRequest(for: role) else { return nil }
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
        guard rootDirectory.isExistingDirectory else {
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
        pushCurrentSelection()
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
        guard resolvedWorkingDirectory.isExistingDirectory else {
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
        pushCurrentSelection()
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
        pushCurrentSelection()
        persist()
    }

    public func selectThread(id threadID: UUID) {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return }
        selectedProjectID = thread.projectID
        selectedThreadID = thread.id
        pushCurrentSelection()
        persist()
    }

    public func archiveThread(id threadID: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].isArchived = true
        if selectedThreadID == threadID {
            selectedThreadID = threads.first { $0.projectID == threads[index].projectID && !$0.isArchived }?.id
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

    private func defaultShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
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
                layoutState: layoutState
            )
        )
    }
}

private extension URL {
    var isExistingDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
