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
        fileIndexMetadataByThreadID: [UUID: FileIndexMetadata] = [:]
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
    }
}

public protocol YAAWStore: AnyObject {
    func load() -> YAAWSnapshot
    func save(_ snapshot: YAAWSnapshot)
}

public final class InMemoryYAAWStore: YAAWStore {
    private var snapshot: YAAWSnapshot

    public init(snapshot: YAAWSnapshot) {
        self.snapshot = snapshot
    }

    public func load() -> YAAWSnapshot {
        snapshot
    }

    public func save(_ snapshot: YAAWSnapshot) {
        self.snapshot = snapshot
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
                isGlobalTerminalExpanded: false
            )
        )
    }
}
