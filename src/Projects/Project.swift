import Foundation

public struct Project: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var rootDirectory: URL
    public var createdAt: Date
    public var lastOpenedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        rootDirectory: URL,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.rootDirectory = rootDirectory
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}
