import Foundation
import SQLite3

extension SQLiteYAAWStore {
    /// Persists a full snapshot in one IMMEDIATE transaction using UPSERT +
    /// diff-based deletes, replacing the old DELETE-everything-then-INSERT-all
    /// scan. The snapshot is the complete desired state: any project/thread/etc.
    /// no longer present is deleted (set-difference against the live row IDs),
    /// and every present row is `INSERT … ON CONFLICT DO UPDATE`. Deleting a
    /// thread cascades (FK ON DELETE CASCADE) to its panel/terminal/index rows,
    /// so unreferenced child rows are cleaned up automatically. Every statement
    /// is served from the prepared-statement cache, so a 10k-thread save compiles
    /// each SQL string once rather than once per row.
    public func save(_ snapshot: YAAWSnapshot) {
        do {
            try transaction {
                let snapshotProjectIDs = Set(snapshot.projects.map(\.id))
                let snapshotThreadIDs = Set(snapshot.threads.map(\.id))

                // Large keyed tables: UPSERT every present row + diff-delete only
                // the rows no longer present. Deleting a thread/project cascades
                // (FK ON DELETE CASCADE) to its child rows, so removed entities are
                // cleaned automatically without rewriting the surviving rows.
                try deleteRows(
                    table: "threads",
                    keepingIDs: snapshotThreadIDs,
                    existing: try loadAllIDs(table: "threads")
                )
                try deleteRows(
                    table: "projects",
                    keepingIDs: snapshotProjectIDs,
                    existing: try loadAllIDs(table: "projects")
                )

                // Small/sparse per-thread + per-project state tables only ever hold
                // rows for *tracked* threads/projects (a thread with default panel
                // state has no row and loads its defaults via fallback). Rebuilding
                // them wholesale is therefore cheap, guarantees no stale rows when a
                // thread's state reverts to default, and — crucially — avoids
                // writing default state for all N threads (the old hot path). Only
                // the rows in the snapshot's sparse dictionaries are reinserted.
                for table in Self.sparseStateTables {
                    try execute("DELETE FROM \(table)")  // hardcoded literals, never user input
                }

                for project in snapshot.projects {
                    try upsertProjectStatement(project)
                }
                for thread in snapshot.threads {
                    try upsertThreadStatement(thread)
                }
                try saveRightPanelModes(snapshot)
                try saveRightPanelStates(snapshot)
                try saveBottomTerminalState(snapshot)
                try saveFileIndexMetadata(snapshot)
                try saveThreadActivity(snapshot)
                try saveSidebarProjectState(snapshot)
                try saveAppState(snapshot)
                try saveLayoutState(snapshot.layoutState)
            }
        } catch {
            recordSQLiteError(name: "sqlite_save_failed", error: error)
        }
    }

    /// Sparse per-thread / per-project state tables that `save()` rebuilds
    /// wholesale (they only hold rows for tracked entities, so this is cheap).
    private static let sparseStateTables = [
        "right_panel_modes",
        "right_panel_tabs",
        "right_panel_tab_state",
        "bottom_terminal_state",
        "file_index_metadata",
        "thread_activity_state",
        "sidebar_project_state",
    ]

