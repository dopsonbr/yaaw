import Foundation
import Observation

/// Owns per-thread right-panel modes and tab state, the selected file, browser
/// error messages, and the now-persisted per-thread file-browser UI state
/// (expanded folders, selected file, nvim path — schema v18). `@MainActor
/// @Observable`. Surface launch/teardown is driven through `RenderSurfaceManaging`;
/// nvim relaunch is requested via per-tab relaunch tokens.
@MainActor
@Observable
public final class RightPanelStore {
    /// The remembered right-panel mode for each thread.
    public internal(set) var rightPanelModesByThreadID: [UUID: RightPanelMode]
    /// The full persisted right-panel state (tabs, folders, selection) per thread.
    public internal(set) var rightPanelStatesByThreadID: [UUID: RightPanelState]
    /// The currently published file-browser selection, relative to the thread root.
    public internal(set) var selectedFileRelativePath: String?
    /// Browser-preview-unavailable messages to show, keyed by thread.
    public internal(set) var browserUnavailableMessagesByThreadID: [UUID: String]

    @ObservationIgnored let persistence: StorePersistenceQueue
    @ObservationIgnored let surfaceManager: any RenderSurfaceManaging
    /// The selected thread ID, pushed by WorkspaceStore on selection change.
    @ObservationIgnored public var selectedThreadID: UUID?
    /// Resolves the selected thread's working directory for path validation,
    /// pushed by WorkspaceStore.
    @ObservationIgnored public var selectedThreadWorkingDirectory: (() -> URL?)?
    /// Per-tab nvim relaunch tokens (bumped to force the surface to relaunch with
    /// a new file). In-memory only; the surface is re-created on relaunch anyway.
    @ObservationIgnored var nvimRelaunchTokensByTabKey: [String: UUID] = [:]
    @ObservationIgnored var nvimRelaunchTokensByThreadID: [UUID: UUID] = [:]

    init(context: StoreLoadContext) {
        let snapshot = context.snapshot
        self.persistence = context.persistenceQueue
        self.surfaceManager = context.environment.renderSurfaceManager
        self.selectedThreadID = snapshot.selectedThreadID

        var modes = snapshot.rightPanelModesByThreadID
        if let selectedThreadID = snapshot.selectedThreadID, modes[selectedThreadID] == nil {
            modes[selectedThreadID] = snapshot.selectedRightPanelMode
        }
        self.rightPanelModesByThreadID = modes

        var states = snapshot.rightPanelStatesByThreadID
        for thread in snapshot.threads where states[thread.id] == nil {
            let mode =
                modes[thread.id]
                ?? (thread.id == snapshot.selectedThreadID
                    ? snapshot.selectedRightPanelMode : .files)
            states[thread.id] = RightPanelState.defaultState(selectedMode: mode)
        }
        self.rightPanelStatesByThreadID = states
        // Restore the selected thread's remembered file selection (v18 persistence).
        self.selectedFileRelativePath =
            snapshot.selectedThreadID.flatMap { states[$0]?.selectedFilePath }
        self.browserUnavailableMessagesByThreadID = [:]
    }

    /// Resolves once every enqueued persistence write has completed (test seam).
    public func flushPersistence() async { await persistence.flush() }

    // MARK: - Computed (scoped to selected thread)

    /// The right-panel mode of the selected thread, defaulting to `.files`.
    public var selectedRightPanelMode: RightPanelMode {
        guard let selectedThreadID else { return .files }
        return rightPanelStatesByThreadID[selectedThreadID]?.selectedMode
            ?? rightPanelModesByThreadID[selectedThreadID]
            ?? .files
    }

    /// The full right-panel state of the selected thread, or a default state.
    public var selectedRightPanelState: RightPanelState {
        guard let selectedThreadID else { return RightPanelState() }
        return rightPanelStatesByThreadID[selectedThreadID]
            ?? RightPanelState.defaultState(
                selectedMode: rightPanelModesByThreadID[selectedThreadID] ?? .files)
    }

    /// The active tab within the selected thread's right-panel state.
    public var selectedRightPanelTab: RightPanelTab { selectedRightPanelState.selectedTab }

    /// The browser-unavailable message for the selected thread, if any.
    public var selectedBrowserUnavailableMessage: String? {
        selectedThreadID.flatMap { browserUnavailableMessagesByThreadID[$0] }
    }

    // MARK: - Mode / tab selection

    /// Selects the right-panel mode for the selected thread and persists it.
    public func selectRightPanelMode(_ mode: RightPanelMode) {
        guard let selectedThreadID else { return }
        rightPanelModesByThreadID[selectedThreadID] = mode
        var state = selectedRightPanelState
        state.selectMode(mode)
        rightPanelStatesByThreadID[selectedThreadID] = state
        persistRightPanel(threadID: selectedThreadID)
    }

    /// Selects the tab with the given ID for the selected thread, syncing the
    /// thread's mode to the tab and persisting the change.
    public func selectRightPanelTab(id tabID: String) {
        guard let selectedThreadID else { return }
        var state = selectedRightPanelState
        state.selectTab(id: tabID)
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = state.selectedMode
        persistRightPanel(threadID: selectedThreadID)
    }

