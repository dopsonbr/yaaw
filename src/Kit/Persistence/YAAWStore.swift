import Foundation

/// A complete, transactionally-consistent picture of all durable YAAW state.
///
/// `save(_:)` treats a snapshot as the *full* desired state, not a delta:
/// rows absent from the snapshot are pruned. Incremental single-row mutations
/// (`upsertThread`, `setRightPanelMode`, …) exist for hot paths that should not
/// pay the cost of serializing the whole world.
public struct YAAWSnapshot: Equatable, Sendable {
    /// All projects, in display order.
    public var projects: [Project]
    /// All agent threads across every project, in display order.
    public var threads: [AgentThread]
    /// The currently selected project.
    public var selectedProjectID: UUID
    /// The currently selected thread, or `nil` when none is selected.
    public var selectedThreadID: UUID?
    /// The right-panel mode chosen per thread.
    public var rightPanelModesByThreadID: [UUID: RightPanelMode]
    /// The persisted right-panel state per thread.
    public var rightPanelStatesByThreadID: [UUID: RightPanelState]
    /// The right-panel mode to apply to threads with no per-thread choice.
    public var selectedRightPanelMode: RightPanelMode
    /// The set of threads whose bottom terminal is expanded.
    public var bottomTerminalExpandedThreadIDs: Set<UUID>
    /// The persisted window/pane layout state.
    public var layoutState: LayoutState
    /// The file-index metadata recorded per thread.
    public var fileIndexMetadataByThreadID: [UUID: FileIndexMetadata]
    /// The activity state recorded per thread.
    public var threadActivityByThreadID: [UUID: ThreadActivityState]
    /// The set of projects expanded in the project list.
    public var expandedProjectIDs: Set<UUID>
    /// The set of projects whose archived section is expanded.
    public var expandedArchivedProjectIDs: Set<UUID>

    /// Whether the selected thread's bottom terminal is expanded; setting it
    /// toggles membership in `bottomTerminalExpandedThreadIDs` for that thread.
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

    /// Creates a snapshot, backfilling default right-panel states for threads
    /// that have a mode but no explicit state and seeding the layout state from
    /// `isGlobalTerminalExpanded` when no `layoutState` is supplied.
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
            states[selectedThreadID] = RightPanelState.defaultState(
                selectedMode: selectedRightPanelMode)
        }
        self.rightPanelStatesByThreadID = states
        self.selectedRightPanelMode = selectedRightPanelMode
        self.bottomTerminalExpandedThreadIDs = bottomTerminalExpandedThreadIDs
        self.layoutState =
            layoutState ?? LayoutState(isGlobalTerminalExpanded: isGlobalTerminalExpanded)
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

/// A persisted file-index cache row: directory metadata plus its ordered entries.
public struct CachedFileIndex: Equatable, Sendable {
    /// The directory metadata (cache key, git identity, timestamps).
    public var metadata: FileIndexMetadata
    /// The ordered file-browser entries for the directory.
    public var entries: [FileBrowserEntry]

    /// Creates a cached file index from its metadata and entries.
    public init(metadata: FileIndexMetadata, entries: [FileBrowserEntry]) {
        self.metadata = metadata
        self.entries = entries
    }
}

/// Durable YAAW state behind an actor boundary. Every member is `async`: the
/// SQLite backing store is an `actor`, so all access is serialized and callers
/// `await`. Parameters are `Sendable` value types, so no `@unchecked Sendable`
/// escape is required to cross the boundary.
public protocol YAAWStore: AnyObject, Sendable {
    func load() async -> YAAWSnapshot
    func save(_ snapshot: YAAWSnapshot) async

    func upsertProject(_ project: Project) async
    func upsertThread(_ thread: AgentThread) async
    func deleteThread(id: UUID) async
    func setRightPanelMode(threadID: UUID, mode: RightPanelMode) async
    func setRightPanelState(threadID: UUID, state: RightPanelState) async
    func setBottomTerminalExpanded(threadID: UUID, isExpanded: Bool) async
    func setSelectedProject(_ projectID: UUID) async
    func setSelectedThread(_ threadID: UUID?) async
    func persistSelectionChange(
        selectedProjectID: UUID,
        selectedThreadID: UUID?,
        touchedProject: Project?,
        touchedThread: AgentThread?,
        expandedProjectID: UUID?
    ) async
    func setLayoutState(_ state: LayoutState) async
    func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) async
    func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool) async
    func upsertFileIndexMetadata(_ metadata: FileIndexMetadata) async
    func upsertThreadActivity(_ activity: ThreadActivityState) async
    func cachedFileIndex(cacheKey: String) async -> CachedFileIndex?
    func upsertCachedFileIndex(_ index: CachedFileIndex) async
}