    private func loadAllIDs(table: String, column: String = "id") throws -> Set<UUID> {
        // table/column are hardcoded literals from the save body, never user input.
        let statement = try cachedPrepare("SELECT \(column) FROM \(table)")
        defer { try? resetStatement(statement) }
        var ids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(at: 0, in: statement)) {
                ids.insert(id)
            }
        }
        return ids
    }

    private func deleteRows(
        table: String,
        keepingIDs: Set<UUID>,
        existing: Set<UUID>
    ) throws {
        let toDelete = existing.subtracting(keepingIDs)
        guard !toDelete.isEmpty else { return }
        // table is a hardcoded literal ("threads"/"projects"); the id is bound.
        let statement = try cachedPrepare("DELETE FROM \(table) WHERE id = ?")
        for id in toDelete {
            bind(id.uuidString, at: 1, in: statement)
            try stepDone(statement)
            try resetStatement(statement)
        }
    }

    private func saveRightPanelModes(_ snapshot: YAAWSnapshot) throws {
        for (threadID, mode) in snapshot.rightPanelModesByThreadID {
            try upsertRightPanelModeStatement(threadID: threadID, mode: mode)
        }
    }

    private func saveRightPanelStates(_ snapshot: YAAWSnapshot) throws {
        // Only threads with explicitly-tracked panel state are persisted; threads
        // absent from the dictionary load their defaults via the load fallback,
        // matching the old behavior without writing N redundant default rows.
        for (threadID, state) in snapshot.rightPanelStatesByThreadID {
            try writeRightPanelState(threadID: threadID, state: state)
        }
    }

    private func saveBottomTerminalState(_ snapshot: YAAWSnapshot) throws {
        // Only expanded threads get a row (collapsed is the absence of a row).
        for threadID in snapshot.bottomTerminalExpandedThreadIDs {
            try setBottomTerminalExpandedStatement(threadID: threadID, isExpanded: true)
        }
    }

    private func saveFileIndexMetadata(_ snapshot: YAAWSnapshot) throws {
        for metadata in snapshot.fileIndexMetadataByThreadID.values {
            try upsertFileIndexMetadataStatement(metadata)
        }
    }

    private func saveThreadActivity(_ snapshot: YAAWSnapshot) throws {
        for activity in snapshot.threadActivityByThreadID.values {
            try upsertThreadActivityStatement(activity)
        }
    }

    private func saveSidebarProjectState(_ snapshot: YAAWSnapshot) throws {
        for project in snapshot.projects {
            try upsertSidebarProjectState(
                projectID: project.id,
                isExpanded: snapshot.expandedProjectIDs.contains(project.id),
                isArchiveExpanded: snapshot.expandedArchivedProjectIDs.contains(project.id)
            )
        }
    }

    private func saveAppState(_ snapshot: YAAWSnapshot) throws {
        try upsertAppStateStatement(
            key: "selected_project_id", value: snapshot.selectedProjectID.uuidString)
        try setSelectedThreadStatement(snapshot.selectedThreadID)
        try upsertAppStateStatement(
            key: "is_global_terminal_expanded",
            value: snapshot.isGlobalTerminalExpanded ? "true" : "false"
        )
    }

    func saveLayoutState(_ layoutState: LayoutState) throws {
        try upsertLayoutStateValue(key: "sidebar_width", value: "\(layoutState.sidebarWidth)")
        try upsertLayoutStateValue(
            key: "right_panel_width", value: "\(layoutState.rightPanelWidth)")
        try upsertLayoutStateValue(
            key: "global_terminal_height", value: "\(layoutState.globalTerminalHeight)")
        try upsertLayoutStateValue(
            key: "sidebar_collapsed", value: layoutState.isSidebarCollapsed ? "true" : "false")
        try upsertLayoutStateValue(
            key: "right_panel_collapsed",
            value: layoutState.isRightPanelCollapsed ? "true" : "false"
        )
        try upsertLayoutStateValue(
            key: "global_terminal_expanded",
            value: layoutState.isGlobalTerminalExpanded ? "true" : "false"
        )
        try upsertLayoutStateValue(
            key: "workspace_swapped",
            value: layoutState.isWorkspaceSwapped ? "true" : "false"
        )
    }
}

// MARK: - Incremental operations

extension SQLiteYAAWStore {
    /// Inserts or updates a single project row.
    public func upsertProject(_ project: Project) {
        runIncremental(name: "upsert_project") {
            try upsertProjectStatement(project)
        }
    }

    /// Inserts or updates a single thread row.
    public func upsertThread(_ thread: AgentThread) {
        runIncremental(name: "upsert_thread") {
            try upsertThreadStatement(thread)
        }
    }

