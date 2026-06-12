import Foundation
import Observation

/// Owns thread activity (status/preview/unread), the file-browser state, the
/// activity → unread → badge → notification chain with focus suppression, the
/// file-browser refresh, and capture/activity polling via the binding actor.
/// `@MainActor @Observable`. Generation counters and in-flight booleans are gone:
/// per-thread polling is a cancellable `Task` keyed by thread (see
/// ActivityStore+Polling); reselect/close/terminate cancels it.
@MainActor
@Observable
public final class ActivityStore {
    /// The latest activity state (status/preview/unread) for each thread, keyed by thread ID.
    public internal(set) var threadActivityByThreadID: [UUID: ThreadActivityState]
    /// The published file-browser state for the selected thread.
    public internal(set) var fileBrowserState: FileBrowserState

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored unowned let workspace: WorkspaceStore
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let rightPanel: RightPanelStore
    @ObservationIgnored let persistence: StorePersistenceQueue
    @ObservationIgnored private let snapshotActivity: [UUID: ThreadActivityState]

    // Focus / notification suppression state.
    @ObservationIgnored var focusedProjectTerminalThreadID: UUID?
    // Capture/activity polling offsets + partial-line buffers (no generation
    // counter — staleness is handled by Task cancellation in +Polling).
    @ObservationIgnored var activityReadOffsetsByThreadID: [UUID: UInt64] = [:]
    @ObservationIgnored var activityPartialLinesByThreadID: [UUID: String] = [:]
    @ObservationIgnored var pendingTerminalTitlesByThreadID: [UUID: String] = [:]
    // File-index request tasks, keyed by thread; cancelled on reselect/reindex.
    @ObservationIgnored var fileIndexTasksByThreadID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var fileBrowserEntriesByThreadID: [UUID: [FileBrowserEntry]] = [:]
    @ObservationIgnored var fileIndexMetadataByThreadID: [UUID: FileIndexMetadata]

    init(
        context: StoreLoadContext,
        workspace: WorkspaceStore,
        settings: SettingsStore,
        rightPanel: RightPanelStore
    ) {
        self.environment = context.environment
        self.workspace = workspace
        self.settings = settings
        self.rightPanel = rightPanel
        self.persistence = StorePersistenceQueue(store: context.environment.persistenceStore)
        self.snapshotActivity = context.snapshot.threadActivityByThreadID
        // Loaded "working" activities downgrade to "inactive" on launch (captures
        // in-flight state before a crash); persisted back below if changed.
        self.threadActivityByThreadID = context.snapshot.threadActivityByThreadID.mapValues {
            $0.downgradedForLaunch()
        }
        self.fileIndexMetadataByThreadID = context.snapshot.fileIndexMetadataByThreadID
        let selectedThread = context.snapshot.selectedThreadID.flatMap { threadID in
            context.snapshot.threads.first { $0.id == threadID }
        }
        self.fileBrowserState = FileBrowserState(
            rootPath: selectedThread?.workingDirectory.path,
            metadata: selectedThread.flatMap { context.snapshot.fileIndexMetadataByThreadID[$0.id] }
        )
    }

    /// Post-init: persist the launch-downgraded activities and update the dock badge.
    func finishLoad() async {
        for (threadID, loadedActivity) in snapshotActivity {
            guard let downgraded = threadActivityByThreadID[threadID], downgraded != loadedActivity
            else { continue }
            persistThreadActivity(downgraded)
        }
        updateDockBadge()
    }

    /// Resolves once every enqueued persistence write has completed (test seam).
    public func flushPersistence() async { await persistence.flush() }

    // MARK: - Reads

    /// The number of threads whose latest activity is currently unread (drives the dock badge).
    public var unreadThreadActivityCount: Int {
        threadActivityByThreadID.values.filter(\.isUnread).count
    }

    /// Returns the activity state for the thread, or a fresh empty state if none exists.
    public func threadActivity(for threadID: UUID) -> ThreadActivityState {
        threadActivityByThreadID[threadID] ?? ThreadActivityState(threadID: threadID)
    }

    /// The most recent interaction time for a thread: the later of its `lastOpenedAt`
    /// and its latest activity update.
    public func lastInteractionDate(for thread: AgentThread) -> Date {
        guard let activity = threadActivityByThreadID[thread.id] else { return thread.lastOpenedAt }
        return max(thread.lastOpenedAt, activity.updatedAt)
    }

