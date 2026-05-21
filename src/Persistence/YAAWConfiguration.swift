import Foundation
import OSLog

public struct YAAWConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var theme: String
    public var ignoreRules: [String]

    public init(
        version: Int = 1,
        theme: String = "Dracula",
        ignoreRules: [String] = Self.defaultIgnoreRules
    ) {
        self.version = version
        self.theme = theme
        self.ignoreRules = ignoreRules
    }

    public static let defaultIgnoreRules = [
        ".git",
        "node_modules",
        "dist",
        ".build",
        "DerivedData"
    ]
}

public final class JSONConfigurationStore {
    private let path: URL
    private let logger = Logger(subsystem: "dev.dopsonbr.YAAW", category: "Configuration")

    public init(path: URL) {
        self.path = path
    }

    public static func defaultPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public func load() -> YAAWConfiguration {
        do {
            guard FileManager.default.fileExists(atPath: path.path) else {
                let configuration = YAAWConfiguration()
                try save(configuration)
                return configuration
            }
            let data = try Data(contentsOf: path)
            let configuration = try JSONDecoder().decode(YAAWConfiguration.self, from: data)
            guard configuration.theme == "Dracula", !configuration.ignoreRules.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Invalid configuration values")
                )
            }
            return configuration
        } catch {
            logger.error("Recovering malformed configuration: \(String(describing: error), privacy: .public)")
            let configuration = YAAWConfiguration()
            try? save(configuration)
            return configuration
        }
    }

    public func save(_ configuration: YAAWConfiguration) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.pretty.encode(configuration)
        let temporaryPath = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporaryPath, options: .atomic)
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: temporaryPath)
        } else {
            try FileManager.default.moveItem(at: temporaryPath, to: path)
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
