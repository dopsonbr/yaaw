import Foundation

public enum ThreadActivityStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case working
    case needsInput
    case complete
    case inactive

    public var cliValue: String {
        switch self {
        case .needsInput:
            return "needs-input"
        default:
            return rawValue
        }
    }

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

public enum ThreadActivitySource: String, Codable, Equatable, Sendable {
    case helper
    case terminalNotification
    case terminalLifecycle
}

public struct ThreadActivityState: Equatable, Sendable {
    public var threadID: UUID
    public var status: ThreadActivityStatus
    public var preview: String?
    public var isUnread: Bool
    public var title: String?
    public var body: String?
    public var source: ThreadActivitySource
    public var updatedAt: Date

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

    public func downgradedForLaunch() -> ThreadActivityState {
        guard status == .working else { return self }
        var copy = self
        copy.status = .inactive
        copy.isUnread = false
        return copy
    }
}

public struct ThreadActivityEvent: Equatable, Sendable {
    public var threadID: UUID
    public var status: ThreadActivityStatus?
    public var title: String?
    public var body: String?
    public var source: ThreadActivitySource
    public var createdAt: Date

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

public enum ThreadActivityText {
    public static let maximumPreviewLength = 240

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

    public static func preview(title: String?, body: String?) -> String? {
        sanitized(body) ?? sanitized(title)
    }

    public static func inferredStatus(title: String?, body: String?) -> ThreadActivityStatus? {
        let lowercased = [title, body]
            .compactMap { collapsedForSearch($0)?.lowercased() }
            .joined(separator: " ")
        return inferredStatus(fromSanitizedLowercased: lowercased)
    }

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

public enum ThreadRelativeTimeFormatter {
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

public struct ThreadActivityNotification: Equatable, Sendable {
    public var threadID: UUID
    public var title: String
    public var subtitle: String
    public var body: String

    public init(threadID: UUID, title: String, subtitle: String, body: String) {
        self.threadID = threadID
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

public protocol ThreadActivityNotificationDispatching: AnyObject, Sendable {
    func dispatch(_ notification: ThreadActivityNotification)
}

public protocol ThreadActivityBadgeUpdating: AnyObject, Sendable {
    func updateUnreadThreadActivityCount(_ count: Int)
}

public final class NoopThreadActivityNotificationDispatcher: ThreadActivityNotificationDispatching {
    public init() {}
    public func dispatch(_ notification: ThreadActivityNotification) {}
}

public final class NoopThreadActivityBadgeUpdater: ThreadActivityBadgeUpdating {
    public init() {}
    public func updateUnreadThreadActivityCount(_ count: Int) {}
}
