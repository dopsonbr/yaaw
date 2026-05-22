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
    public static let defaultFallbackSearchPaths = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    private let fallbackSearchPaths: [String]

    public init(fallbackSearchPaths: [String] = Self.defaultFallbackSearchPaths) {
        self.fallbackSearchPaths = fallbackSearchPaths
    }

    public func executablePath(named executableName: String, environment: [String: String]) -> String? {
        if executableName.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executableName) {
            return executableName
        }

        let pathValue = environment["PATH"] ?? ""
        var searchedDirectories = Set<String>()
        let searchPaths = pathValue.split(separator: ":").map(String.init) + fallbackSearchPaths
        for directory in searchPaths where searchedDirectories.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executableName)
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
    public var startOffset: UInt64
    public var nextOffset: UInt64

    public init(output: String, nextOffset: UInt64, startOffset: UInt64 = 0) {
        self.output = output
        self.startOffset = startOffset
        self.nextOffset = nextOffset
    }
}

public final class AgentCLISessionBindingService: @unchecked Sendable {
    private let adaptersByKind: [AgentCLIKind: any AgentCLIAdapter]
    private let resolver: any AgentCLIExecutableResolving
    private let environment: [String: String]
    private let captureDirectory: URL?
    private let activityDirectory: URL?
    private let helperBinDirectory: URL

