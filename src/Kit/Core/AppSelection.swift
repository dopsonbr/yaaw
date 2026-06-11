import Foundation

public struct AppSelection: Equatable, Sendable, Codable {
    public var projectID: UUID
    public var threadID: UUID?

    public init(projectID: UUID, threadID: UUID?) {
        self.projectID = projectID
        self.threadID = threadID
    }
}

public struct NavigationHistory: Equatable, Sendable {
    public private(set) var entries: [AppSelection]
    public private(set) var cursor: Int
    public let limit: Int

    public init(initial: AppSelection, limit: Int = 50) {
        self.entries = [initial]
        self.cursor = 0
        self.limit = limit
    }

    public var current: AppSelection {
        entries[cursor]
    }

    public var canGoBack: Bool {
        cursor > 0
    }

    public var canGoForward: Bool {
        cursor < entries.count - 1
    }

    public mutating func push(_ selection: AppSelection) {
        guard current != selection else { return }

        if canGoForward {
            entries.removeSubrange((cursor + 1)..<entries.count)
        }

        entries.append(selection)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        cursor = entries.count - 1
    }

    public mutating func goBack() -> AppSelection? {
        guard canGoBack else { return nil }
        cursor -= 1
        return current
    }

    public mutating func goForward() -> AppSelection? {
        guard canGoForward else { return nil }
        cursor += 1
        return current
    }
}
