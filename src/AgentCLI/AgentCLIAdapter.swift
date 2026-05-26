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

public struct SessionLinkCandidate: Identifiable, Equatable, Sendable {
    public var identity: String
    public var displayName: String
    public var agentCLI: AgentCLIKind
    public var workingDirectory: URL?
    public var updatedAt: Date?
    public var source: String

    public init(
        identity: String,
        displayName: String,
        agentCLI: AgentCLIKind,
        workingDirectory: URL? = nil,
        updatedAt: Date? = nil,
        source: String
    ) {
        self.identity = identity
        self.displayName = displayName
        self.agentCLI = agentCLI
        self.workingDirectory = workingDirectory
        self.updatedAt = updatedAt
        self.source = source
    }

    public var id: String {
        "\(agentCLI.rawValue):\(identity)"
    }
}

public protocol AgentCLIAdapter: Sendable {
    var kind: AgentCLIKind { get }
    var executableName: String { get }
    var supportsStartName: Bool { get }
    var supportsInteractiveRename: Bool { get }

    func invocation(
        sessionIdentity: String?,
        requestedName: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation

    func startupInput(
        forPendingSessionRename name: String,
        sessionIdentity: String?
    ) -> String?

    func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata?

    func sessionLinkCandidates(
        workingDirectory: URL,
        homeDirectory: URL
    ) -> [SessionLinkCandidate]

    func metadataFromCatalog(
        sessionIdentity: String,
        workingDirectory: URL,
        homeDirectory: URL
    ) -> AgentCLISessionMetadata?
}

extension AgentCLIAdapter {
    public var supportsStartName: Bool { false }
    public var supportsInteractiveRename: Bool { false }

    public func startupInput(
        forPendingSessionRename name: String,
        sessionIdentity: String?
    ) -> String? {
        nil
    }

    public func sessionLinkCandidates(
        workingDirectory: URL,
        homeDirectory: URL
    ) -> [SessionLinkCandidate] {
        []
    }

    public func metadataFromCatalog(
        sessionIdentity: String,
        workingDirectory: URL,
        homeDirectory: URL
    ) -> AgentCLISessionMetadata? {
        sessionLinkCandidates(workingDirectory: workingDirectory, homeDirectory: homeDirectory)
            .first { $0.identity == sessionIdentity }
            .map { AgentCLISessionMetadata(identity: $0.identity, reportedName: $0.displayName) }
    }
}

public struct CodexCLIAdapter: AgentCLIAdapter {
    public let kind: AgentCLIKind = .codex
    public let executableName = "codex"

    public init() {}

    public func invocation(
        sessionIdentity: String?,
        requestedName: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation {
        return AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedExecutablePath,
            arguments: sessionIdentity.map { ["resume", $0] } ?? []
        )
    }

    public var supportsInteractiveRename: Bool { true }

    public func startupInput(
        forPendingSessionRename name: String,
        sessionIdentity: String?
    ) -> String? {
        Self.renameCommand(for: name)
    }

    public func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        AgentCLIOutputParser.metadata(from: output, terminalTitle: terminalTitle, kind: kind)
    }

    public func sessionLinkCandidates(
        workingDirectory: URL,
        homeDirectory: URL
    ) -> [SessionLinkCandidate] {
        AgentCLISessionCatalog.codexCandidates(
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory
        )
    }
}

public struct ClaudeCLIAdapter: AgentCLIAdapter {
    public let kind: AgentCLIKind = .claude
    public let executableName = "claude"

    public init() {}

    public func invocation(
        sessionIdentity: String?,
        requestedName: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation {
        let arguments: [String]
        if let sessionIdentity {
            arguments = ["--resume", sessionIdentity]
        } else if let requestedName = Self.sanitizedSessionName(requestedName) {
            arguments = ["--name", requestedName]
        } else {
            arguments = []
        }
        return AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedExecutablePath,
            arguments: arguments
        )
    }