    public init(
        adapters: [any AgentCLIAdapter] = [
            CodexCLIAdapter(),
            ClaudeCLIAdapter(),
            OpenCodeCLIAdapter(),
            CopilotCLIAdapter()
        ],
        resolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        captureDirectory: URL? = AgentCLISessionBindingService.defaultCaptureDirectory(),
        activityDirectory: URL? = AgentCLISessionBindingService.defaultActivityDirectory(),
        helperBinDirectory: URL = AgentCLISessionBindingService.defaultHelperBinDirectory()
    ) {
        self.adaptersByKind = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) })
        self.resolver = resolver
        self.environment = environment
        self.captureDirectory = captureDirectory
        self.activityDirectory = activityDirectory
        self.helperBinDirectory = helperBinDirectory
    }

    public static func defaultCaptureDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("AgentCLICaptures", isDirectory: true)
    }

    public static func defaultActivityDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("AgentCLIEvents", isDirectory: true)
    }

    public static func defaultHelperBinDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("HelperBin", isDirectory: true)
    }

    public func terminalCommand(for thread: AgentThread, executableNameOverride: String? = nil) -> [String] {
        let command = invocation(for: thread, executableNameOverride: executableNameOverride).command
        guard let captureLogURL = captureLogURL(for: thread),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            return command
        }
        let helperBinURL = installNotifyHelperIfNeeded()
        let activityLogURL = activityLogURL(for: thread)
        try? FileManager.default.createDirectory(
            at: captureLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: captureLogURL)
        let shellPath = interactiveShellPath()
        let captureCommand = (["/usr/bin/script", "-q", captureLogURL.path] + command)
            .map(Self.shellQuoted)
            .joined(separator: " ")
        let environmentPrefix = shellEnvironmentPrefix(
            thread: thread,
            helperBinURL: helperBinURL,
            activityLogURL: activityLogURL
        )
        let shellCommand = "\(environmentPrefix)\(captureCommand); yaaw_exit_status=$?; if [ \"$yaaw_exit_status\" -ne 0 ]; then printf '\\nYAAW: agent command exited with status %s\\n' \"$yaaw_exit_status\"; fi; exec \(Self.shellQuoted(shellPath)) -l"
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

    public func activityLogURL(for thread: AgentThread) -> URL? {
        activityDirectory?.appendingPathComponent("\(thread.id.uuidString).ndjson")
    }

    private func shellEnvironmentPrefix(
        thread: AgentThread,
        helperBinURL: URL?,
        activityLogURL: URL?
    ) -> String {
        var assignments = [
            "export YAAW_THREAD_ID=\(Self.shellQuoted(thread.id.uuidString))",
            "export YAAW_PROJECT_ID=\(Self.shellQuoted(thread.projectID.uuidString))"
        ]
        if let activityLogURL {
            try? FileManager.default.createDirectory(
                at: activityLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            assignments.append("export YAAW_EVENT_LOG=\(Self.shellQuoted(activityLogURL.path))")
        }
        if let helperBinURL {
            assignments.append("export PATH=\(Self.shellQuoted(helperBinURL.path)):\u{0022}$PATH\u{0022}")
        }
        return assignments.joined(separator: "; ") + "; "
    }

    private func installNotifyHelperIfNeeded() -> URL? {
        let helperBinURL = helperBinDirectory
        let helperURL = helperBinURL.appendingPathComponent("yaaw-notify")
        do {
            try FileManager.default.createDirectory(at: helperBinURL, withIntermediateDirectories: true)
            try Self.notifyHelperScript.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
            return helperBinURL
        } catch {
            return nil
        }
    }

    private static let notifyHelperScript = """
    #!/bin/zsh
    set -e

    activity_status=""
    title=""
    body=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status)
          activity_status="$2"
          shift 2
          ;;
        --title)
          title="$2"
          shift 2
          ;;
        --body)
          body="$2"
          shift 2
          ;;
        *)
          if [[ -z "$body" ]]; then
            body="$1"
          else
            body="$body $1"
          fi
          shift
          ;;
      esac
    done

    case "$activity_status" in
      needs-input|needs_input) activity_status="needsInput" ;;
      working|complete|inactive) ;;
      "") activity_status="" ;;
      *) activity_status="" ;;
    esac

    json_escape() {
      local s="$1"
      s="${s//\\/\\\\}"
      s="${s//\\"/\\\\\\"}"
      s="${s//$'\\n'/\\\\n}"
      s="${s//$'\\r'/\\\\r}"
      s="${s//$'\\t'/\\\\t}"
      print -r -- "$s"
    }

    if [[ -n "$YAAW_EVENT_LOG" && -n "$YAAW_THREAD_ID" ]]; then
      mkdir -p "$(dirname "$YAAW_EVENT_LOG")"
      printf '{"thread_id":"%s","status":"%s","title":"%s","body":"%s","source":"helper","created_at":%s}\\n' \\
        "$(json_escape "$YAAW_THREAD_ID")" \\
        "$(json_escape "$activity_status")" \\
        "$(json_escape "$title")" \\
        "$(json_escape "$body")" \\
        "$(date +%s)" >> "$YAAW_EVENT_LOG"
    fi

    notification_title="${title:-YAAW}"
    notification_body="${body:-$activity_status}"
    printf '\\033]777;notify;%s;%s\\007' "$notification_title" "$notification_body"
    """

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
        guard let url = captureLogURL(for: thread) else {
            return nil
        }
        return capturedOutput(from: url, after: offset, maxBytes: maxBytes)
    }

    public func capturedActivityEvents(
        for thread: AgentThread,
        after offset: UInt64,
        maxBytes: Int = 64 * 1024
    ) -> AgentCLICapturedOutput? {
        guard let url = activityLogURL(for: thread) else {
            return nil
        }
        return capturedOutput(from: url, after: offset, maxBytes: maxBytes)
    }

    private func capturedOutput(
        from url: URL,
        after offset: UInt64,
        maxBytes: Int
    ) -> AgentCLICapturedOutput? {
        guard maxBytes > 0 else { return nil }
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        guard fileSize > offset else { return nil }

        let effectiveOffset: UInt64
        if fileSize - offset > Self.captureLogStaleWindow {
            let maxReadBytes = UInt64(maxBytes)
            effectiveOffset = fileSize > maxReadBytes ? fileSize - maxReadBytes : 0
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
            nextOffset: effectiveOffset + UInt64(data.count),
            startOffset: effectiveOffset
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
