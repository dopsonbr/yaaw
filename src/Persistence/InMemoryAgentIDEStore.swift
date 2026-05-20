import Foundation

public struct AgentIDESnapshot: Equatable, Sendable {
    public var projects: [Project]
    public var threads: [AgentThread]
    public var selectedRightPanelMode: RightPanelMode
    public var isGlobalTerminalExpanded: Bool

    public init(
        projects: [Project],
        threads: [AgentThread],
        selectedRightPanelMode: RightPanelMode,
        isGlobalTerminalExpanded: Bool
    ) {
        self.projects = projects
        self.threads = threads
        self.selectedRightPanelMode = selectedRightPanelMode
        self.isGlobalTerminalExpanded = isGlobalTerminalExpanded
    }
}

public final class InMemoryAgentIDEStore {
    private var snapshot: AgentIDESnapshot

    public init(snapshot: AgentIDESnapshot) {
        self.snapshot = snapshot
    }

    public func load() -> AgentIDESnapshot {
        snapshot
    }

    public func save(_ snapshot: AgentIDESnapshot) {
        self.snapshot = snapshot
    }

    public static func helloWorld() -> InMemoryAgentIDEStore {
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

        return InMemoryAgentIDEStore(
            snapshot: AgentIDESnapshot(
                projects: [project],
                threads: [thread],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
    }
}
