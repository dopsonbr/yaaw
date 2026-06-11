import Foundation

/// In-memory `YAAWStore` double used by tests and as the seed/fallback factory.
///
/// An `actor` so it satisfies the `Sendable` protocol with no `@unchecked`
/// escape. Write counters (`layoutStateWriteCount`, …) let tests assert that a
/// high-level operation issued exactly the writes it should; they are read with
/// `await store.threadActivityWriteCount`.
public actor InMemoryYAAWStore: YAAWStore {
    private var snapshot: YAAWSnapshot
    private var cachedFileIndexesByKey: [String: CachedFileIndex] = [:]
    private var projectIndexByID: [UUID: Int] = [:]
    private var threadIndexByID: [UUID: Int] = [:]
    public private(set) var layoutStateWriteCount = 0
    public private(set) var threadActivityWriteCount = 0
    public private(set) var selectionChangeWriteCount = 0

    public init(snapshot: YAAWSnapshot) {
        self.snapshot = snapshot
        // Build the lookup indexes inline: a synchronous actor `init` runs in a
        // nonisolated context and so cannot call the isolated `rebuildIndexes()`.
        self.projectIndexByID = Dictionary(
            uniqueKeysWithValues: snapshot.projects.enumerated().map { ($0.element.id, $0.offset) })
        self.threadIndexByID = Dictionary(
            uniqueKeysWithValues: snapshot.threads.enumerated().map { ($0.element.id, $0.offset) })
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

    public func persistSelectionChange(
        selectedProjectID: UUID,
        selectedThreadID: UUID?,
        touchedProject: Project?,
        touchedThread: AgentThread?,
        expandedProjectID: UUID?
    ) {
        selectionChangeWriteCount += 1
        if let touchedProject {
            upsertProject(touchedProject)
        }
        if let touchedThread {
            upsertThread(touchedThread)
        }
        if let expandedProjectID {
            setProjectExpanded(expandedProjectID, isExpanded: true)
        }
        setSelectedProject(selectedProjectID)
        setSelectedThread(selectedThreadID)
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
        threadActivityWriteCount += 1
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
        projectIndexByID = Dictionary(
            uniqueKeysWithValues: snapshot.projects.enumerated().map { ($0.element.id, $0.offset) })
        rebuildThreadIndex()
    }

    private func rebuildThreadIndex() {
        threadIndexByID = Dictionary(
            uniqueKeysWithValues: snapshot.threads.enumerated().map { ($0.element.id, $0.offset) })
    }

    /// The seed snapshot used when the database is empty and the fallback when a
    /// load fails. A single Global project with one "Hello World" thread.
    public static func helloWorldSnapshot() -> YAAWSnapshot {
        let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let threadID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let createdAt = Date(timeIntervalSince1970: 0)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let globalChatsDirectory = ProjectSettings().resolvedGlobalChatsDirectory(
            homeDirectory: homeDirectory)

        let project = Project(
            id: projectID,
            displayName: "Global",
            rootDirectory: globalChatsDirectory,
            createdAt: createdAt,
            lastOpenedAt: createdAt
        )

        let thread = AgentThread(
            id: threadID,
            displayName: "Hello World",
            projectID: projectID,
            workingDirectory: globalChatsDirectory,
            createdAt: createdAt,
            lastOpenedAt: createdAt,
            isArchived: false
        )

        return YAAWSnapshot(
            projects: [project],
            threads: [thread],
            selectedProjectID: projectID,
            selectedThreadID: threadID,
            rightPanelModesByThreadID: [threadID: .files],
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false,
            expandedProjectIDs: [projectID]
        )
    }

    public static func helloWorld() -> InMemoryYAAWStore {
        InMemoryYAAWStore(snapshot: helloWorldSnapshot())
    }
}
