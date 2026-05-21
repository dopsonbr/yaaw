import Foundation

public struct YAAWSnapshot: Equatable, Sendable {
    public var projects: [Project]
    public var threads: [AgentThread]
    public var selectedProjectID: UUID
    public var selectedThreadID: UUID?
    public var rightPanelModesByThreadID: [UUID: RightPanelMode]
    public var rightPanelStatesByThreadID: [UUID: RightPanelState]
    public var selectedRightPanelMode: RightPanelMode
    public var bottomTerminalExpandedThreadIDs: Set<UUID>
    public var layoutState: LayoutState
    public var fileIndexMetadataByThreadID: [UUID: FileIndexMetadata]
    public var threadActivityByThreadID: [UUID: ThreadActivityState]
    public var expandedProjectIDs: Set<UUID>
    public var expandedArchivedProjectIDs: Set<UUID>

    public var isGlobalTerminalExpanded: Bool {
        get { selectedThreadID.map { bottomTerminalExpandedThreadIDs.contains($0) } ?? false }
        set {
            guard let selectedThreadID else { return }
            if newValue {
                bottomTerminalExpandedThreadIDs.insert(selectedThreadID)
            } else {
                bottomTerminalExpandedThreadIDs.remove(selectedThreadID)
            }
        }
    }

    public init(
        projects: [Project],
        threads: [AgentThread],
        selectedProjectID: UUID,
        selectedThreadID: UUID?,
        rightPanelModesByThreadID: [UUID: RightPanelMode] = [:],
        rightPanelStatesByThreadID: [UUID: RightPanelState] = [:],
        selectedRightPanelMode: RightPanelMode,
        bottomTerminalExpandedThreadIDs: Set<UUID> = [],
        isGlobalTerminalExpanded: Bool,
        layoutState: LayoutState? = nil,
        fileIndexMetadataByThreadID: [UUID: FileIndexMetadata] = [:],
        threadActivityByThreadID: [UUID: ThreadActivityState] = [:],
        expandedProjectIDs: Set<UUID> = [],
        expandedArchivedProjectIDs: Set<UUID> = []
    ) {
        self.projects = projects
        self.threads = threads
        self.selectedProjectID = selectedProjectID
        self.selectedThreadID = selectedThreadID
        self.rightPanelModesByThreadID = rightPanelModesByThreadID
        var states = rightPanelStatesByThreadID
        for (threadID, mode) in rightPanelModesByThreadID where states[threadID] == nil {
            states[threadID] = RightPanelState.defaultState(selectedMode: mode)
        }
        if let selectedThreadID, states[selectedThreadID] == nil {
            states[selectedThreadID] = RightPanelState.defaultState(selectedMode: selectedRightPanelMode)
        }
        self.rightPanelStatesByThreadID = states
        self.selectedRightPanelMode = selectedRightPanelMode
        self.bottomTerminalExpandedThreadIDs = bottomTerminalExpandedThreadIDs
        self.layoutState = layoutState ?? LayoutState(isGlobalTerminalExpanded: isGlobalTerminalExpanded)
        if isGlobalTerminalExpanded, let selectedThreadID {
            self.bottomTerminalExpandedThreadIDs.insert(selectedThreadID)
        }
        self.layoutState.isGlobalTerminalExpanded = false
        self.fileIndexMetadataByThreadID = fileIndexMetadataByThreadID
        self.threadActivityByThreadID = threadActivityByThreadID
        self.expandedProjectIDs = expandedProjectIDs
        self.expandedArchivedProjectIDs = expandedArchivedProjectIDs
    }
}

public protocol YAAWStore: AnyObject {
    func load() -> YAAWSnapshot
    func save(_ snapshot: YAAWSnapshot)

    func upsertProject(_ project: Project)
    func upsertThread(_ thread: AgentThread)
    func deleteThread(id: UUID)
    func setRightPanelMode(threadID: UUID, mode: RightPanelMode)
    func setRightPanelState(threadID: UUID, state: RightPanelState)
    func setBottomTerminalExpanded(threadID: UUID, isExpanded: Bool)
    func setSelectedProject(_ projectID: UUID)
    func setSelectedThread(_ threadID: UUID?)
    func setLayoutState(_ state: LayoutState)
    func setProjectExpanded(_ projectID: UUID, isExpanded: Bool)
    func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool)
    func upsertFileIndexMetadata(_ metadata: FileIndexMetadata)
    func upsertThreadActivity(_ activity: ThreadActivityState)
    func cachedFileIndex(cacheKey: String) -> CachedFileIndex?
    func upsertCachedFileIndex(_ index: CachedFileIndex)
}

public final class InMemoryYAAWStore: YAAWStore {
    private var snapshot: YAAWSnapshot
    private var cachedFileIndexesByKey: [String: CachedFileIndex] = [:]
    private var projectIndexByID: [UUID: Int] = [:]
    private var threadIndexByID: [UUID: Int] = [:]
    private(set) var layoutStateWriteCount = 0

