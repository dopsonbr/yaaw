import Foundation

public struct AgentCLIOptionCatalog: Codable, Equatable, Sendable {
    public var entries: [AgentCLIOptionCatalogEntry]

    public init(entries: [AgentCLIOptionCatalogEntry]) {
        let byKind = Dictionary(uniqueKeysWithValues: entries.map { ($0.kind, $0) })
        self.entries = AgentCLIKind.allCases.map { kind in
            byKind[kind] ?? Self.fallbackEntry(for: kind)
        }
    }

    public static var fallback: AgentCLIOptionCatalog {
        AgentCLIOptionCatalog(entries: AgentCLIKind.allCases.map(fallbackEntry(for:)))
    }

    public func entry(for kind: AgentCLIKind) -> AgentCLIOptionCatalogEntry {
        entries.first { $0.kind == kind } ?? Self.fallbackEntry(for: kind)
    }

    public func permissionPresets(for kind: AgentCLIKind) -> [AgentPermissionMode] {
        entry(for: kind).permissionPresets
    }

    public static func fallbackEntry(for kind: AgentCLIKind) -> AgentCLIOptionCatalogEntry {
        AgentCLIOptionCatalogEntry(
            kind: kind,
            executablePath: nil,
            version: nil,
            helpHash: "fallback",
            capturedAt: nil,
            permissionPresets: AgentPermissionMode.builtInModes(for: kind),
            diagnostic: "Using built-in fallback presets."
        )
    }
}

public struct AgentCLIOptionCatalogEntry: Codable, Equatable, Sendable {
    public var kind: AgentCLIKind
    public var executablePath: String?
    public var version: String?
    public var helpHash: String?
    public var capturedAt: Date?
    public var permissionPresets: [AgentPermissionMode]
    public var diagnostic: String?

    public init(
        kind: AgentCLIKind,
        executablePath: String?,
        version: String?,
        helpHash: String?,
        capturedAt: Date?,
        permissionPresets: [AgentPermissionMode],
        diagnostic: String? = nil
    ) {
        self.kind = kind
        self.executablePath = executablePath
        self.version = version?.catalogNilIfBlank
        self.helpHash = helpHash?.catalogNilIfBlank
        self.capturedAt = capturedAt
        self.permissionPresets = permissionPresets
        self.diagnostic = diagnostic?.catalogNilIfBlank
    }
}

public protocol AgentCLIOptionCatalogServicing: Sendable {
    func loadCatalog() -> AgentCLIOptionCatalog
    func refreshCatalog(
        configuration: YAAWConfiguration,
        resolver: any AgentCLIExecutableResolving,
        environment: [String: String]
    ) -> AgentCLIOptionCatalog
}

