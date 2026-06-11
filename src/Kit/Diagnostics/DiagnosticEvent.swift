import Foundation
import OSLog

/// A structured diagnostic event: a category, a stable name, and string metadata.
public struct DiagnosticEvent: Equatable, Sendable {
    /// Coarse area the event belongs to (e.g. `"Fonts"`, `"Persistence"`).
    public var category: String
    /// Stable, machine-greppable event name.
    public var name: String
    /// Free-form key/value context attached to the event.
    public var metadata: [String: String]

    /// Creates a diagnostic event.
    public init(category: String, name: String, metadata: [String: String] = [:]) {
        self.category = category
        self.name = name
        self.metadata = metadata
    }
}

/// A sink that records ``DiagnosticEvent`` values. Implementations are `Sendable`
/// so they can be shared across actors and the render-helper boundary.
public protocol DiagnosticEventRecording: AnyObject, Sendable {
    /// Records a single diagnostic event.
    func record(_ event: DiagnosticEvent)
}

/// Records diagnostic events to the unified logging system (`os.Logger`).
///
/// `os.Logger` is itself `Sendable` and thread-safe, and constructing one is
/// cheap, so this recorder holds only the immutable subsystem string and builds
/// a per-category `Logger` on each call. That makes the class trivially
/// `Sendable` — no lock, queue, or mutable cache, and therefore no
/// `@unchecked Sendable` escape hatch (rewrite tightened standards).
public final class LoggerDiagnosticEventRecorder: DiagnosticEventRecording {
    /// Shared recorder used as the default sink across the app.
    public static let shared = LoggerDiagnosticEventRecorder()

    private let subsystem: String

    /// Creates a recorder logging under `subsystem`.
    public init(subsystem: String = "dev.dopsonbr.YAAW") {
        self.subsystem = subsystem
    }

    /// Logs `event` to the unified logging system under its category.
    public func record(_ event: DiagnosticEvent) {
        let logger = Logger(subsystem: subsystem, category: event.category)
        let rendered = Self.render(event.metadata)
        logger.info("\(event.name, privacy: .public) \(rendered, privacy: .public)")
    }

    private static func render(_ metadata: [String: String]) -> String {
        metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}
