import Foundation
import SQLite3

// Cached-statement row writers shared by full `save` and the incremental ops.
// Each helper draws its statement from `cachedPrepare`, binds, steps, and
// `resetStatement`s it for the next reuse — it never finalizes (the cache owns
// the statement and finalizes it in `deinit`).
extension SQLiteYAAWStore {
    func upsertProjectStatement(_ project: Project) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO projects (
                id,
                display_name,
                root_directory,
                created_at,
                last_opened_at,
                is_pinned,
                sort_order,
                is_archived
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                root_directory = excluded.root_directory,
                created_at = excluded.created_at,
                last_opened_at = excluded.last_opened_at,
                is_pinned = excluded.is_pinned,
                sort_order = excluded.sort_order,
                is_archived = excluded.is_archived
            """
        )
        defer { try? resetStatement(statement) }
        bind(project.id.uuidString, at: 1, in: statement)
        bind(project.displayName, at: 2, in: statement)
        bind(project.rootDirectory.path, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, project.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, project.lastOpenedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 6, project.isPinned ? 1 : 0)
        sqlite3_bind_int(statement, 7, Int32(project.sortOrder))
        sqlite3_bind_int(statement, 8, project.isArchived ? 1 : 0)
        try stepDone(statement)
    }

    func upsertThreadStatement(_ thread: AgentThread) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO threads (
                id,
                display_name,
                project_id,
                working_directory,
                created_at,
                last_opened_at,
                is_archived,
                agent_cli,
                session_identity,
                canonical_session_name,
                pending_session_rename,
                is_pinned,
                launch_options_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                project_id = excluded.project_id,
                working_directory = excluded.working_directory,
                created_at = excluded.created_at,
                last_opened_at = excluded.last_opened_at,
                is_archived = excluded.is_archived,
                agent_cli = excluded.agent_cli,
                session_identity = excluded.session_identity,
                canonical_session_name = excluded.canonical_session_name,
                pending_session_rename = excluded.pending_session_rename,
                is_pinned = excluded.is_pinned,
                launch_options_json = excluded.launch_options_json
            """
        )
        defer { try? resetStatement(statement) }
        bind(thread.id.uuidString, at: 1, in: statement)
        bind(thread.displayName, at: 2, in: statement)
        bind(thread.projectID.uuidString, at: 3, in: statement)
        bind(thread.workingDirectory.path, at: 4, in: statement)
        sqlite3_bind_double(statement, 5, thread.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, thread.lastOpenedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 7, thread.isArchived ? 1 : 0)
        bind(thread.agentCLI.rawValue, at: 8, in: statement)
        bindOptional(thread.sessionIdentity, at: 9, in: statement)
        bindOptional(thread.canonicalSessionName, at: 10, in: statement)
        bindOptional(thread.pendingSessionRename, at: 11, in: statement)
        sqlite3_bind_int(statement, 12, thread.isPinned ? 1 : 0)
        bindOptional(launchOptionsJSON(for: thread), at: 13, in: statement)
        try stepDone(statement)
    }

    func upsertRightPanelModeStatement(threadID: UUID, mode: RightPanelMode) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO right_panel_modes (thread_id, mode) VALUES (?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET mode = excluded.mode
            """
        )
        defer { try? resetStatement(statement) }
        bind(threadID.uuidString, at: 1, in: statement)
        bind(mode.rawValue, at: 2, in: statement)
        try stepDone(statement)
    }

    /// Rewrites the persisted right-panel tabs and selected tab for one thread.
    /// Old tabs are deleted and the normalized tab set is reinserted with a
    /// contiguous `tab_order` (0, 1, 2, …) — combined with the v17 index this is
    /// what makes tab order stable across save→load cycles. The selected tab id
    /// is UPSERTed.
    func writeRightPanelState(threadID: UUID, state: RightPanelState) throws {
        let deleteStatement = try cachedPrepare(
            "DELETE FROM right_panel_tabs WHERE thread_id = ?")
        bind(threadID.uuidString, at: 1, in: deleteStatement)
        try stepDone(deleteStatement)
        try resetStatement(deleteStatement)

        let persistedState = state.persistenceSnapshot
        let tabs = RightPanelState.normalizedTabs(persistedState.tabs)
        let insertStatement = try cachedPrepare(
            """
            INSERT INTO right_panel_tabs (
                thread_id, tab_id, kind, title, relative_path, url_string, tab_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        for (index, tab) in tabs.enumerated() {
            bind(threadID.uuidString, at: 1, in: insertStatement)
            bind(tab.id, at: 2, in: insertStatement)
            bind(tab.kind.rawValue, at: 3, in: insertStatement)
            bind(tab.title, at: 4, in: insertStatement)
            bindOptional(tab.relativePath, at: 5, in: insertStatement)
            bindOptional(tab.urlString, at: 6, in: insertStatement)
            sqlite3_bind_int(insertStatement, 7, Int32(index))
            try stepDone(insertStatement)
            try resetStatement(insertStatement)
        }

        let stateStatement = try cachedPrepare(
            """
            INSERT INTO right_panel_tab_state (thread_id, selected_tab_id) VALUES (?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET selected_tab_id = excluded.selected_tab_id
            """
        )
        defer { try? resetStatement(stateStatement) }
        bind(threadID.uuidString, at: 1, in: stateStatement)
        bind(persistedState.selectedTabID, at: 2, in: stateStatement)
        try stepDone(stateStatement)
    }

    func setBottomTerminalExpandedStatement(threadID: UUID, isExpanded: Bool) throws {
        if isExpanded {
            let statement = try cachedPrepare(
                """
                INSERT INTO bottom_terminal_state (thread_id, is_expanded) VALUES (?, 1)
                ON CONFLICT(thread_id) DO UPDATE SET is_expanded = 1
                """
            )
            defer { try? resetStatement(statement) }
            bind(threadID.uuidString, at: 1, in: statement)
            try stepDone(statement)
        } else {
            let statement = try cachedPrepare(
                "DELETE FROM bottom_terminal_state WHERE thread_id = ?")
            defer { try? resetStatement(statement) }
            bind(threadID.uuidString, at: 1, in: statement)
            try stepDone(statement)
        }
    }

    func upsertAppStateStatement(key: String, value: String) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO app_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { try? resetStatement(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    func upsertLayoutStateValue(key: String, value: String) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO layout_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { try? resetStatement(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    func upsertSidebarProjectState(
        projectID: UUID, isExpanded: Bool, isArchiveExpanded: Bool
    ) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO sidebar_project_state (
                project_id,
                is_expanded,
                is_archive_expanded
            )
            VALUES (?, ?, ?)
            ON CONFLICT(project_id) DO UPDATE SET
                is_expanded = excluded.is_expanded,
                is_archive_expanded = excluded.is_archive_expanded
            """
        )
        defer { try? resetStatement(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, isExpanded ? 1 : 0)
        sqlite3_bind_int(statement, 3, isArchiveExpanded ? 1 : 0)
        try stepDone(statement)
    }

    func upsertFileIndexMetadataStatement(_ metadata: FileIndexMetadata) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO file_index_metadata (
                thread_id,
                cache_key,
                root_path,
                git_identity,
                ignore_rules_fingerprint,
                schema_version,
                indexed_at,
                file_count,
                ignored_directory_count
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
                cache_key = excluded.cache_key,
                root_path = excluded.root_path,
                git_identity = excluded.git_identity,
                ignore_rules_fingerprint = excluded.ignore_rules_fingerprint,
                schema_version = excluded.schema_version,
                indexed_at = excluded.indexed_at,
                file_count = excluded.file_count,
                ignored_directory_count = excluded.ignored_directory_count
            """
        )
        defer { try? resetStatement(statement) }
        bind(metadata.threadID.uuidString, at: 1, in: statement)
        bindOptional(metadata.cacheKey, at: 2, in: statement)
        bind(metadata.rootPath, at: 3, in: statement)
        bind(metadata.gitIdentity, at: 4, in: statement)
        bind(metadata.ignoreRulesFingerprint, at: 5, in: statement)
        sqlite3_bind_int(statement, 6, Int32(metadata.schemaVersion))
        sqlite3_bind_double(statement, 7, metadata.indexedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 8, Int32(metadata.fileCount))
        sqlite3_bind_int(statement, 9, Int32(metadata.ignoredDirectoryCount))
        try stepDone(statement)
    }

    func upsertThreadActivityStatement(_ activity: ThreadActivityState) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO thread_activity_state (
                thread_id,
                status,
                preview,
                is_unread,
                title,
                body,
                source,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
                status = excluded.status,
                preview = excluded.preview,
                is_unread = excluded.is_unread,
                title = excluded.title,
                body = excluded.body,
                source = excluded.source,
                updated_at = excluded.updated_at
            """
        )
        defer { try? resetStatement(statement) }
        bind(activity.threadID.uuidString, at: 1, in: statement)
        bind(activity.status.rawValue, at: 2, in: statement)
        bindOptional(activity.preview, at: 3, in: statement)
        sqlite3_bind_int(statement, 4, activity.isUnread ? 1 : 0)
        bindOptional(activity.title, at: 5, in: statement)
        bindOptional(activity.body, at: 6, in: statement)
        bind(activity.source.rawValue, at: 7, in: statement)
        sqlite3_bind_double(statement, 8, activity.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    func deleteCachedFileIndexEntries(cacheKey: String) throws {
        let statement = try cachedPrepare(
            "DELETE FROM file_index_cache_entries WHERE cache_key = ?")
        defer { try? resetStatement(statement) }
        bind(cacheKey, at: 1, in: statement)
        try stepDone(statement)
    }

    func upsertCachedFileIndexMetadata(_ metadata: FileIndexMetadata) throws {
        guard let cacheKey = metadata.cacheKey else { return }
        let statement = try cachedPrepare(
            """
            INSERT INTO file_index_cache_metadata (
                cache_key,
                root_path,
                git_identity,
                ignore_rules_fingerprint,
                schema_version,
                indexed_at,
                file_count,
                ignored_directory_count
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(cache_key) DO UPDATE SET
                root_path = excluded.root_path,
                git_identity = excluded.git_identity,
                ignore_rules_fingerprint = excluded.ignore_rules_fingerprint,
                schema_version = excluded.schema_version,
                indexed_at = excluded.indexed_at,
                file_count = excluded.file_count,
                ignored_directory_count = excluded.ignored_directory_count
            """
        )
        defer { try? resetStatement(statement) }
        bind(cacheKey, at: 1, in: statement)
        bind(metadata.rootPath, at: 2, in: statement)
        bind(metadata.gitIdentity, at: 3, in: statement)
        bind(metadata.ignoreRulesFingerprint, at: 4, in: statement)
        sqlite3_bind_int(statement, 5, Int32(metadata.schemaVersion))
        sqlite3_bind_double(statement, 6, metadata.indexedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 7, Int32(metadata.fileCount))
        sqlite3_bind_int(statement, 8, Int32(metadata.ignoredDirectoryCount))
        try stepDone(statement)
    }

    func insertCachedFileIndexEntry(
        cacheKey: String, entry: FileBrowserEntry, entryOrder: Int
    ) throws {
        let statement = try cachedPrepare(
            """
            INSERT INTO file_index_cache_entries (
                cache_key,
                relative_path,
                is_directory,
                entry_order
            )
            VALUES (?, ?, ?, ?)
            """
        )
        defer { try? resetStatement(statement) }
        bind(cacheKey, at: 1, in: statement)
        bind(entry.relativePath, at: 2, in: statement)
        sqlite3_bind_int(statement, 3, entry.isDirectory ? 1 : 0)
        sqlite3_bind_int(statement, 4, Int32(entryOrder))
        try stepDone(statement)
    }
}

// One-shot insert helpers used only by the migration ladder (seed paths). They
// are `nonisolated` + handle-parameterized (the ladder runs in the synchronous
// `init`) and use `prepare`/`finalize` rather than the cache: migrations run
// once at startup against a small row set, and some seed tables may be
// dropped/renamed by a later migration step in the same `migrate()` pass.
extension SQLiteYAAWStore {
    nonisolated static func insertBottomTerminalState(
        _ database: OpaquePointer?, threadID: UUID, isExpanded: Bool
    ) throws {
        let statement = try prepare(
            database, "INSERT INTO bottom_terminal_state (thread_id, is_expanded) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        bind(threadID.uuidString, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, isExpanded ? 1 : 0)
        try stepDone(database, statement)
    }

    nonisolated static func insertSidebarProjectState(
        _ database: OpaquePointer?, projectID: UUID, isExpanded: Bool, isArchiveExpanded: Bool
    ) throws {
        let statement = try prepare(
            database,
            """
            INSERT INTO sidebar_project_state (
                project_id,
                is_expanded,
                is_archive_expanded
            )
            VALUES (?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, isExpanded ? 1 : 0)
        sqlite3_bind_int(statement, 3, isArchiveExpanded ? 1 : 0)
        try stepDone(database, statement)
    }

    nonisolated static func insertRightPanelState(
        _ database: OpaquePointer?, threadID: UUID, state: RightPanelState
    ) throws {
        let persistedState = state.persistenceSnapshot
        let tabs = RightPanelState.normalizedTabs(persistedState.tabs)
        for (index, tab) in tabs.enumerated() {
            let statement = try prepare(
                database,
                """
                INSERT INTO right_panel_tabs (
                    thread_id,
                    tab_id,
                    kind,
                    title,
                    relative_path,
                    url_string,
                    tab_order
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(threadID.uuidString, at: 1, in: statement)
            bind(tab.id, at: 2, in: statement)
            bind(tab.kind.rawValue, at: 3, in: statement)
            bind(tab.title, at: 4, in: statement)
            bindOptional(tab.relativePath, at: 5, in: statement)
            bindOptional(tab.urlString, at: 6, in: statement)
            sqlite3_bind_int(statement, 7, Int32(index))
            try stepDone(database, statement)
        }

        let stateStatement = try prepare(
            database, "INSERT INTO right_panel_tab_state (thread_id, selected_tab_id) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(stateStatement) }
        bind(threadID.uuidString, at: 1, in: stateStatement)
        bind(persistedState.selectedTabID, at: 2, in: stateStatement)
        try stepDone(database, stateStatement)
    }

    nonisolated static func insertLayoutState(
        _ database: OpaquePointer?, _ layoutState: LayoutState
    ) throws {
        try insertLayoutStateValue(
            database, key: "sidebar_width", value: "\(layoutState.sidebarWidth)")
        try insertLayoutStateValue(
            database, key: "right_panel_width", value: "\(layoutState.rightPanelWidth)")
        try insertLayoutStateValue(
            database, key: "global_terminal_height", value: "\(layoutState.globalTerminalHeight)")
        try insertLayoutStateValue(
            database, key: "sidebar_collapsed",
            value: layoutState.isSidebarCollapsed ? "true" : "false")
        try insertLayoutStateValue(
            database, key: "right_panel_collapsed",
            value: layoutState.isRightPanelCollapsed ? "true" : "false"
        )
        try insertLayoutStateValue(
            database, key: "global_terminal_expanded",
            value: layoutState.isGlobalTerminalExpanded ? "true" : "false"
        )
        try insertLayoutStateValue(
            database, key: "workspace_swapped",
            value: layoutState.isWorkspaceSwapped ? "true" : "false"
        )
    }

    nonisolated static func insertLayoutStateValue(
        _ database: OpaquePointer?, key: String, value: String
    )
        throws
    {
        let statement = try prepare(database, "INSERT INTO layout_state (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(database, statement)
    }
}