    // MARK: - Selection / config hooks (from WorkspaceStore)

    func handleSelectionChanged(selectedThread: AgentThread?) {
        // Cancel the previous thread's in-flight file index, then reset + refresh.
        resetFileBrowserForSelectedThread(selectedThread: selectedThread)
        if let selectedThread {
            refreshFileBrowser(
                for: selectedThread, publishCachedSnapshot: false, forceReindex: false)
        }
    }

    func handleConfigurationReload() {
        activityPartialLinesByThreadID.removeAll()
        refreshSelectedFileBrowser()
    }

    // MARK: - Activity chain

    /// The core activity engine: resolves status/preview, applies focus
    /// suppression, skips redundant publishes (idempotency), persists, advances
    /// `lastOpenedAt`, updates the badge, and dispatches a notification. Re-homed
    /// byte-for-byte in behavior from `AppModel.applyThreadActivity`.
    func applyThreadActivity(_ event: ThreadActivityEvent, isUnread: Bool, shouldNotify: Bool) {
        guard let threadIndex = workspace.threadIndexByID[event.threadID] else { return }
        let currentActivity = threadActivity(for: event.threadID)
        let status =
            event.status
            ?? ThreadActivityText.inferredStatus(title: event.title, body: event.body)
            ?? currentActivity.status
        let preview = ThreadActivityText.preview(title: event.title, body: event.body)
        let suppressNotification = shouldSuppressSystemNotification(for: event.threadID)
        let activity = ThreadActivityState(
            threadID: event.threadID,
            status: status,
            preview: preview,
            isUnread: isUnread && !suppressNotification,
            title: event.title,
            body: event.body,
            source: event.source,
            updatedAt: event.createdAt
        )
        if Self.hasSamePublishedActivity(activity, as: currentActivity) { return }
        threadActivityByThreadID[event.threadID] = activity
        persistThreadActivity(activity)
        if workspace.threads[threadIndex].lastOpenedAt < event.createdAt {
            workspace.touchThreadLastOpened(at: threadIndex, to: event.createdAt)
        }
        updateDockBadge()
        recordDiagnostic(
            category: "Threads",
            name: "thread_activity_updated",
            metadata: [
                "thread_id": event.threadID.uuidString,
                "status": status.rawValue,
                "source": event.source.rawValue,
            ]
        )
        if shouldNotify, activity.isUnread, !suppressNotification {
            dispatchSystemNotification(for: activity)
        }
    }

    func markThreadActivityRead(threadID: UUID) {
        guard var activity = threadActivityByThreadID[threadID], activity.isUnread else { return }
        activity.isUnread = false
        threadActivityByThreadID[threadID] = activity
        persistThreadActivity(activity)
        updateDockBadge()
    }

    static func hasSamePublishedActivity(
        _ lhs: ThreadActivityState, as rhs: ThreadActivityState
    ) -> Bool {
        var normalized = lhs
        normalized.updatedAt = rhs.updatedAt
        return normalized == rhs
    }

    private func shouldSuppressSystemNotification(for threadID: UUID) -> Bool {
        environment.isApplicationActive()
            && workspace.selectedThreadID == threadID
            && focusedProjectTerminalThreadID == threadID
    }

    private func dispatchSystemNotification(for activity: ThreadActivityState) {
        guard let thread = workspace.thread(withID: activity.threadID),
            let project = workspace.projects.first(where: { $0.id == thread.projectID })
        else { return }
        environment.notificationDispatcher.dispatch(
            ThreadActivityNotification(
                threadID: activity.threadID,
                title: thread.displayName,
                subtitle: "\(project.displayName) - \(activity.status.cliValue)",
                body: activity.preview ?? activity.body ?? activity.title
                    ?? activity.status.cliValue
            )
        )
    }

    private func updateDockBadge() {
        environment.badgeUpdater.updateUnreadThreadActivityCount(unreadThreadActivityCount)
    }

    // MARK: - Persistence

    func persistThreadActivity(_ activity: ThreadActivityState) {
        persistence.enqueue { await $0.upsertThreadActivity(activity) }
    }

    func persistFileIndexMetadata(_ metadata: FileIndexMetadata) {
        persistence.enqueue { await $0.upsertFileIndexMetadata(metadata) }
    }

    func recordDiagnostic(category: String, name: String, metadata: [String: String] = [:]) {
        environment.diagnosticRecorder.record(
            DiagnosticEvent(category: category, name: name, metadata: metadata))
    }
}
