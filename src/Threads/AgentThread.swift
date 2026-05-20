import Foundation

public struct AgentThread: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var projectID: UUID
    public var workingDirectory: URL
    public var createdAt: Date
    public var lastOpenedAt: Date
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        projectID: UUID,
        workingDirectory: URL,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.isArchived = isArchived
    }
}
