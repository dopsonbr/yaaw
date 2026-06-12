import Foundation

/// A navigable selection of a project and an optional thread within it.
public struct AppSelection: Equatable, Sendable, Codable {
    /// The selected project.
    public var projectID: UUID
    /// The selected thread within the project, or `nil` if none is selected.
    public var threadID: UUID?

    /// Creates a selection of the given project and optional thread.
    public init(projectID: UUID, threadID: UUID?) {
        self.projectID = projectID
        self.threadID = threadID
    }
}

/// A bounded back/forward history of `AppSelection`s with a movable cursor.
public struct NavigationHistory: Equatable, Sendable {
    /// The recorded selections, oldest first.
    public private(set) var entries: [AppSelection]
    /// The index into `entries` of the current selection.
    public private(set) var cursor: Int
    /// The maximum number of entries retained; older entries are dropped.
    public let limit: Int

    /// Creates a history seeded with an initial selection and a retention limit.
    public init(initial: AppSelection, limit: Int = 50) {
        self.entries = [initial]
        self.cursor = 0
        self.limit = limit
    }

    /// The selection at the current cursor position.
    public var current: AppSelection {
        entries[cursor]
    }

    /// Whether there is an earlier selection to navigate back to.
    public var canGoBack: Bool {
        cursor > 0
    }

    /// Whether there is a later selection to navigate forward to.
    public var canGoForward: Bool {
        cursor < entries.count - 1
    }

    /// Records a new selection at the cursor, discarding any forward history and
    /// trimming the oldest entries to stay within `limit`. No-op if it equals the
    /// current selection.
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

    /// Moves the cursor back one step and returns the now-current selection, or
    /// `nil` if already at the oldest entry.
    public mutating func goBack() -> AppSelection? {
        guard canGoBack else { return nil }
        cursor -= 1
        return current
    }

    /// Moves the cursor forward one step and returns the now-current selection,
    /// or `nil` if already at the newest entry.
    public mutating func goForward() -> AppSelection? {
        guard canGoForward else { return nil }
        cursor += 1
        return current
    }
}