    public var supportsStartName: Bool { true }
    public var supportsInteractiveRename: Bool { true }

    public func startupInput(
        forPendingSessionRename name: String,
        sessionIdentity: String?
    ) -> String? {
        sessionIdentity == nil ? nil : Self.renameCommand(for: name)
    }

    public func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        AgentCLIOutputParser.metadata(from: output, terminalTitle: terminalTitle, kind: kind)
    }

    public func sessionLinkCandidates(
        workingDirectory: URL,
        homeDirectory: URL
    ) -> [SessionLinkCandidate] {
        AgentCLISessionCatalog.claudeCandidates(
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory
        )
    }
}

public struct OpenCodeCLIAdapter: AgentCLIAdapter {
    public let kind: AgentCLIKind = .opencode
    public let executableName = "opencode"

    public init() {}

    public func invocation(
        sessionIdentity: String?,
        requestedName: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation {
        return AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedExecutablePath,
            arguments: sessionIdentity.map { ["--session", $0] } ?? []
        )
    }

    public func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        AgentCLIOutputParser.metadata(from: output, terminalTitle: terminalTitle, kind: kind)
    }

    public func sessionLinkCandidates(
        workingDirectory: URL,
        homeDirectory: URL
    ) -> [SessionLinkCandidate] {
        AgentCLISessionCatalog.openCodeCandidates(
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory
        )
    }
}

public struct CopilotCLIAdapter: AgentCLIAdapter {
    public let kind: AgentCLIKind = .copilot
    public let executableName = "copilot"

    public init() {}

