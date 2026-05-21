import Foundation
import OSLog

public struct DiagnosticEvent: Equatable, Sendable {
    public var category: String
    public var name: String
    public var metadata: [String: String]

    public init(category: String, name: String, metadata: [String: String] = [:]) {
        self.category = category
        self.name = name
        self.metadata = metadata
    }
}

public protocol DiagnosticEventRecording: AnyObject, Sendable {
    func record(_ event: DiagnosticEvent)
}

public final class LoggerDiagnosticEventRecorder: DiagnosticEventRecording, @unchecked Sendable {
    public static let shared = LoggerDiagnosticEventRecorder()

    private let subsystem: String
    private let queue = DispatchQueue(label: "dev.dopsonbr.YAAW.diagnostics", qos: .utility)
    private let cacheLock = NSLock()
    private var loggersByCategory: [String: Logger] = [:]

    public init(subsystem: String = "dev.dopsonbr.YAAW") {
        self.subsystem = subsystem
    }

    public func record(_ event: DiagnosticEvent) {
        let logger = self.logger(forCategory: event.category)
        let rendered = Self.render(event.metadata)
        let name = event.name
        queue.async {
            logger.info("\(name, privacy: .public) \(rendered, privacy: .public)")
        }
    }

    private func logger(forCategory category: String) -> Logger {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = loggersByCategory[category] {
            return cached
        }
        let logger = Logger(subsystem: subsystem, category: category)
        loggersByCategory[category] = logger
        return logger
    }

    private static func render(_ metadata: [String: String]) -> String {
        metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}
