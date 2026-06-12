import Foundation
import Observation

/// Owns sidebar/right-panel/bottom-terminal widths, collapses, swap state, and the
/// set of threads with an expanded bottom terminal. `@MainActor @Observable`.
/// Every mutation persists via the injected store actor; drag-resize batches the
/// persist into ``commitLayoutResize`` so a drag does not write per tick.
@MainActor
@Observable
public final class LayoutStore {
    /// The current window-chrome geometry and visibility state.
    public private(set) var layoutState: LayoutState
    /// The IDs of threads whose bottom terminal is currently expanded.
    public private(set) var bottomTerminalExpandedThreadIDs: Set<UUID>

    @ObservationIgnored private let persistence: StorePersistenceQueue
    @ObservationIgnored private let diagnosticRecorder: any DiagnosticEventRecording
    /// The selected thread the bottom-terminal toggle applies to. Pushed by
    /// WorkspaceStore on selection change so LayoutStore stays decoupled.
    @ObservationIgnored public var selectedThreadID: UUID?

    init(context: StoreLoadContext) {
        self.persistence = StorePersistenceQueue(store: context.environment.persistenceStore)
        self.diagnosticRecorder = context.environment.diagnosticRecorder
        self.layoutState = context.snapshot.layoutState
        self.bottomTerminalExpandedThreadIDs = context.snapshot.bottomTerminalExpandedThreadIDs
        self.selectedThreadID = context.snapshot.selectedThreadID
    }

    /// Resolves once every enqueued persistence write has completed (test seam).
    public func flushPersistence() async { await persistence.flush() }

    // MARK: - Bottom terminal

    /// Whether the selected thread's bottom terminal is expanded.
    public var isBottomTerminalExpanded: Bool {
        selectedThreadID.map { bottomTerminalExpandedThreadIDs.contains($0) } ?? false
    }

    /// Alias for ``isBottomTerminalExpanded``.
    public var isGlobalTerminalExpanded: Bool { isBottomTerminalExpanded }

    /// Whether the given thread's bottom terminal is expanded.
    public func isBottomTerminalExpanded(for threadID: UUID) -> Bool {
        bottomTerminalExpandedThreadIDs.contains(threadID)
    }

    /// Toggles the selected thread's bottom terminal, if any thread is selected.
    public func toggleBottomTerminal() {
        guard let selectedThreadID else { return }
        toggleBottomTerminal(for: selectedThreadID)
    }

    /// Alias for ``toggleBottomTerminal()``.
    public func toggleGlobalTerminal() { toggleBottomTerminal() }

    /// Toggles the given thread's bottom terminal, recording a diagnostic and
    /// persisting the new state.
    public func toggleBottomTerminal(for threadID: UUID) {
        if bottomTerminalExpandedThreadIDs.contains(threadID) {
            bottomTerminalExpandedThreadIDs.remove(threadID)
        } else {
            bottomTerminalExpandedThreadIDs.insert(threadID)
        }
        let isExpanded = bottomTerminalExpandedThreadIDs.contains(threadID)
        recordDiagnostic(
            category: "Layout",
            name: "bottom_terminal_toggled",
            metadata: ["thread_id": threadID.uuidString, "expanded": "\(isExpanded)"]
        )
        persistence.enqueue {
            await $0.setBottomTerminalExpanded(threadID: threadID, isExpanded: isExpanded)
        }
    }

    // MARK: - Collapses & swap

    /// Toggles whether the sidebar is collapsed and persists the change.
    public func toggleSidebarCollapsed() {
        layoutState.isSidebarCollapsed.toggle()
        persistLayout()
    }

    /// Toggles whether the right panel is collapsed and persists the change.
    public func toggleRightPanelCollapsed() {
        layoutState.isRightPanelCollapsed.toggle()
        persistLayout()
    }

    /// Toggles whether the main and right workspace positions are swapped and
    /// persists the change.
    public func toggleWorkspaceSwap() {
        layoutState.isWorkspaceSwapped.toggle()
        persistLayout()
    }

    // MARK: - Resize

    /// Sets the sidebar width (clamped to its valid range), persisting unless
    /// `persist` is `false` (used per tick during a drag).
    public func setSidebarWidth(_ width: Double, persist: Bool = true) {
        layoutState.sidebarWidth = LayoutState.clamp(
            width, minimum: LayoutState.minimumSidebarWidth,
            maximum: LayoutState.maximumSidebarWidth)
        if persist { persistLayout() }
    }

    /// Sets the right-panel width (clamped to its minimum), persisting unless
    /// `persist` is `false` (used per tick during a drag).
    public func setRightPanelWidth(_ width: Double, persist: Bool = true) {
        layoutState.rightPanelWidth = LayoutState.clampMinimum(
            width, minimum: LayoutState.minimumRightPanelWidth)
        if persist { persistLayout() }
    }

    /// Sets the bottom (global) terminal height (clamped for the available window
    /// height), persisting unless `persist` is `false` (used per tick during a drag).
    public func setGlobalTerminalHeight(
        _ height: Double,
        availableWindowHeight: Double? = nil,
        persist: Bool = true
    ) {
        layoutState.globalTerminalHeight = LayoutState.clampedGlobalTerminalHeight(
            height, availableWindowHeight: availableWindowHeight)
        if persist { persistLayout() }
    }

    /// Resets the sidebar width to its default, persisting unless `persist` is `false`.
    public func resetSidebarWidth(persist: Bool = true) {
        layoutState.resetSidebarWidth()
        if persist { persistLayout() }
    }

    /// Resets the right-panel width to its default, persisting unless `persist` is `false`.
    public func resetRightPanelWidth(persist: Bool = true) {
        layoutState.resetRightPanelWidth()
        if persist { persistLayout() }
    }

    /// Resets the bottom (global) terminal height to its default, persisting unless
    /// `persist` is `false`.
    public func resetGlobalTerminalHeight(persist: Bool = true) {
        layoutState.resetGlobalTerminalHeight()
        if persist { persistLayout() }
    }

    /// Persists the current layout once; for drag operations that ran with
    /// `persist: false` per tick, this is the single committing write.
    public func commitLayoutResize() {
        persistLayout()
    }

    // MARK: - Persistence

    private func persistLayout() {
        let state = layoutState
        persistence.enqueue { await $0.setLayoutState(state) }
    }

    private func recordDiagnostic(category: String, name: String, metadata: [String: String]) {
        diagnosticRecorder.record(
            DiagnosticEvent(category: category, name: name, metadata: metadata))
    }
}