    public init(snapshot: YAAWSnapshot) {
        self.snapshot = snapshot
        rebuildIndexes()
    }

    public func load() -> YAAWSnapshot {
        snapshot
    }

    public func save(_ snapshot: YAAWSnapshot) {
        self.snapshot = snapshot
        rebuildIndexes()
    }

    public func upsertProject(_ project: Project) {
        if let index = projectIndexByID[project.id] {
            snapshot.projects[index] = project
        } else {
            projectIndexByID[project.id] = snapshot.projects.count
            snapshot.projects.append(project)
        }
    }

    public func upsertThread(_ thread: AgentThread) {
        if let index = threadIndexByID[thread.id] {
            snapshot.threads[index] = thread
        } else {
            threadIndexByID[thread.id] = snapshot.threads.count
            snapshot.threads.append(thread)
        }
    }

    public func deleteThread(id: UUID) {
        snapshot.threads.removeAll { $0.id == id }
        threadIndexByID.removeValue(forKey: id)
        rebuildThreadIndex()
        snapshot.rightPanelModesByThreadID.removeValue(forKey: id)
        snapshot.rightPanelStatesByThreadID.removeValue(forKey: id)
        snapshot.bottomTerminalExpandedThreadIDs.remove(id)
        snapshot.fileIndexMetadataByThreadID.removeValue(forKey: id)
        snapshot.threadActivityByThreadID.removeValue(forKey: id)
        if snapshot.selectedThreadID == id {
            snapshot.selectedThreadID = nil
        }
    }

    public func setRightPanelMode(threadID: UUID, mode: RightPanelMode) {
        snapshot.rightPanelModesByThreadID[threadID] = mode
    }

    public func setRightPanelState(threadID: UUID, state: RightPanelState) {
        snapshot.rightPanelStatesByThreadID[threadID] = state
    }

    public func setBottomTerminalExpanded(threadID: UUID, isExpanded: Bool) {
        if isExpanded {
            snapshot.bottomTerminalExpandedThreadIDs.insert(threadID)
        } else {
            snapshot.bottomTerminalExpandedThreadIDs.remove(threadID)
        }
    }

    public func setSelectedProject(_ projectID: UUID) {
        snapshot.selectedProjectID = projectID
    }

    public func setSelectedThread(_ threadID: UUID?) {
        snapshot.selectedThreadID = threadID
    }

    public func setLayoutState(_ state: LayoutState) {
        layoutStateWriteCount += 1
        snapshot.layoutState = state
    }

    public func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        if isExpanded {
            snapshot.expandedProjectIDs.insert(projectID)
        } else {
            snapshot.expandedProjectIDs.remove(projectID)
        }
    }

    public func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool) {
        if isExpanded {
            snapshot.expandedArchivedProjectIDs.insert(projectID)
        } else {
            snapshot.expandedArchivedProjectIDs.remove(projectID)
        }
    }

    public func upsertFileIndexMetadata(_ metadata: FileIndexMetadata) {
        snapshot.fileIndexMetadataByThreadID[metadata.threadID] = metadata
    }

    public func upsertThreadActivity(_ activity: ThreadActivityState) {
        snapshot.threadActivityByThreadID[activity.threadID] = activity
    }

    public func cachedFileIndex(cacheKey: String) -> CachedFileIndex? {
        cachedFileIndexesByKey[cacheKey]
    }

    public func upsertCachedFileIndex(_ index: CachedFileIndex) {
        guard let cacheKey = index.metadata.cacheKey else { return }
        cachedFileIndexesByKey[cacheKey] = index
    }

    private func rebuildIndexes() {
        projectIndexByID = Dictionary(uniqueKeysWithValues: snapshot.projects.enumerated().map { ($0.element.id, $0.offset) })
        rebuildThreadIndex()
    }

    private func rebuildThreadIndex() {
        threadIndexByID = Dictionary(uniqueKeysWithValues: snapshot.threads.enumerated().map { ($0.element.id, $0.offset) })
    }

    public static func helloWorld() -> InMemoryYAAWStore {
        let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let threadID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let createdAt = Date(timeIntervalSince1970: 0)
        let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        let project = Project(
            id: projectID,
            displayName: "Global",
            rootDirectory: homeDirectory,
            createdAt: createdAt,
            lastOpenedAt: createdAt
        )

        let thread = AgentThread(
            id: threadID,
            displayName: "Hello World",
            projectID: projectID,
            workingDirectory: homeDirectory,
            createdAt: createdAt,
            lastOpenedAt: createdAt,
            isArchived: false
        )

        return InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [project],
                threads: [thread],
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                rightPanelModesByThreadID: [threadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false,
                expandedProjectIDs: [projectID]
            )
        )
    }
}