    /// Deletes a thread by ID, cascading to its child rows.
    public func deleteThread(id: UUID) {
        runIncremental(name: "delete_thread") {
            let statement = try cachedPrepare("DELETE FROM threads WHERE id = ?")
            defer { try? resetStatement(statement) }
            bind(id.uuidString, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    /// Persists the right-panel mode for a thread.
    public func setRightPanelMode(threadID: UUID, mode: RightPanelMode) {
        runIncremental(name: "set_right_panel_mode") {
            try upsertRightPanelModeStatement(threadID: threadID, mode: mode)
        }
    }

    /// Persists the full right-panel state (tabs, folders, selection) for a thread.
    public func setRightPanelState(threadID: UUID, state: RightPanelState) {
        runIncremental(name: "set_right_panel_state") {
            try writeRightPanelState(threadID: threadID, state: state)
        }
    }

    /// Persists whether a thread's bottom terminal is expanded.
    public func setBottomTerminalExpanded(threadID: UUID, isExpanded: Bool) {
        runIncremental(name: "set_bottom_terminal_expanded") {
            try setBottomTerminalExpandedStatement(threadID: threadID, isExpanded: isExpanded)
        }
    }

    /// Persists the selected project.
    public func setSelectedProject(_ projectID: UUID) {
        runIncremental(name: "set_selected_project") {
            try upsertAppStateStatement(key: "selected_project_id", value: projectID.uuidString)
        }
    }

    /// Persists the selected thread, or clears it when `nil`.
    public func setSelectedThread(_ threadID: UUID?) {
        runIncremental(name: "set_selected_thread") {
            try setSelectedThreadStatement(threadID)
        }
    }

    /// Persists a selection change in one transaction: any touched project/thread
    /// rows, the optionally expanded project, and the selected project/thread.
    public func persistSelectionChange(
        selectedProjectID: UUID,
        selectedThreadID: UUID?,
        touchedProject: Project?,
        touchedThread: AgentThread?,
        expandedProjectID: UUID?
    ) {
        runIncremental(name: "persist_selection_change") {
            if let touchedProject {
                try upsertProjectStatement(touchedProject)
            }
            if let touchedThread {
                try upsertThreadStatement(touchedThread)
            }
            if let expandedProjectID {
                try setProjectExpandedStatement(projectID: expandedProjectID, isExpanded: true)
            }
            try upsertAppStateStatement(
                key: "selected_project_id", value: selectedProjectID.uuidString)
            try setSelectedThreadStatement(selectedThreadID)
        }
    }

    /// Persists the workspace layout state (split sizes and collapse flags).
    public func setLayoutState(_ state: LayoutState) {
        runIncremental(name: "set_layout_state") {
            try saveLayoutState(state)
        }
    }

    /// Persists whether a project's sidebar row is expanded, preserving its
    /// archive-expanded flag.
    public func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        runIncremental(name: "set_project_expanded") {
            try setProjectExpandedStatement(projectID: projectID, isExpanded: isExpanded)
        }
    }

    /// Persists whether a project's archived-threads section is expanded,
    /// preserving its expanded flag.
    public func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool) {
        runIncremental(name: "set_project_archive_expanded") {
            let currentExpandedState =
                try Self.loadSidebarProjectState(database, projectID: projectID)?.isExpanded
                ?? false
            try upsertSidebarProjectState(
                projectID: projectID,
                isExpanded: currentExpandedState,
                isArchiveExpanded: isExpanded
            )
        }
    }

    /// Inserts or updates a thread's file-index metadata row.
    public func upsertFileIndexMetadata(_ metadata: FileIndexMetadata) {
        runIncremental(name: "upsert_file_index_metadata") {
            try upsertFileIndexMetadataStatement(metadata)
        }
    }

    /// Inserts or updates a thread's activity-state row.
    public func upsertThreadActivity(_ activity: ThreadActivityState) {
        runIncremental(name: "upsert_thread_activity") {
            try upsertThreadActivityStatement(activity)
        }
    }

    /// Replaces the shared cached file index for one cache key: clears its prior
    /// entries, then writes the new metadata and ordered entries. No-op when the
    /// index has no cache key.
    public func upsertCachedFileIndex(_ index: CachedFileIndex) {
        runIncremental(name: "upsert_cached_file_index") {
            guard let cacheKey = index.metadata.cacheKey else { return }
            try deleteCachedFileIndexEntries(cacheKey: cacheKey)
            try upsertCachedFileIndexMetadata(index.metadata)
            for (entryOrder, entry) in index.entries.enumerated() {
                try insertCachedFileIndexEntry(
                    cacheKey: cacheKey, entry: entry, entryOrder: entryOrder)
            }
        }
    }

    // Persists the selected thread (or clears it) within an existing transaction;
    // shared by setSelectedThread, persistSelectionChange, and full save.
    func setSelectedThreadStatement(_ threadID: UUID?) throws {
        if let threadID {
            try upsertAppStateStatement(key: "selected_thread_id", value: threadID.uuidString)
        } else {
            let statement = try cachedPrepare("DELETE FROM app_state WHERE key = ?")
            defer { try? resetStatement(statement) }
            bind("selected_thread_id", at: 1, in: statement)
            try stepDone(statement)
        }
    }

    // Marks a project expanded within an existing transaction, preserving its
    // archive-expanded flag; shared by setProjectExpanded and persistSelectionChange.
    func setProjectExpandedStatement(projectID: UUID, isExpanded: Bool) throws {
        let currentArchiveState =
            try Self.loadSidebarProjectState(database, projectID: projectID)?.isArchiveExpanded
            ?? false
        try upsertSidebarProjectState(
            projectID: projectID,
            isExpanded: isExpanded,
            isArchiveExpanded: currentArchiveState
        )
    }
}
