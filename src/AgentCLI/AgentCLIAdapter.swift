import Foundation

public struct AgentCLIInvocation: Equatable, Sendable {
    public var executableName: String
    public var resolvedExecutablePath: String?
    public var arguments: [String]

    public init(
        executableName: String,
        resolvedExecutablePath: String?,
        arguments: [String]
    ) {
        self.executableName = executableName
        self.resolvedExecutablePath = resolvedExecutablePath
        self.arguments = arguments
    }

    public var command: [String] {
        [resolvedExecutablePath ?? executableName] + arguments
    }
}

public struct AgentCLISessionMetadata: Equatable, Sendable {
    public var identity: String
    public var reportedName: String?
    public var title: String?

    public init(identity: String, reportedName: String? = nil, title: String? = nil) {
        self.identity = identity
        self.reportedName = reportedName?.nilIfBlank
        self.title = title?.nilIfBlank
    }

    public var canonicalName: String {
        reportedName ?? title ?? identity
    }
}

public protocol AgentCLIAdapter: Sendable {
    var kind: AgentCLIKind { get }
    var executableName: String { get }

    func invocation(
        sessionIdentity: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation

    func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata?
}

public struct CodexCLIAdapter: AgentCLIAdapter {
    public let kind: AgentCLIKind = .codex
    public let executableName = "codex"

    public init() {}

    public func invocation(
        sessionIdentity: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation {
        AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedExecutablePath,
            arguments: sessionIdentity.map { ["resume", $0] } ?? []
        )
    }

    public func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        AgentCLIOutputParser.metadata(from: output, terminalTitle: terminalTitle, kind: kind)
    }
}

public struct ClaudeCLIAdapter: AgentCLIAdapter {
    public let kind: AgentCLIKind = .claude
    public let executableName = "claude"

    public init() {}

    public func invocation(
        sessionIdentity: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation {
        AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedExecutablePath,
            arguments: sessionIdentity.map { ["--resume", $0] } ?? []
        )
    }

    public func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        AgentCLIOutputParser.metadata(from: output, terminalTitle: terminalTitle, kind: kind)
    }
}

public struct OpenCodeCLIAdapter: AgentCLIAdapter {
    public let kind: AgentCLIKind = .opencode
    public let executableName = "opencode"

    public init() {}

    public func invocation(
        sessionIdentity: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation {
        AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedExecutablePath,
            arguments: sessionIdentity.map { ["--session", $0] } ?? []
        )
    }

    public func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        AgentCLIOutputParser.metadata(from: output, terminalTitle: terminalTitle, kind: kind)
    }
}

public struct CopilotCLIAdapter: AgentCLIAdapter {
    public let kind: AgentCLIKind = .copilot
    public let executableName = "copilot"

    public init() {}

    public func invocation(
        sessionIdentity: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation {
        AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedExecutablePath,
            arguments: sessionIdentity.map { ["--resume=\($0)"] } ?? []
        )
    }

    public func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        AgentCLIOutputParser.metadata(from: output, terminalTitle: terminalTitle, kind: kind)
    }
}

public protocol AgentCLIExecutableResolving: Sendable {
    func executablePath(named executableName: String, environment: [String: String]) -> String?
}

public struct PATHAgentCLIExecutableResolver: AgentCLIExecutableResolving {
    public init() {}

    public func executablePath(named executableName: String, environment: [String: String]) -> String? {
        let pathValue = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}

public enum AgentCLISessionBindingError: Error, Equatable {
    case missingAdapter(AgentCLIKind)
    case missingExecutable(String)
    case launchFailed(String)
    case metadataNotFound(String)
}

public struct AgentCLICapturedOutput: Equatable, Sendable {
    public var output: String
    public var nextOffset: UInt64

    public init(output: String, nextOffset: UInt64) {
        self.output = output
        self.nextOffset = nextOffset
    }
}

public final class AgentCLISessionBindingService: @unchecked Sendable {
    private let adaptersByKind: [AgentCLIKind: any AgentCLIAdapter]
    private let resolver: any AgentCLIExecutableResolving
    private let environment: [String: String]
    private let captureDirectory: URL?

