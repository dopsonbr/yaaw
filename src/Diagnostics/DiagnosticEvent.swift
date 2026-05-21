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

    public init(subsystem: String = "dev.dopsonbr.YAAW") {
        self.subsystem = subsystem
    }

    public func record(_ event: DiagnosticEvent) {
        let logger = Logger(subsystem: subsystem, category: event.category)
        logger.info("\(event.name, privacy: .public) \(Self.render(event.metadata), privacy: .public)")
    }

    private static func render(_ metadata: [String: String]) -> String {
        metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}
