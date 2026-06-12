import Foundation

/// The activity state of a thread's agent session, as surfaced in the sidebar.
public enum ThreadActivityStatus: String, Codable, CaseIterable, Equatable, Sendable {
    /// The agent is actively working on a task.
    case working
    /// The agent is paused waiting for user input or approval.
    case needsInput
    /// The agent has finished its task.
    case complete
    /// The thread has no active agent session.
    case inactive

    /// The status as the CLI/helper protocol spells it (e.g. `needs-input`).
    public var cliValue: String {
        switch self {
        case .needsInput:
            return "needs-input"
        default:
            return rawValue
        }
    }

    /// Parses a status from a CLI/helper string, tolerating common spelling
    /// variants (e.g. `needs-input`, `completed`, `idle`); returns `nil` if
    /// unrecognized.
    public static func parse(_ value: String?) -> ThreadActivityStatus? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "working":
            return .working
        case "needsInput", "needs-input", "needs_input":
            return .needsInput
        case "complete", "completed":
            return .complete
        case "inactive", "idle":
            return .inactive
        default:
            return nil
        }
    }
}

/// Where a thread-activity update originated.
public enum ThreadActivitySource: String, Codable, Equatable, Sendable {
    /// Reported by the agent helper process.
    case helper
    /// Derived from a terminal notification (e.g. an OSC notification).
    case terminalNotification
    /// Inferred from terminal lifecycle events (e.g. process start/exit).
    case terminalLifecycle
}

/// The durable per-thread activity record shown in the sidebar.
public struct ThreadActivityState: Equatable, Sendable {
    /// The thread this state describes.
    public var threadID: UUID
    /// The thread's current activity status.
    public var status: ThreadActivityStatus
    /// A short sanitized preview of the latest activity, if any.
    public var preview: String?
    /// Whether the thread has unread activity.
    public var isUnread: Bool
    /// The latest activity title, if any.
    public var title: String?
    /// The latest activity body, if any.
    public var body: String?
    /// The source of the most recent update.
    public var source: ThreadActivitySource
    /// When this state was last updated.
    public var updatedAt: Date

    /// Creates an activity state, sanitizing `preview`, `title`, and `body`.
    public init(
        threadID: UUID,
        status: ThreadActivityStatus = .inactive,
        preview: String? = nil,
        isUnread: Bool = false,
        title: String? = nil,
        body: String? = nil,
        source: ThreadActivitySource = .terminalLifecycle,
        updatedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.status = status
        self.preview = ThreadActivityText.sanitized(preview)
        self.isUnread = isUnread
        self.title = ThreadActivityText.sanitized(title)
        self.body = ThreadActivityText.sanitized(body)
        self.source = source
        self.updatedAt = updatedAt
    }

    /// Returns a copy with a `working` status reset to `inactive` (and cleared
    /// unread flag), used when relaunching a thread so a stale "working" state
    /// does not persist. Other statuses are returned unchanged.
    public func downgradedForLaunch() -> ThreadActivityState {
        guard status == .working else { return self }
        var copy = self
        copy.status = .inactive
        copy.isUnread = false
        return copy
    }
}

/// A single incoming activity update for a thread, before it is folded into the
/// durable ``ThreadActivityState``.
public struct ThreadActivityEvent: Equatable, Sendable {
    /// The thread this event targets.
    public var threadID: UUID
    /// The status reported by the event, if any.
    public var status: ThreadActivityStatus?
    /// The event title, if any.
    public var title: String?
    /// The event body, if any.
    public var body: String?
    /// The source that produced the event.
    public var source: ThreadActivitySource
    /// When the event was created.
    public var createdAt: Date

    /// Creates an event, sanitizing `title` and `body`.
    public init(
        threadID: UUID,
        status: ThreadActivityStatus?,
        title: String?,
        body: String?,
        source: ThreadActivitySource,
        createdAt: Date = Date()
    ) {
        self.threadID = threadID
        self.status = status
        self.title = ThreadActivityText.sanitized(title)
        self.body = ThreadActivityText.sanitized(body)
        self.source = source
        self.createdAt = createdAt
    }

    /// Parses newline-delimited JSON helper output into events, skipping any line
    /// that is not a valid event object with a parseable `thread_id`.
    public static func helperEvents(from output: String) -> [ThreadActivityEvent] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let threadIDValue = object["thread_id"] as? String,
                let threadID = UUID(uuidString: threadIDValue)
            else {
                return nil
            }
            let createdAt =
                (object["created_at"] as? TimeInterval).map {
                    Date(timeIntervalSince1970: $0)
                } ?? Date()
            return ThreadActivityEvent(
                threadID: threadID,
                status: ThreadActivityStatus.parse(object["status"] as? String),
                title: object["title"] as? String,
                body: object["body"] as? String,
                source: ThreadActivitySource(rawValue: object["source"] as? String ?? "")
                    ?? .helper,
                createdAt: createdAt
            )
        }
    }
}

/// Text helpers for normalizing agent activity text: stripping ANSI/terminal
/// escapes, collapsing whitespace, truncating previews, and inferring status.
public enum ThreadActivityText {
    /// The maximum length of a sanitized preview string, in characters.
    public static let maximumPreviewLength = 240

