import Combine
import Foundation

public final class AppModel: ObservableObject {
    @Published public private(set) var projects: [Project]
    @Published public private(set) var threads: [AgentThread]
    @Published public private(set) var selectedProjectID: UUID
    @Published public private(set) var selectedThreadID: UUID?
    @Published public private(set) var rightPanelModesByThreadID: [UUID: RightPanelMode]
    @Published public private(set) var isGlobalTerminalExpanded: Bool

    public let projectTerminal: TerminalSurfaceDescriptor
    public private(set) var navigationHistory: NavigationHistory
    private let store: AgentIDEStore

    public init(store: AgentIDEStore = InMemoryAgentIDEStore.helloWorld()) {
        self.store = store
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
        self.isGlobalTerminalExpanded = snapshot.isGlobalTerminalExpanded
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

    public var activeThreadsForSelectedProject: [AgentThread] {
        threads.filter { $0.projectID == selectedProjectID && !$0.isArchived }
    }

    public var archivedThreadsForSelectedProject: [AgentThread] {
        threads.filter { $0.projectID == selectedProjectID && $0.isArchived }
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
        isGlobalTerminalExpanded.toggle()
        persist()
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

    private func persist() {
        store.save(
            AgentIDESnapshot(
                projects: projects,
                threads: threads,
                selectedProjectID: selectedProjectID,
                selectedThreadID: selectedThreadID,
                rightPanelModesByThreadID: rightPanelModesByThreadID,
                selectedRightPanelMode: selectedRightPanelMode,
                isGlobalTerminalExpanded: isGlobalTerminalExpanded
            )
        )
    }
}