    public func invocation(
        sessionIdentity: String?,
        requestedName: String?,
        resolvedExecutablePath: String?
    ) -> AgentCLIInvocation {
        let arguments: [String]
        if let sessionIdentity {
            arguments = ["--resume=\(sessionIdentity)"]
        } else if let requestedName = Self.sanitizedSessionName(requestedName) {
            arguments = ["--name", requestedName]
        } else {
            arguments = []
        }
        return AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedExecutablePath,
            arguments: arguments
        )
    }

    public var supportsStartName: Bool { true }
    public var supportsInteractiveRename: Bool { true }

    public func startupInput(
        forPendingSessionRename name: String,
        sessionIdentity: String?
    ) -> String? {
        sessionIdentity == nil ? nil : Self.renameCommand(for: name)
    }

    public func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        AgentCLIOutputParser.metadata(from: output, terminalTitle: terminalTitle, kind: kind)
    }

    public func sessionLinkCandidates(
        workingDirectory: URL,
        homeDirectory: URL
    ) -> [SessionLinkCandidate] {
        AgentCLISessionCatalog.copilotCandidates(
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory
        )
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
        "/sbin",
    ]

    private let fallbackSearchPaths: [String]

    public init(fallbackSearchPaths: [String] = Self.defaultFallbackSearchPaths) {
        self.fallbackSearchPaths = fallbackSearchPaths
    }

    public func executablePath(named executableName: String, environment: [String: String])
        -> String?
    {
        if executableName.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: executableName)
        {
            return executableName
        }

        let pathValue = environment["PATH"] ?? ""
        var searchedDirectories = Set<String>()
        let searchPaths = pathValue.split(separator: ":").map(String.init) + fallbackSearchPaths
        for directory in searchPaths where searchedDirectories.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
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
    private let homeDirectory: URL

    public init(
        adapters: [any AgentCLIAdapter] = [
            CodexCLIAdapter(),
            ClaudeCLIAdapter(),
            OpenCodeCLIAdapter(),
            CopilotCLIAdapter(),
        ],
        resolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        captureDirectory: URL? = AgentCLISessionBindingService.defaultCaptureDirectory(),
        activityDirectory: URL? = AgentCLISessionBindingService.defaultActivityDirectory(),
        helperBinDirectory: URL = AgentCLISessionBindingService.defaultHelperBinDirectory(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.adaptersByKind = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) })
        self.resolver = resolver
        self.environment = environment
        self.captureDirectory = captureDirectory
        self.activityDirectory = activityDirectory
        self.helperBinDirectory = helperBinDirectory
        self.homeDirectory = homeDirectory
    }

    public static func defaultCaptureDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("AgentCLICaptures", isDirectory: true)
    }

    public static func defaultActivityDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("AgentCLIEvents", isDirectory: true)
    }

    public static func defaultHelperBinDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("HelperBin", isDirectory: true)
    }

    public func terminalCommand(for thread: AgentThread, executableNameOverride: String? = nil)
        -> [String]
    {
        if captureLogURL(for: thread) == nil {
            return invocation(for: thread, executableNameOverride: executableNameOverride)
                .command
        }
        return terminalLaunchDescriptor(
            for: thread,
            executableNameOverride: executableNameOverride
        ).command
    }

    public func terminalLaunchDescriptor(
        for thread: AgentThread,
        executableNameOverride: String? = nil
    ) -> AgentTerminalLaunchDescriptor {
        let command = invocation(for: thread, executableNameOverride: executableNameOverride)
            .command
        let helperBinURL = installNotifyHelperIfNeeded()
        let activityLogURL = activityLogURL(for: thread)
        let captureLogURL = captureLogURL(for: thread)
        if let captureLogURL {
            try? FileManager.default.createDirectory(
                at: captureLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: captureLogURL)
        }
        let shellPath = interactiveShellPath()
        let agentCommand =
            command
            .map(Self.shellQuoted)
            .joined(separator: " ")
        let launchEnvironment = shellEnvironment(
            thread: thread,
            helperBinURL: helperBinURL,
            activityLogURL: activityLogURL
        )
        let shellCommand =
            "trap 'exit 143' TERM; trap 'exit 129' HUP; \(agentCommand); yaaw_exit_status=$?; if [ \"$yaaw_exit_status\" -ne 0 ]; then printf '\\nYAAW: agent command exited with status %s\\n' \"$yaaw_exit_status\"; fi; exec \(Self.shellQuoted(shellPath)) -l"
        return AgentTerminalLaunchDescriptor(
            command: [shellPath, "-lic", shellCommand],
            environment: launchEnvironment,
            captureLogURL: captureLogURL,
            startupInput: startupInput(for: thread)
        )
    }

    public func invocation(for thread: AgentThread, executableNameOverride: String? = nil)
        -> AgentCLIInvocation
    {
        guard let adapter = adaptersByKind[thread.agentCLI] else {
            let executableName = executableNameOverride ?? thread.agentCLI.rawValue
            return AgentCLIInvocation(
                executableName: executableName,
                resolvedExecutablePath: resolver.executablePath(
                    named: executableName, environment: environment),
                arguments: []
            )
        }
        let executableName = executableNameOverride ?? adapter.executableName
        let resolvedPath = resolver.executablePath(named: executableName, environment: environment)
        let invocation = adapter.invocation(
            sessionIdentity: thread.sessionIdentity,
            requestedName: thread.pendingSessionRename,
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

    public func supportsSessionRename(for kind: AgentCLIKind) -> Bool {
        adaptersByKind[kind]?.supportsInteractiveRename == true
    }

    public func canApplySessionNameOnLaunch(for kind: AgentCLIKind) -> Bool {
        guard let adapter = adaptersByKind[kind] else { return false }
        return adapter.supportsStartName || adapter.supportsInteractiveRename
    }

    public func sessionLinkCandidates(for thread: AgentThread) -> [SessionLinkCandidate] {
        adaptersByKind[thread.agentCLI]?.sessionLinkCandidates(
            workingDirectory: thread.workingDirectory,
            homeDirectory: homeDirectory
        ) ?? []
    }

    public func catalogMetadata(for thread: AgentThread) -> AgentCLISessionMetadata? {
        guard let sessionIdentity = thread.sessionIdentity else { return nil }
        return adaptersByKind[thread.agentCLI]?.metadataFromCatalog(
            sessionIdentity: sessionIdentity,
            workingDirectory: thread.workingDirectory,
            homeDirectory: homeDirectory
        )
    }

    public func exactSessionLinkCandidate(for thread: AgentThread) -> SessionLinkCandidate? {
        guard thread.sessionIdentity == nil else { return nil }
        let matchNames = Self.sessionLinkMatchNames(for: thread)
        guard !matchNames.isEmpty else { return nil }
        let matchingCandidates = sessionLinkCandidates(for: thread).filter { candidate in
            guard let candidateName = Self.normalizedSessionLinkName(candidate.displayName) else {
                return false
            }
            return matchNames.contains(candidateName)
        }
        guard !matchingCandidates.isEmpty else { return nil }

        let directoryMatches = matchingCandidates.filter { candidate in
            guard let directory = candidate.workingDirectory else { return false }
            return Self.sameDirectory(directory, thread.workingDirectory)
        }
        let candidates = directoryMatches.isEmpty ? matchingCandidates : directoryMatches
        let identities = Set(candidates.map(\.id))
        guard identities.count == 1 else { return nil }
        return candidates.first
    }

    public func captureLogURL(for thread: AgentThread) -> URL? {
        captureDirectory?.appendingPathComponent("\(thread.id.uuidString).log")
    }

    public func activityLogURL(for thread: AgentThread) -> URL? {
        activityDirectory?.appendingPathComponent("\(thread.id.uuidString).ndjson")
    }

    private func startupInput(for thread: AgentThread) -> String? {
        guard let pendingSessionRename = thread.pendingSessionRename,
            let adapter = adaptersByKind[thread.agentCLI]
        else { return nil }
        return adapter.startupInput(
            forPendingSessionRename: pendingSessionRename,
            sessionIdentity: thread.sessionIdentity
        )
    }

    private func shellEnvironment(
        thread: AgentThread,
        helperBinURL: URL?,
        activityLogURL: URL?
    ) -> [String: String] {
        var launchEnvironment = environment
        launchEnvironment["YAAW_THREAD_ID"] = thread.id.uuidString
        launchEnvironment["YAAW_PROJECT_ID"] = thread.projectID.uuidString
        if let activityLogURL {
            try? FileManager.default.createDirectory(
                at: activityLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            launchEnvironment["YAAW_EVENT_LOG"] = activityLogURL.path
        }
        if let helperBinURL {
            let path = launchEnvironment["PATH"] ?? ""
            launchEnvironment["PATH"] =
                path.isEmpty ? helperBinURL.path : "\(helperBinURL.path):\(path)"
        }
        if launchEnvironment["TERM"]?.nilIfBlank == nil {
            launchEnvironment["TERM"] = "xterm-256color"
        }
        if launchEnvironment["COLORTERM"]?.nilIfBlank == nil {
            launchEnvironment["COLORTERM"] = "truecolor"
        }
        launchEnvironment["TERM_PROGRAM"] = "YAAW"
        return launchEnvironment
    }

    private func installNotifyHelperIfNeeded() -> URL? {
        let helperBinURL = helperBinDirectory
        let helperURL = helperBinURL.appendingPathComponent("yaaw-notify")
        do {
            try FileManager.default.createDirectory(
                at: helperBinURL, withIntermediateDirectories: true)
            try Self.notifyHelperScript.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
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
            FileManager.default.isExecutableFile(atPath: shell)
        {
            return shell
        }
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            return "/bin/zsh"
        }
        return "/bin/bash"
    }

    private static func shellQuoted(_ argument: String) -> String {
        if argument.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.union(
                .init(charactersIn: "\"'\\$`;&|<>[]{}()!#*?~"))) == nil
        {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sessionLinkMatchNames(for thread: AgentThread) -> Set<String> {
        var names: [String] = []
        names.append(
            contentsOf: [
                thread.pendingSessionRename,
                thread.canonicalSessionName,
                thread.displayName,
            ].compactMap { $0 })
        return Set(names.compactMap(normalizedSessionLinkName))
    }

    private static func normalizedSessionLinkName(_ name: String?) -> String? {
        let collapsed = name?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed?.nilIfBlank
    }

    private static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
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
        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        guard fileSize > 0 else { return nil }

        let requestedOffset = offset > fileSize ? 0 : offset
        guard fileSize > requestedOffset else { return nil }
        let effectiveOffset: UInt64
        if fileSize - requestedOffset > Self.captureLogStaleWindow {
            let maxReadBytes = UInt64(maxBytes)
            effectiveOffset = fileSize > maxReadBytes ? fileSize - maxReadBytes : 0
        } else {
            effectiveOffset = requestedOffset
        }

        try? fileHandle.seek(toOffset: effectiveOffset)
        guard let data = try? fileHandle.read(upToCount: maxBytes),
            !data.isEmpty
        else {
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
        guard
            let executablePath = resolver.executablePath(
                named: adapter.executableName,
                environment: processEnvironment
            )
        else {
            throw AgentCLISessionBindingError.missingExecutable(adapter.executableName)
        }

        let invocation = adapter.invocation(
            sessionIdentity: resumeIdentity,
            requestedName: nil,
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

extension AgentCLIAdapter {
    fileprivate static func sanitizedSessionName(_ name: String?) -> String? {
        let singleLine = name?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let trimmed = singleLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    fileprivate static func renameCommand(for name: String) -> String? {
        guard let name = sanitizedSessionName(name) else { return nil }
        return "/rename \(name)\n"
    }
}

private enum AgentCLISessionCatalog {
    static func codexCandidates(
        homeDirectory: URL,
        workingDirectory: URL
    ) -> [SessionLinkCandidate] {
        let codexDirectory =
            homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
        let indexURL =
            codexDirectory
            .appendingPathComponent("session_index.jsonl")
        let indexCandidates: [SessionLinkCandidate] =
            jsonObjects(fromJSONL: indexURL).compactMap { object in
                guard
                    let identity = firstString(
                        in: object,
                        keys: ["session_id", "sessionId", "id", "conversation_id", "thread_id"]
                    )
                else { return nil }
                let directory = firstURL(
                    in: object,
                    keys: ["cwd", "working_directory", "workingDirectory", "directory", "path"]
                )
                guard matches(workingDirectory: workingDirectory, candidateDirectory: directory)
                else { return nil }
                let name =
                    firstString(
                        in: object,
                        keys: [
                            "thread_name", "session_name", "sessionName", "title", "name",
                            "summary",
                        ]
                    ) ?? identity
                return SessionLinkCandidate(
                    identity: identity,
                    displayName: name,
                    agentCLI: .codex,
                    workingDirectory: directory,
                    updatedAt: firstDate(
                        in: object,
                        keys: ["updated_at", "updatedAt", "timestamp", "created_at", "createdAt"]
                    ),
                    source: "~/.codex/session_index.jsonl"
                )
            }
        let indexedIdentities = Set(indexCandidates.map(\.identity))
        let historyURL = codexDirectory.appendingPathComponent("history.jsonl")
        let historyCandidates: [SessionLinkCandidate] =
            jsonObjects(fromJSONL: historyURL).compactMap { object in
                guard
                    let identity = firstString(
                        in: object,
                        keys: ["session_id", "sessionId", "id", "conversation_id", "thread_id"]
                    ),
                    !indexedIdentities.contains(identity)
                else { return nil }
                let name =
                    firstString(
                        in: object,
                        keys: [
                            "thread_name", "session_name", "sessionName", "title", "name",
                            "summary", "text",
                        ]
                    ) ?? identity
                return SessionLinkCandidate(
                    identity: identity,
                    displayName: name,
                    agentCLI: .codex,
                    updatedAt: firstDate(
                        in: object,
                        keys: [
                            "updated_at", "updatedAt", "timestamp", "created_at", "createdAt", "ts",
                        ]
                    ),
                    source: "~/.codex/history.jsonl"
                )
            }
        return merged(indexCandidates + historyCandidates)
    }

    static func claudeCandidates(
        homeDirectory: URL,
        workingDirectory: URL
    ) -> [SessionLinkCandidate] {
        let projectsDirectory =
            homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let directories = claudeProjectDirectories(
            root: projectsDirectory,
            workingDirectory: workingDirectory
        )
        let candidates = directories.flatMap { projectDirectory in
            enumeratedFiles(in: projectDirectory, extensions: ["jsonl"]).compactMap { fileURL in
                claudeCandidate(
                    from: fileURL,
                    workingDirectory: workingDirectory
                )
            }
        }
        return merged(candidates)
    }

    static func openCodeCandidates(
        homeDirectory: URL,
        workingDirectory: URL
    ) -> [SessionLinkCandidate] {
        let sessionsDirectory =
            homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
        return merged(
            enumeratedFiles(in: sessionsDirectory, extensions: ["json"]).compactMap { fileURL in
                guard let object = jsonObject(from: fileURL) else { return nil }
                let directory = firstURL(
                    in: object,
                    keys: ["directory", "cwd", "working_directory", "workingDirectory", "path"]
                )
                guard
                    matches(
                        workingDirectory: workingDirectory,
                        candidateDirectory: directory,
                        allowUnknownDirectory: false
                    )
                else { return nil }
                guard
                    let identity =
                        firstString(
                            in: object, keys: ["id", "sessionID", "sessionId", "session_id"])
                        ?? fileURL.deletingPathExtension().lastPathComponent.nilIfBlank
                else { return nil }
                let name =
                    firstString(in: object, keys: ["title", "name", "summary", "description"])
                    ?? identity
                return SessionLinkCandidate(
                    identity: identity,
                    displayName: name,
                    agentCLI: .opencode,
                    workingDirectory: directory,
                    updatedAt: firstDate(
                        in: object,
                        keys: ["updated", "updated_at", "updatedAt", "time", "created_at"]
                    ) ?? modificationDate(for: fileURL),
                    source: "~/.local/share/opencode/storage/session"
                )
            })
    }

    static func copilotCandidates(
        homeDirectory: URL,
        workingDirectory: URL
    ) -> [SessionLinkCandidate] {
        let stateDirectory =
            homeDirectory
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("session-state", isDirectory: true)
        guard let sessionDirectories = directoryChildren(of: stateDirectory) else {
            return []
        }
        return merged(
            sessionDirectories.compactMap { sessionDirectory in
                copilotCandidate(
                    from: sessionDirectory,
                    workingDirectory: workingDirectory
                )
            })
    }

    private static func claudeProjectDirectories(
        root: URL,
        workingDirectory: URL
    ) -> [URL] {
        let encoded = workingDirectory.path.replacingOccurrences(of: "/", with: "-")
        var directories: [URL] = []
        let direct = root.appendingPathComponent(encoded, isDirectory: true)
        if isDirectory(direct) {
            directories.append(direct)
        }
        if let children = directoryChildren(of: root) {
            for child in children
            where decodedClaudeDirectoryName(child.lastPathComponent) == workingDirectory.path
                && !directories.contains(child)
            {
                directories.append(child)
            }
        }
        return directories
    }

    private static func claudeCandidate(
        from fileURL: URL,
        workingDirectory: URL
    ) -> SessionLinkCandidate? {
        var identity = fileURL.deletingPathExtension().lastPathComponent.nilIfBlank
        var name: String?
        var directory: URL? = workingDirectory
        var updatedAt = modificationDate(for: fileURL)
        for object in jsonObjects(fromJSONL: fileURL) {
            identity =
                firstString(in: object, keys: ["sessionId", "session_id", "id", "uuid"])
                ?? identity
            name =
                firstString(
                    in: object,
                    keys: [
                        "agent-name", "agentName", "custom-title", "customTitle", "ai-title",
                        "aiTitle", "title", "name", "summary",
                    ]
                ) ?? name
            directory =
                firstURL(
                    in: object,
                    keys: ["cwd", "working_directory", "workingDirectory", "directory"]
                ) ?? directory
            updatedAt =
                firstDate(
                    in: object,
                    keys: ["timestamp", "updated_at", "updatedAt", "created_at", "createdAt"]
                ) ?? updatedAt
        }
        guard let identity else { return nil }
        guard matches(workingDirectory: workingDirectory, candidateDirectory: directory) else {
            return nil
        }
        return SessionLinkCandidate(
            identity: identity,
            displayName: name ?? identity,
            agentCLI: .claude,
            workingDirectory: directory,
            updatedAt: updatedAt,
            source: "~/.claude/projects"
        )
    }

    private static func copilotCandidate(
        from sessionDirectory: URL,
        workingDirectory: URL
    ) -> SessionLinkCandidate? {
        let metadataURL = sessionDirectory.appendingPathComponent("vscode.metadata.json")
        let metadataObject = jsonObject(from: metadataURL)
        var identity =
            metadataObject.flatMap {
                firstString(in: $0, keys: ["session_id", "sessionId", "id"])
            } ?? sessionDirectory.lastPathComponent.nilIfBlank
        var name = metadataObject.flatMap {
            firstString(in: $0, keys: ["name", "title", "sessionName", "session_name"])
        }
        var directory = metadataObject.flatMap {
            firstURL(
                in: $0,
                keys: ["cwd", "directory", "working_directory", "workingDirectory", "path"]
            )
        }
        var updatedAt =
            metadataObject.flatMap {
                firstDate(in: $0, keys: ["updated_at", "updatedAt", "timestamp", "created_at"])
            } ?? modificationDate(for: metadataURL)

        let eventsURL = sessionDirectory.appendingPathComponent("events.jsonl")
        for object in jsonObjects(fromJSONL: eventsURL) {
            identity =
                firstString(in: object, keys: ["session_id", "sessionId", "id"])
                ?? identity
            directory =
                firstURL(
                    in: object,
                    keys: ["cwd", "directory", "working_directory", "workingDirectory", "path"]
                ) ?? directory
            name =
                firstString(
                    in: object,
                    keys: [
                        "name", "title", "sessionName", "session_name", "firstUserMessage",
                        "first_user_message",
                    ]
                ) ?? name
            updatedAt =
                firstDate(in: object, keys: ["timestamp", "created_at", "createdAt", "time"])
                ?? updatedAt
        }
        guard let identity else { return nil }
        guard
            matches(
                workingDirectory: workingDirectory,
                candidateDirectory: directory,
                allowUnknownDirectory: false
            )
        else { return nil }
        return SessionLinkCandidate(
            identity: identity,
            displayName: name ?? identity,
            agentCLI: .copilot,
            workingDirectory: directory,
            updatedAt: updatedAt,
            source: "~/.copilot/session-state"
        )
    }

    private static func merged(_ candidates: [SessionLinkCandidate]) -> [SessionLinkCandidate] {
        var byIdentity: [String: SessionLinkCandidate] = [:]
        for candidate in candidates {
            guard !candidate.identity.isEmpty else { continue }
            guard let existing = byIdentity[candidate.identity] else {
                byIdentity[candidate.identity] = candidate
                continue
            }
            let candidateIsNewer =
                (candidate.updatedAt ?? .distantPast) > (existing.updatedAt ?? .distantPast)
            let existingUsesIdentity = existing.displayName == existing.identity
            if candidateIsNewer || existingUsesIdentity {
                byIdentity[candidate.identity] = candidate
            }
        }
        return byIdentity.values.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case (let lhsDate?, let rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.displayName.localizedStandardCompare(rhs.displayName)
                    == .orderedAscending
            }
        }
    }

    private static func matches(
        workingDirectory: URL,
        candidateDirectory: URL?,
        allowUnknownDirectory: Bool = true
    ) -> Bool {
        guard let candidateDirectory else { return allowUnknownDirectory }
        return candidateDirectory.standardizedFileURL.path
            == workingDirectory.standardizedFileURL.path
    }

    private static func decodedClaudeDirectoryName(_ name: String) -> String {
        guard name.hasPrefix("-") else { return name }
        return name.replacingOccurrences(of: "-", with: "/")
    }

    private static func directoryChildren(of directory: URL) -> [URL]? {
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return nil }
        return children.filter { isDirectory($0) }
    }

    private static func enumeratedFiles(in directory: URL, extensions: Set<String>) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }
        return files
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func jsonObject(from url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func jsonObjects(fromJSONL url: URL) -> [Any] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
    }

    private static func firstString(in object: Any, keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(in: object, key: key) {
                return value
            }
        }
        return nil
    }

    private static func stringValue(in object: Any, key: String) -> String? {
        if let dictionary = object as? [String: Any] {
            for (candidateKey, value) in dictionary
            where candidateKey.caseInsensitiveCompare(key) == .orderedSame {
                if let string = coercedString(value) {
                    return string
                }
            }
            for value in dictionary.values {
                if let nested = stringValue(in: value, key: key) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = stringValue(in: value, key: key) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func firstURL(in object: Any, keys: [String]) -> URL? {
        firstString(in: object, keys: keys).flatMap(urlFromPath)
    }

    private static func urlFromPath(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded =
            trimmed == "~" || trimmed.hasPrefix("~/")
            ? FileManager.default.homeDirectoryForCurrentUser.path
                + String(trimmed.dropFirst())
            : trimmed
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func firstDate(in object: Any, keys: [String]) -> Date? {
        for key in keys {
            if let date = dateValue(in: object, key: key) {
                return date
            }
        }
        return nil
    }

    private static func dateValue(in object: Any, key: String) -> Date? {
        if let dictionary = object as? [String: Any] {
            for (candidateKey, value) in dictionary
            where candidateKey.caseInsensitiveCompare(key) == .orderedSame {
                if let date = coercedDate(value) {
                    return date
                }
            }
            for value in dictionary.values {
                if let nested = dateValue(in: value, key: key) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = dateValue(in: value, key: key) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func coercedString(_ value: Any) -> String? {
        if let string = value as? String {
            return string.nilIfBlank
        }
        if let number = value as? NSNumber {
            return number.stringValue.nilIfBlank
        }
        return nil
    }

    private static func coercedDate(_ value: Any) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        guard let string = coercedString(value) else { return nil }
        if let numeric = Double(string) {
            return Date(
                timeIntervalSince1970: numeric > 1_000_000_000_000 ? numeric / 1000 : numeric)
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
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
            identity =
                identity
                ?? value(
                    in: line,
                    lowercased: lowercased,
                    prefixes: [
                        "yaaw_session_id=",
                        "session_id=",
                        "\(kind.rawValue)_session_id=",
                        "\(kind.rawValue) session id:",
                        "session id:",
                    ]
                )
            reportedName =
                reportedName
                ?? value(
                    in: line,
                    lowercased: lowercased,
                    prefixes: [
                        "yaaw_session_name=",
                        "session_name=",
                        "\(kind.rawValue)_session_name=",
                        "\(kind.rawValue) session name:",
                        "session name:",
                        "name:",
                    ]
                )
            title =
                title
                ?? value(
                    in: line,
                    lowercased: lowercased,
                    prefixes: [
                        "yaaw_session_title=",
                        "session_title=",
                        "\(kind.rawValue)_session_title=",
                        "\(kind.rawValue) session title:",
                        "session title:",
                        "title:",
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

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate var cleanedSessionField: String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    fileprivate var removingTerminalControls: String {
        String(
            unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            })
    }
}