    /// Returns `text` with terminal escapes removed and whitespace collapsed,
    /// truncated to ``maximumPreviewLength``; `nil` if the result is empty.
    public static func sanitized(_ text: String?) -> String? {
        guard let collapsed = collapsedForSearch(text) else { return nil }
        if collapsed.count <= maximumPreviewLength {
            return collapsed
        }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maximumPreviewLength)
        return String(collapsed[..<end])
    }

    private static func collapsedForSearch(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed =
            text
            .replacingOccurrences(
                of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression
            )
            .replacingOccurrences(
                of: "\u{001B}[@-Z\\-_]", with: "", options: .regularExpression
            )
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    /// Returns a sanitized preview, preferring `body` over `title`.
    public static func preview(title: String?, body: String?) -> String? {
        sanitized(body) ?? sanitized(title)
    }

    /// Infers an activity status from the combined `title` and `body` text using
    /// keyword heuristics; `nil` if no status can be inferred.
    public static func inferredStatus(title: String?, body: String?) -> ThreadActivityStatus? {
        let lowercased = [title, body]
            .compactMap { collapsedForSearch($0)?.lowercased() }
            .joined(separator: " ")
        return inferredStatus(fromSanitizedLowercased: lowercased)
    }

    /// Infers an activity status from raw terminal output using keyword
    /// heuristics; `nil` if no status can be inferred.
    public static func inferredStatus(fromTerminalOutput output: String) -> ThreadActivityStatus? {
        guard let lowercased = collapsedForSearch(output)?.lowercased() else { return nil }
        return inferredStatus(fromSanitizedLowercased: lowercased)
    }

    private static func inferredStatus(
        fromSanitizedLowercased lowercased: String
    ) -> ThreadActivityStatus? {
        if lowercased.contains("needs input")
            || lowercased.contains("waiting for input")
            || lowercased.contains("waiting for your input")
            || lowercased.contains("requires input")
            || lowercased.contains("approval needed")
            || lowercased.contains("awaiting approval")
        {
            return .needsInput
        }
        if lowercased.contains("use /skills to list available skills")
            || lowercased.contains("worked for ")
        {
            return .complete
        }
        if lowercased.contains("thinking")
            || lowercased.contains("almost done thinking")
            || lowercased.contains("plan mode on")
            || lowercased.contains("esc to interrupt")
        {
            return .working
        }
        if lowercased.contains("complete")
            || lowercased.contains("completed")
            || lowercased.contains("finished")
            || lowercased.contains("done")
        {
            return .complete
        }
        return nil
    }
}

/// Formats elapsed time as a compact relative string for the sidebar.
public enum ThreadRelativeTimeFormatter {
    /// Returns a compact elapsed-time string (e.g. `5m`, `2h`, `3d`, `1w`)
    /// between `date` and `now`, clamped to a minimum of one minute.
    public static func shortElapsed(since date: Date, now: Date = Date()) -> String {
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(date)))
        let elapsedMinutes = max(1, elapsedSeconds / 60)
        if elapsedMinutes < 60 {
            return "\(elapsedMinutes)m"
        }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 {
            return "\(elapsedHours)h"
        }

        let elapsedDays = elapsedHours / 24
        if elapsedDays < 7 {
            return "\(elapsedDays)d"
        }

        return "\(max(1, elapsedDays / 7))w"
    }
}

/// A user-facing notification describing thread activity, ready to be dispatched
/// to the system notification center.
public struct ThreadActivityNotification: Equatable, Sendable {
    /// The thread the notification is about.
    public var threadID: UUID
    /// The notification title.
    public var title: String
    /// The notification subtitle.
    public var subtitle: String
    /// The notification body text.
    public var body: String

    /// Creates a notification with the given fields.
    public init(threadID: UUID, title: String, subtitle: String, body: String) {
        self.threadID = threadID
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

/// Dispatches thread-activity notifications to the user.
public protocol ThreadActivityNotificationDispatching: AnyObject, Sendable {
    /// Dispatches `notification` to the user.
    func dispatch(_ notification: ThreadActivityNotification)
}

/// Updates the app's unread thread-activity badge count.
public protocol ThreadActivityBadgeUpdating: AnyObject, Sendable {
    /// Sets the displayed unread thread-activity count.
    func updateUnreadThreadActivityCount(_ count: Int)
}

/// A no-op dispatcher that discards notifications, for tests and headless runs.
public final class NoopThreadActivityNotificationDispatcher: ThreadActivityNotificationDispatching {
    /// Creates a no-op dispatcher.
    public init() {}
    /// Discards `notification`.
    public func dispatch(_ notification: ThreadActivityNotification) {}
}

/// A no-op badge updater that ignores count changes, for tests and headless runs.
public final class NoopThreadActivityBadgeUpdater: ThreadActivityBadgeUpdating {
    /// Creates a no-op badge updater.
    public init() {}
    /// Ignores the count change.
    public func updateUnreadThreadActivityCount(_ count: Int) {}
}
