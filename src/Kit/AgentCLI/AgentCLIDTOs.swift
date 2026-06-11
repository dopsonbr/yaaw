import Foundation

/// A fully-resolved invocation of an agent CLI: the executable name, its
/// resolved absolute path (if found on `PATH`), and the ordered argument list.
public struct AgentCLIInvocation: Equatable, Sendable {
    /// The executable name as requested (e.g. `"codex"` or a user override).
    public var executableName: String
    /// The absolute path the executable resolved to, if it was found.
    public var resolvedExecutablePath: String?
    /// The ordered arguments to pass to the executable.
    public var arguments: [String]

    /// Creates an invocation.
    public init(
        executableName: String,
        resolvedExecutablePath: String?,
        arguments: [String]
    ) {
        self.executableName = executableName
        self.resolvedExecutablePath = resolvedExecutablePath
        self.arguments = arguments
    }

    /// The full command line: resolved path (or bare name) followed by arguments.
    public var command: [String] {
        [resolvedExecutablePath ?? executableName] + arguments
    }
}

/// Session metadata scraped from a CLI's output or catalog: a required identity
/// plus optional reported name and title, with a single canonical-name rule.
public struct AgentCLISessionMetadata: Equatable, Sendable {
    /// The durable session identifier used to resume the session.
    public var identity: String
    /// The session name the CLI reported (highest-priority display name).
    public var reportedName: String?
    /// The transient terminal title, used only as a name fallback.
    public var title: String?

    /// Creates metadata; blank name/title are normalized to `nil`.
    public init(identity: String, reportedName: String? = nil, title: String? = nil) {
        self.identity = identity
        self.reportedName = reportedName?.agentCLINilIfBlank
        self.title = title?.agentCLINilIfBlank
    }

    /// Derives metadata from a matched catalog candidate. Single source of truth
    /// shared by the actor's `catalogMetadata(for:)` path.
    public init(from candidate: SessionLinkCandidate) {
        self.init(identity: candidate.identity, reportedName: candidate.displayName)
    }

    /// The display name to show: reported name, else title, else the identity.
    public var canonicalName: String {
        reportedName ?? title ?? identity
    }
}

/// A candidate session discovered in a CLI's on-disk catalog that a thread may
/// be linked to.
public struct SessionLinkCandidate: Identifiable, Equatable, Sendable {
    /// The durable session identifier.
    public var identity: String
    /// The candidate's display name (falls back to the identity).
    public var displayName: String
    /// The CLI family this candidate belongs to.
    public var agentCLI: AgentCLIKind
    /// The working directory recorded for the session, if any.
    public var workingDirectory: URL?
    /// The last-updated timestamp recorded for the session, if any.
    public var updatedAt: Date?
    /// A human-readable description of where the candidate was read from.
    public var source: String

    /// Creates a candidate.
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

    /// A stable identity scoped by CLI family.
    public var id: String {
        "\(agentCLI.rawValue):\(identity)"
    }
}

/// A window of captured terminal output read from a capture log, plus the byte
/// offsets it spans so callers can resume reading.
public struct AgentCLICapturedOutput: Equatable, Sendable {
    /// The decoded text of this window.
    public var output: String
    /// The byte offset this window started at.
    public var startOffset: UInt64
    /// The byte offset to pass on the next read.
    public var nextOffset: UInt64

    /// Creates a captured-output window.
    public init(output: String, nextOffset: UInt64, startOffset: UInt64 = 0) {
        self.output = output
        self.startOffset = startOffset
        self.nextOffset = nextOffset
    }
}

/// A terminal launch plan: the (capture-wrapped) command, environment, capture
/// log location, and optional startup input to feed the CLI.
///
/// Chunk C owns this DTO so the session-binding logic can be built and tested
/// independently of the Chunk D terminal stack; the helper consumes the same
/// shape when it launches the PTY.
public struct AgentCLITerminalLaunchDescriptor: Equatable, Sendable {
    /// The command to execute (shell-wrapped when capture is configured).
    public var command: [String]
    /// The environment to launch with (capture/activity vars injected).
    public var environment: [String: String]
    /// The capture-log file the terminal output should be written to, if any.
    public var captureLogURL: URL?
    /// Optional input to feed to the CLI once it starts (e.g. a rename command).
    public var startupInput: String?

    /// Creates a launch descriptor.
    public init(
        command: [String],
        environment: [String: String],
        captureLogURL: URL? = nil,
        startupInput: String? = nil
    ) {
        self.command = command
        self.environment = environment
        self.captureLogURL = captureLogURL
        self.startupInput = startupInput
    }
}

/// The result of attempting to read catalog metadata for a thread.
///
/// `driftDetected` makes a catalog/format change a distinguishable, loud signal
/// instead of a silent `nil`. Chunk E turns `driftDetected` into a visible
/// thread state; Chunk C also records a diagnostic when it occurs.
public enum CatalogMetadataResult: Equatable, Sendable {
    /// Metadata was found and parsed for the requested session.
    case found(AgentCLISessionMetadata)
    /// A session record exists but could not be parsed (format drift).
    case driftDetected(reason: String)
    /// No record for the requested session was present in the catalog.
    case absent
}

/// Errors raised while binding, launching, or scraping an agent CLI session.
public enum AgentCLISessionBindingError: Error, Equatable, Sendable {
    /// No manifest is registered for the given CLI family.
    case missingManifest(AgentCLIKind)
    /// The executable could not be resolved on `PATH` or the fallback dirs.
    case missingExecutable(String)
    /// Launching the CLI process failed.
    case launchFailed(String)
    /// The CLI produced output but no session metadata could be parsed from it.
    case metadataNotFound(String)
}

extension String {
    /// Trimmed, or `nil` when the trimmed value is empty.
    var agentCLINilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