    /// Closes the tab with the given ID for the selected thread, tearing down any
    /// associated surface (nvim) or message (browser) and persisting the change.
    public func closeRightPanelTab(id tabID: String) {
        guard let selectedThreadID else { return }
        var state = selectedRightPanelState
        guard let closedTab = state.closeTab(id: tabID) else { return }
        rightPanelStatesByThreadID[selectedThreadID] = state
        rightPanelModesByThreadID[selectedThreadID] = state.selectedMode
        switch closedTab.kind {
        case .browser:
            browserUnavailableMessagesByThreadID.removeValue(forKey: selectedThreadID)
        case .nvim:
            surfaceManager.shutdown(
                role: .nvimTab(threadID: selectedThreadID, tabID: closedTab.id))
            nvimRelaunchTokensByTabKey.removeValue(
                forKey: nvimTabKey(threadID: selectedThreadID, tabID: closedTab.id))
        case .files, .git:
            break
        }
        persistRightPanel(threadID: selectedThreadID)
    }

    /// Selects the next right-panel mode in cycle order.
    public func cycleRightPanelModeForward() { selectRightPanelMode(selectedRightPanelMode.next) }
    /// Selects the previous right-panel mode in cycle order.
    public func cycleRightPanelModeBackward() {
        selectRightPanelMode(selectedRightPanelMode.previous)
    }

    // MARK: - Per-thread persisted UI state

    /// The expanded folders remembered for a thread (now persisted, schema v18).
    public func expandedFolders(forThreadID id: UUID) -> Set<String> {
        rightPanelStatesByThreadID[id]?.expandedFolders ?? []
    }

    /// Records the expanded folders for a thread and persists them (schema v18).
    public func setExpandedFolders(_ folders: Set<String>, forThreadID id: UUID) {
        var state = rightPanelStatesByThreadID[id] ?? RightPanelState.defaultState()
        guard state.expandedFolders != folders else { return }
        state.expandedFolders = folders
        rightPanelStatesByThreadID[id] = state
        persistRightPanel(threadID: id)
    }

    /// The nvim path remembered for a thread (now persisted, schema v18).
    public func nvimPath(forThreadID id: UUID) -> String? {
        rightPanelStatesByThreadID[id]?.nvimPath
    }

    // MARK: - Selected-file memory

    /// Sets the published selection and records it as the thread's remembered file
    /// so a thread/tab switch restores it. Now persisted (schema v18).
    func setSelectedFile(_ relativePath: String?) {
        selectedFileRelativePath = relativePath
        guard let selectedThreadID else { return }
        var state = rightPanelStatesByThreadID[selectedThreadID] ?? RightPanelState.defaultState()
        guard state.selectedFilePath != relativePath else { return }
        state.selectedFilePath = relativePath
        rightPanelStatesByThreadID[selectedThreadID] = state
        persistRightPanel(threadID: selectedThreadID)
    }

    /// Re-points the published selection to the newly selected thread's remembered
    /// file. Called by WorkspaceStore on selection change.
    func restoreSelectedFile(forThreadID threadID: UUID?) {
        selectedFileRelativePath = threadID.flatMap {
            rightPanelStatesByThreadID[$0]?.selectedFilePath
        }
    }

    /// The per-thread remembered file selection (kept even when not currently
    /// visible), used by ActivityStore to restore selection on index changes.
    func rememberedSelectedFile(forThreadID threadID: UUID) -> String? {
        rightPanelStatesByThreadID[threadID]?.selectedFilePath
    }

    /// Clears only the published value, keeping the per-thread memory so a later
    /// index load (e.g. an expanded subtree) can restore it.
    func clearPublishedSelectedFile() {
        selectedFileRelativePath = nil
    }

    /// Sets only the published value without touching per-thread memory.
    func setPublishedSelectedFileOnly(_ relativePath: String?) {
        selectedFileRelativePath = relativePath
    }

    // MARK: - Thread lifecycle hooks (from WorkspaceStore)

    func seedDefaultState(forThreadID threadID: UUID) {
        rightPanelModesByThreadID[threadID] = .files
        rightPanelStatesByThreadID[threadID] = RightPanelState.defaultState()
        persistRightPanel(threadID: threadID)
    }

    // MARK: - Persistence

    func persistRightPanel(threadID: UUID) {
        let mode = rightPanelModesByThreadID[threadID] ?? .files
        guard let state = rightPanelStatesByThreadID[threadID] else {
            persistence.enqueue { await $0.setRightPanelMode(threadID: threadID, mode: mode) }
            return
        }
        persistence.enqueue {
            await $0.setRightPanelMode(threadID: threadID, mode: mode)
            await $0.setRightPanelState(threadID: threadID, state: state)
        }
    }

    func nvimTabKey(threadID: UUID, tabID: String) -> String {
        "\(threadID.uuidString)|\(tabID)"
    }
}
