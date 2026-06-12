import Foundation

/// A named local directory the user has registered as a workspace for agent threads.
public struct Project: Identifiable, Equatable, Sendable {
    /// The stable unique identifier for the project.
    public let id: UUID
    /// The user-facing name shown for the project.
    public var displayName: String
    /// The local root directory the project is bound to.
    public var rootDirectory: URL
    /// The date the project was first created.
    public var createdAt: Date
    /// The date the project was most recently opened.
    public var lastOpenedAt: Date
    /// Whether the project is pinned to the top of the project list.
    public var isPinned: Bool
    /// The position of the project within its sort group.
    public var sortOrder: Int
    /// Whether the project has been archived and hidden from the active list.
    public var isArchived: Bool

    /// Creates a project with the given metadata, defaulting timestamps to now.
    public init(
        id: UUID = UUID(),
        displayName: String,
        rootDirectory: URL,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        isPinned: Bool = false,
        sortOrder: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.rootDirectory = rootDirectory
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.isPinned = isPinned
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }
}

/// The direction to move a project when reordering the project list.
public enum ProjectMoveDirection: Sendable {
    /// Move the project earlier in the list.
    case up
    /// Move the project later in the list.
    case down
}
