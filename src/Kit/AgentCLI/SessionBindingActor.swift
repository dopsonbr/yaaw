import Foundation

/// Cache key for catalog candidates: a CLI family scoped to a working directory.
struct SessionCatalogCacheKey: Hashable, Sendable {
    var kind: AgentCLIKind
    var workingDirectoryPath: String
}

/// Cached catalog candidates plus the signature they were read at.
struct SessionCatalogCacheEntry: Sendable {
    var signature: String
    var candidates: [SessionLinkCandidate]
}

/// Interprets declarative ``CLIManifest`` records to bind threads to agent CLI
/// sessions: command construction, catalog scanning, exact linking, output and
/// catalog metadata extraction, and capture/activity log reading.
///
/// All public methods are `async`; the catalog cache is actor-private state, so
/// there is no lock and no `@unchecked Sendable` escape (the legacy service was
/// `@unchecked Sendable` with an `NSLock`-guarded cache).
public actor SessionBindingActor {
    let manifestsByKind: [AgentCLIKind: CLIManifest]
    let resolver: any AgentCLIExecutableResolving
    let environment: [String: String]
    let captureDirectory: URL?
    let activityDirectory: URL?
    let helperBinDirectory: URL
    let homeDirectory: URL
    let diagnosticRecorder: any DiagnosticEventRecording

    static let catalogCacheLimit = 64
    var catalogCacheByKey: [SessionCatalogCacheKey: SessionCatalogCacheEntry] = [:]
    var catalogCacheInsertionOrder: [SessionCatalogCacheKey] = []

    /// The maximum capture-log lookback window before an offset is clamped.
    public static let captureLogStaleWindow: UInt64 = 8 * 1024 * 1024

    /// Creates a session-binding actor.
    ///
    /// Defaults install the four built-in manifests, a `PATH`-based resolver, and
    /// the standard Application Support capture/activity/helper directories.
    public init(
        manifests: [AgentCLIKind: CLIManifest] = CLIManifest.builtIns,
        resolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        captureDirectory: URL? = SessionBindingActor.defaultCaptureDirectory(),
        activityDirectory: URL? = SessionBindingActor.defaultActivityDirectory(),
        helperBinDirectory: URL = SessionBindingActor.defaultHelperBinDirectory(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        diagnosticRecorder: any DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared
    ) {
        self.manifestsByKind = manifests
        self.resolver = resolver
        self.environment = environment
        self.captureDirectory = captureDirectory
        self.activityDirectory = activityDirectory
        self.helperBinDirectory = helperBinDirectory
        self.homeDirectory = homeDirectory
        self.diagnosticRecorder = diagnosticRecorder
    }

    /// The default capture-log directory under Application Support.
    public static func defaultCaptureDirectory() -> URL {
        applicationSupportYAAW().appendingPathComponent("AgentCLICaptures", isDirectory: true)
    }

    /// The default activity-log directory under Application Support.
    public static func defaultActivityDirectory() -> URL {
        applicationSupportYAAW().appendingPathComponent("AgentCLIEvents", isDirectory: true)
    }

    /// The default helper-bin directory under Application Support.
    public static func defaultHelperBinDirectory() -> URL {
        applicationSupportYAAW().appendingPathComponent("HelperBin", isDirectory: true)
    }

    private static func applicationSupportYAAW() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
    }

    // MARK: - Capabilities

    /// Whether the CLI supports interactive `/rename`.
    public func supportsSessionRename(for kind: AgentCLIKind) -> Bool {
        manifestsByKind[kind]?.supportsInteractiveRename == true
    }

    /// Whether a session name can be applied at launch (start-name or rename).
    public func canApplySessionNameOnLaunch(for kind: AgentCLIKind) -> Bool {
        guard let manifest = manifestsByKind[kind] else { return false }
        return manifest.supportsStartName || manifest.supportsInteractiveRename
    }

    /// Whether the terminal title is a trustworthy session-name source.
    public func usesTerminalTitleAsSessionName(for kind: AgentCLIKind) -> Bool {
        manifestsByKind[kind]?.usesTerminalTitleAsSessionName ?? true
    }

    // MARK: - Command construction

    /// The command to launch a thread's terminal: a bare invocation when no
    /// capture is configured, otherwise the capture-wrapped shell command.
    public func terminalCommand(
        for thread: AgentThread,
        executableNameOverride: String? = nil,
        permissionModes: [AgentPermissionMode]? = nil
    ) -> [String] {
        if captureLogURL(for: thread) == nil {
            return invocation(
                for: thread,
                executableNameOverride: executableNameOverride,
                permissionModes: permissionModes
            ).command
        }
        return terminalLaunchDescriptor(
            for: thread,
            executableNameOverride: executableNameOverride,
            permissionModes: permissionModes
        ).command
    }

    /// The fully-resolved invocation for a thread, with permission and additional
    /// arguments prepended before the manifest's resume/start-name arguments.
    public func invocation(
        for thread: AgentThread,
        executableNameOverride: String? = nil,
        permissionModes: [AgentPermissionMode]? = nil
    ) -> AgentCLIInvocation {
        let validated = thread.launchOptions.validated(
            for: thread.agentCLI,
            permissionModes: permissionModes
        )
        recordUnsupportedPermissionModeIfNeeded(
            thread: thread,
            validated: validated,
            permissionModes: permissionModes
        )
        let resolvedOverride = validated.executableName ?? executableNameOverride
        let permissionAndAdditional =
            validated.permissionArguments(for: thread.agentCLI, permissionModes: permissionModes)
            + validated.additionalArguments

        guard let manifest = manifestsByKind[thread.agentCLI] else {
            let executableName = resolvedOverride ?? thread.agentCLI.rawValue
            return AgentCLIInvocation(
                executableName: executableName,
                resolvedExecutablePath: resolver.executablePath(
                    named: executableName, environment: environment),
                arguments: permissionAndAdditional
            )
        }

        let executableName = resolvedOverride ?? manifest.executableName
        let resolvedPath = resolver.executablePath(named: executableName, environment: environment)
        return AgentCLIInvocation(
            executableName: executableName,
            resolvedExecutablePath: resolvedPath,
            arguments: permissionAndAdditional
                + manifest.invocationArguments(
                    sessionIdentity: thread.sessionIdentity,
                    requestedName: thread.pendingSessionRename
                )
        )
    }

    private func recordUnsupportedPermissionModeIfNeeded(
        thread: AgentThread,
        validated: AgentLaunchOptions,
        permissionModes: [AgentPermissionMode]?
    ) {
        guard let requested = thread.launchOptions.permissionModeID else { return }
        // Loud failure: a mode was explicitly requested but the resolved support
        // set does not contain it — either `validated` dropped it, or (when the
        // family has no modes, e.g. opencode) it is kept yet inert. Both cases
        // mean the user's choice will not take effect, so record a diagnostic.
        let supportedIDs = Set(
            (permissionModes ?? AgentPermissionMode.supportedModes(for: thread.agentCLI)).map(\.id))
        guard validated.permissionModeID == nil || !supportedIDs.contains(requested) else { return }
        diagnosticRecorder.record(
            DiagnosticEvent(
                category: "AgentCLI",
                name: "permission_mode_unsupported",
                metadata: [
                    "agent_cli": thread.agentCLI.rawValue,
                    "requested_mode": requested,
                    "thread_id": thread.id.uuidString,
                ]
            )
        )
    }

    // MARK: - Capture / activity log URLs

    /// The capture-log URL for a thread, if capture is configured.
    public func captureLogURL(for thread: AgentThread) -> URL? {
        captureDirectory?.appendingPathComponent("\(thread.id.uuidString).log")
    }

    /// The activity-log (NDJSON) URL for a thread, if configured.
    public func activityLogURL(for thread: AgentThread) -> URL? {
        activityDirectory?.appendingPathComponent("\(thread.id.uuidString).ndjson")
    }
}

