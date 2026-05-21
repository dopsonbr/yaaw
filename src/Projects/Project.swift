import Foundation

public struct Project: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var rootDirectory: URL
    public var createdAt: Date
    public var lastOpenedAt: Date
    public var isPinned: Bool
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        rootDirectory: URL,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        isPinned: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.rootDirectory = rootDirectory
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.isPinned = isPinned
        self.sortOrder = sortOrder
    }
}

public enum ProjectMoveDirection: Sendable {
    case up
    case down
}