public final class AgentCLIOptionCatalogService: AgentCLIOptionCatalogServicing,
    @unchecked Sendable
{
    private let cachePath: URL
    private let fileManager: FileManager
    private let diagnosticRecorder: DiagnosticEventRecording
    private let probeTimeoutSeconds: TimeInterval

    public init(
        cachePath: URL = AgentCLIOptionCatalogService.defaultCachePath(),
        fileManager: FileManager = .default,
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared,
        probeTimeoutSeconds: TimeInterval = 3
    ) {
        self.cachePath = cachePath
        self.fileManager = fileManager
        self.diagnosticRecorder = diagnosticRecorder
        self.probeTimeoutSeconds = probeTimeoutSeconds
    }

    public static func defaultCachePath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("AgentCLIOptions", isDirectory: true)
            .appendingPathComponent("catalog.json")
    }

    public func loadCatalog() -> AgentCLIOptionCatalog {
        guard fileManager.fileExists(atPath: cachePath.path) else {
            return .fallback
        }
        do {
            let data = try Data(contentsOf: cachePath)
            return try JSONDecoder().decode(AgentCLIOptionCatalog.self, from: data)
        } catch {
            recordFailure(kind: nil, source: "cache_load", error: error, fallback: "built_in")
            return .fallback
        }
    }

    public func refreshCatalog(
        configuration: YAAWConfiguration,
        resolver: any AgentCLIExecutableResolving,
        environment: [String: String]
    ) -> AgentCLIOptionCatalog {
        let cached = loadCatalog()
        let entries = AgentCLIKind.allCases.map { kind in
            do {
                return try probe(
                    kind: kind,
                    executableName: configuration.agentExecutableName(for: kind),
                    resolver: resolver,
                    environment: environment
                )
            } catch {
                if let cachedEntry = cached.entries.first(where: { $0.kind == kind }),
                    cachedEntry.helpHash != "fallback"
                {
                    recordFailure(kind: kind, source: "probe", error: error, fallback: "cache")
                    return cachedEntry
                }
                recordFailure(kind: kind, source: "probe", error: error, fallback: "built_in")
                return AgentCLIOptionCatalog.fallbackEntry(for: kind)
            }
        }
        let catalog = AgentCLIOptionCatalog(entries: entries)
        save(catalog)
        return catalog
    }

    private func probe(
        kind: AgentCLIKind,
        executableName: String,
        resolver: any AgentCLIExecutableResolving,
        environment: [String: String]
    ) throws -> AgentCLIOptionCatalogEntry {
        let executablePath =
            resolver.executablePath(named: executableName, environment: environment)
            ?? (executableName.contains("/") ? executableName : nil)
        guard let executablePath else {
            throw AgentCLIOptionCatalogError.missingExecutable(executableName)
        }

        let helpText = try captureOutput(
            executablePath: executablePath,
            arguments: ["--help"],
            environment: environment
        )
        let permissionPresets = AgentCLIOptionCatalogParser.permissionPresets(
            kind: kind,
            helpText: helpText
        )
        if permissionPresets.isEmpty, kind != .opencode {
            throw AgentCLIOptionCatalogError.unrecognizedHelp(kind.rawValue)
        }
        let version = try? captureOutput(
            executablePath: executablePath,
            arguments: ["--version"],
            environment: environment
        )
        return AgentCLIOptionCatalogEntry(
            kind: kind,
            executablePath: executablePath,
            version: version?.firstNonBlankLine,
            helpHash: Self.stableHash(helpText),
            capturedAt: Date(),
            permissionPresets: permissionPresets
        )
    }

    private func captureOutput(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()
        if semaphore.wait(timeout: .now() + probeTimeoutSeconds) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
            throw AgentCLIOptionCatalogError.timeout(executablePath)
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output =
            (String(data: outputData, encoding: .utf8) ?? "")
            + (String(data: errorData, encoding: .utf8) ?? "")
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentCLIOptionCatalogError.emptyOutput(executablePath)
        }
        return output
    }

    private func save(_ catalog: AgentCLIOptionCatalog) {
        do {
            try fileManager.createDirectory(
                at: cachePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(catalog)
            try data.write(to: cachePath, options: .atomic)
        } catch {
            recordFailure(kind: nil, source: "cache_save", error: error, fallback: "memory")
        }
    }

    private func recordFailure(
        kind: AgentCLIKind?,
        source: String,
        error: Error,
        fallback: String
    ) {
        var metadata = [
            "source": source,
            "fallback": fallback,
            "error": String(describing: error),
        ]
        if let kind {
            metadata["agent_cli"] = kind.rawValue
        }
        diagnosticRecorder.record(
            DiagnosticEvent(
                category: "AgentCLIOptions",
                name: "catalog_refresh_failed",
                metadata: metadata
            )
        )
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public enum AgentCLIOptionCatalogParser {
    public static func permissionPresets(
        kind: AgentCLIKind,
        helpText: String
    ) -> [AgentPermissionMode] {
        let lowercasedHelp = helpText.lowercased()
        switch kind {
        case .codex:
            return codexPresets(helpText: lowercasedHelp)
        case .claude:
            return lowercasedHelp.contains("--permission-mode")
                ? AgentPermissionMode.builtInModes(for: .claude)
                : []
        case .opencode:
            return []
        case .copilot:
            return copilotPresets(helpText: lowercasedHelp)
        }
    }

    private static func codexPresets(helpText: String) -> [AgentPermissionMode] {
        AgentPermissionMode.builtInModes(for: .codex).filter { mode in
            if mode.arguments.first == "--ask-for-approval" {
                return helpText.contains("--ask-for-approval")
            }
            if mode.arguments.first == "--sandbox" {
                return helpText.contains("--sandbox")
            }
            return mode.arguments.contains { helpText.contains($0.lowercased()) }
        }
    }

    private static func copilotPresets(helpText: String) -> [AgentPermissionMode] {
        AgentPermissionMode.builtInModes(for: .copilot).filter { mode in
            mode.arguments.contains { helpText.contains($0.lowercased()) }
        }
    }
}

public enum AgentCLIOptionCatalogError: Error, Equatable, Sendable {
    case missingExecutable(String)
    case timeout(String)
    case emptyOutput(String)
    case unrecognizedHelp(String)
}

extension String {
    fileprivate var firstNonBlankLine: String? {
        split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    fileprivate var catalogNilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