extension CLIManifest {
    /// The full launch arguments for a (resume or fresh) invocation: resume args
    /// when a session identity exists, else start-name args when a name was
    /// requested, else empty.
    func invocationArguments(sessionIdentity: String?, requestedName: String?) -> [String] {
        if let sessionIdentity {
            return resumeTemplate.arguments(sessionIdentity: sessionIdentity)
        }
        if case .viaFlag(let flag) = startNameCapability,
            let name = AgentCLINaming.sanitized(requestedName)
        {
            return [flag, name]
        }
        return []
    }

    /// The startup input to feed for a pending rename, honoring the rename
    /// capability and the "only if resumed" gate.
    func startupInput(forPendingRename name: String, sessionIdentity: String?) -> String? {
        switch renameCapability {
        case .none:
            return nil
        case .viaStartupInput(let command):
            return AgentCLINaming.renameCommand(template: command, name: name)
        case .viaStartupInputIfResumed(let command):
            guard sessionIdentity != nil else { return nil }
            return AgentCLINaming.renameCommand(template: command, name: name)
        }
    }
}

/// Naming helpers shared by invocation and rename construction.
enum AgentCLINaming {
    /// A single-line, trimmed name, or `nil` if blank.
    static func sanitized(_ name: String?) -> String? {
        let singleLine =
            name?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let trimmed = singleLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Expands a rename-command template (`"/rename {name}\n"`) with a sanitized
    /// name, or `nil` if the name is blank.
    static func renameCommand(template: String, name: String) -> String? {
        guard let sanitized = sanitized(name) else { return nil }
        return template.replacingOccurrences(of: "{name}", with: sanitized)
    }
}
