import Foundation

/// A single agent CLI session within a project. A thread is permanently bound to
/// one CLI family and resumes the same underlying session via its stored session
/// identity.
public struct AgentThread: Identifiable, Equatable, Sendable {
    /// The thread's stable unique identifier.
    public let id: UUID
    /// The user-facing thread name.
    public var displayName: String
    /// The identifier of the project this thread belongs to.
    public var projectID: UUID
    /// The directory the agent CLI runs in.
    public var workingDirectory: URL
    /// The CLI family this thread is permanently bound to.
    public var agentCLI: AgentCLIKind
    /// The launch options applied when starting or resuming the CLI.
    public var launchOptions: AgentLaunchOptions
    /// The stored identity used to resume the same underlying CLI session.
    public var sessionIdentity: String?
    /// The canonical session name reported by the CLI, if known.
    public var canonicalSessionName: String?
    /// A pending session rename to apply on the next launch, if any.
    public var pendingSessionRename: String?
    /// When the thread was created.
    public var createdAt: Date
    /// When the thread was last opened.
    public var lastOpenedAt: Date
    /// Whether the thread is archived.
    public var isArchived: Bool
    /// Whether the thread is pinned.
    public var isPinned: Bool

    /// Creates a thread, validating `launchOptions` against `agentCLI` and
    /// normalizing an empty `pendingSessionRename` to `nil`.
    public init(
        id: UUID = UUID(),
        displayName: String,
        projectID: UUID,
        workingDirectory: URL,
        agentCLI: AgentCLIKind = .codex,
        launchOptions: AgentLaunchOptions = AgentLaunchOptions(),
        sessionIdentity: String? = nil,
        canonicalSessionName: String? = nil,
        pendingSessionRename: String? = nil,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        isArchived: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.agentCLI = agentCLI
        self.launchOptions = launchOptions.validated(for: agentCLI)
        self.sessionIdentity = sessionIdentity
        self.canonicalSessionName = canonicalSessionName
        let trimmedPendingRename =
            pendingSessionRename?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pendingSessionRename =
            trimmedPendingRename?.isEmpty == false ? trimmedPendingRename : nil
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.isArchived = isArchived
        self.isPinned = isPinned
    }
}