    public init(
        adapters: [any AgentCLIAdapter] = [
            CodexCLIAdapter(),
            ClaudeCLIAdapter(),
            OpenCodeCLIAdapter(),
            CopilotCLIAdapter()
        ],
        resolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        captureDirectory: URL? = AgentCLISessionBindingService.defaultCaptureDirectory()
    ) {
        self.adaptersByKind = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) })
        self.resolver = resolver
        self.environment = environment
        self.captureDirectory = captureDirectory
    }

    public static func defaultCaptureDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("AgentCLICaptures", isDirectory: true)
    }

    public func terminalCommand(for thread: AgentThread, executableNameOverride: String? = nil) -> [String] {
        let command = invocation(for: thread, executableNameOverride: executableNameOverride).command
        guard let captureLogURL = captureLogURL(for: thread),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            return command
        }
        try? FileManager.default.createDirectory(
            at: captureLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: captureLogURL)
        let shellPath = interactiveShellPath()
        let captureCommand = (["/usr/bin/script", "-q", captureLogURL.path] + command)
            .map(Self.shellQuoted)
            .joined(separator: " ")
        let shellCommand = "\(captureCommand); yaaw_exit_status=$?; if [ \"$yaaw_exit_status\" -ne 0 ]; then printf '\\nYAAW: agent command exited with status %s\\n' \"$yaaw_exit_status\"; fi; exec \(Self.shellQuoted(shellPath)) -l"
        return [shellPath, "-lic", shellCommand]
    }

    public func invocation(for thread: AgentThread, executableNameOverride: String? = nil) -> AgentCLIInvocation {
        guard let adapter = adaptersByKind[thread.agentCLI] else {
            let executableName = executableNameOverride ?? thread.agentCLI.rawValue
            return AgentCLIInvocation(
                executableName: executableName,
                resolvedExecutablePath: resolver.executablePath(named: executableName, environment: environment),
                arguments: []
            )
        }
        let executableName = executableNameOverride ?? adapter.executableName
        let resolvedPath = resolver.executablePath(named: executableName, environment: environment)
        let invocation = adapter.invocation(
            sessionIdentity: thread.sessionIdentity,
            resolvedExecutablePath: resolvedPath
        )
        return AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: invocation.resolvedExecutablePath,
            arguments: invocation.arguments
        )
    }

    public func metadata(
        for kind: AgentCLIKind,
        output: String,
        terminalTitle: String? = nil
    ) -> AgentCLISessionMetadata? {
        adaptersByKind[kind]?.metadata(from: output, terminalTitle: terminalTitle)
    }

    public func metadata(
        fromExistingIdentity identity: String,
        terminalTitle: String
    ) -> AgentCLISessionMetadata {
        AgentCLISessionMetadata(identity: identity, title: terminalTitle)
    }

    public func captureLogURL(for thread: AgentThread) -> URL? {
        captureDirectory?.appendingPathComponent("\(thread.id.uuidString).log")
    }

    private func interactiveShellPath() -> String {
        if let shell = environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            return "/bin/zsh"
        }
        return "/bin/bash"
    }

    private static func shellQuoted(_ argument: String) -> String {
        if argument.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"'\\$`;&|<>[]{}()!#*?~"))) == nil {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static let captureLogStaleWindow: UInt64 = 8 * 1024 * 1024

    public func capturedOutput(
        for thread: AgentThread,
        after offset: UInt64,
        maxBytes: Int = 64 * 1024
    ) -> AgentCLICapturedOutput? {
        guard let url = captureLogURL(for: thread),
              let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        guard fileSize > offset else { return nil }

        let effectiveOffset: UInt64
        if fileSize - offset > Self.captureLogStaleWindow {
            effectiveOffset = fileSize - UInt64(maxBytes)
        } else {
            effectiveOffset = offset
        }

        try? fileHandle.seek(toOffset: effectiveOffset)
        guard let data = try? fileHandle.read(upToCount: maxBytes),
              !data.isEmpty else {
            return nil
        }
        return AgentCLICapturedOutput(
            output: String(decoding: data, as: UTF8.self),
            nextOffset: effectiveOffset + UInt64(data.count)
        )
    }

    public func captureMetadataByRunningCLI(
        kind: AgentCLIKind,
        resumeIdentity: String? = nil,
        workingDirectory: URL,
        environment overrideEnvironment: [String: String]? = nil
    ) throws -> AgentCLISessionMetadata {
        guard let adapter = adaptersByKind[kind] else {
            throw AgentCLISessionBindingError.missingAdapter(kind)
        }

        let processEnvironment = overrideEnvironment ?? environment
        guard let executablePath = resolver.executablePath(
            named: adapter.executableName,
            environment: processEnvironment
        ) else {
            throw AgentCLISessionBindingError.missingExecutable(adapter.executableName)
        }

        let invocation = adapter.invocation(
            sessionIdentity: resumeIdentity,
            resolvedExecutablePath: executablePath
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = processEnvironment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AgentCLISessionBindingError.launchFailed(String(describing: error))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard let metadata = adapter.metadata(from: output, terminalTitle: nil) else {
            throw AgentCLISessionBindingError.metadataNotFound(output)
        }
        return metadata
    }
}

private enum AgentCLIOutputParser {
    static func metadata(
        from output: String,
        terminalTitle: String?,
        kind: AgentCLIKind
    ) -> AgentCLISessionMetadata? {
        var identity: String?
        var reportedName: String?
        var title = terminalTitle?.nilIfBlank

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).removingTerminalControls
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = line.lowercased()
            identity = identity ?? value(
                in: line,
                lowercased: lowercased,
                prefixes: [
                    "yaaw_session_id=",
                    "session_id=",
                    "\(kind.rawValue)_session_id=",
                    "\(kind.rawValue) session id:",
                    "session id:"
                ]
            )
            reportedName = reportedName ?? value(
                in: line,
                lowercased: lowercased,
                prefixes: [
                    "yaaw_session_name=",
                    "session_name=",
                    "\(kind.rawValue)_session_name=",
                    "\(kind.rawValue) session name:",
                    "session name:",
                    "name:"
                ]
            )
            title = title ?? value(
                in: line,
                lowercased: lowercased,
                prefixes: [
                    "yaaw_session_title=",
                    "session_title=",
                    "\(kind.rawValue)_session_title=",
                    "\(kind.rawValue) session title:",
                    "session title:",
                    "title:"
                ]
            )
        }

        guard let identity = identity?.nilIfBlank else { return nil }
        return AgentCLISessionMetadata(
            identity: identity,
            reportedName: reportedName,
            title: title
        )
    }

    private static func value(
        in line: String,
        lowercased: String,
        prefixes: [String]
    ) -> String? {
        for prefix in prefixes where lowercased.hasPrefix(prefix) {
            let index = line.index(line.startIndex, offsetBy: prefix.count)
            return String(line[index...]).cleanedSessionField.nilIfBlank
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var cleanedSessionField: String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    var removingTerminalControls: String {
        String(unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        })
    }
}
