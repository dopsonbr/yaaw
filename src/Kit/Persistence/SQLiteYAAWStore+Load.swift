import Foundation
import SQLite3

// Read helpers are `nonisolated` and handle-parameterized so the migration
// ladder (which runs in the synchronous `init`) and the isolated `load()` path
// can share them. They compile one-shot statements (no cache) and touch only
// the passed handle and pure value types.
extension SQLiteYAAWStore {
    /// Reassembles a full `YAAWSnapshot` from the database. An empty `projects`
    /// table is treated as first launch: the Global "Hello World" seed is saved
    /// and returned. Any thrown error degrades to the in-memory seed and records
    /// a diagnostic, so a corrupt database never deadlocks startup.
    public func load() -> YAAWSnapshot {
        let database = database
        do {
            let projects = try Self.loadProjects(database)
            if projects.isEmpty {
                let seed = InMemoryYAAWStore.helloWorldSnapshot()
                save(seed)
                return seed
            }

            let threads = try Self.loadThreads(database)
            let selectedProjectID =
                try Self.loadUUID(database, key: "selected_project_id") ?? projects[0].id
            let selectedThreadID =
                try Self.loadUUID(database, key: "selected_thread_id")
                ?? threads.first { $0.projectID == selectedProjectID && !$0.isArchived }?.id
            let modes = try Self.loadRightPanelModes(database)
            let rightPanelStates = try Self.loadRightPanelStates(
                database, fallbackModes: modes, threads: threads)
            let selectedMode =
                selectedThreadID.map { rightPanelStates[$0]?.selectedMode ?? modes[$0] ?? .files }
                ?? .files
            let fallbackGlobalTerminalExpanded =
                try Self.loadBool(database, key: "is_global_terminal_expanded") ?? false
            let layoutState = try Self.loadLayoutState(
                database, fallbackGlobalTerminalExpanded: fallbackGlobalTerminalExpanded
            )
            let fileIndexMetadata = try Self.loadFileIndexMetadata(database)
            let threadActivity = try Self.loadThreadActivity(database)
            let bottomTerminalExpandedThreadIDs =
                try Self.loadBottomTerminalExpandedThreadIDs(database)
            let sidebarProjectState = try Self.loadSidebarProjectState(database)

            return YAAWSnapshot(
                projects: projects,
                threads: threads,
                selectedProjectID: selectedProjectID,
                selectedThreadID: selectedThreadID,
                rightPanelModesByThreadID: modes,
                rightPanelStatesByThreadID: rightPanelStates,
                selectedRightPanelMode: selectedMode,
                bottomTerminalExpandedThreadIDs: bottomTerminalExpandedThreadIDs,
                isGlobalTerminalExpanded: layoutState.isGlobalTerminalExpanded,
                layoutState: layoutState,
                fileIndexMetadataByThreadID: fileIndexMetadata,
                threadActivityByThreadID: threadActivity,
                expandedProjectIDs: sidebarProjectState.expandedProjectIDs,
                expandedArchivedProjectIDs: sidebarProjectState.expandedArchivedProjectIDs
            )
        } catch {
            recordSQLiteError(name: "sqlite_load_failed", error: error)
            return InMemoryYAAWStore.helloWorldSnapshot()
        }
    }

    public func cachedFileIndex(cacheKey: String) -> CachedFileIndex? {
        do {
            return try Self.loadCachedFileIndex(database, cacheKey: cacheKey)
        } catch {
            recordSQLiteError(name: "sqlite_load_cached_file_index_failed", error: error)
            return nil
        }
    }

    nonisolated static func loadProjects(_ database: OpaquePointer?) throws -> [Project] {
        let statement = try prepare(
            database,
            """
            SELECT
                id,
                display_name,
                root_directory,
                created_at,
                last_opened_at,
                is_pinned,
                sort_order,
                is_archived
            FROM projects
            ORDER BY
                CASE WHEN display_name = 'Global' THEN 1 ELSE 0 END,
                is_pinned DESC,
                sort_order,
                created_at,
                display_name
            """
        )
        defer { sqlite3_finalize(statement) }
        var projects: [Project] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, in: statement)) else {
                throw SQLiteStoreError.executionFailed("Invalid project id")
            }
            projects.append(
                Project(
                    id: id,
                    displayName: text(at: 1, in: statement),
                    rootDirectory: URL(
                        fileURLWithPath: text(at: 2, in: statement), isDirectory: true),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    isPinned: sqlite3_column_int(statement, 5) == 1,
                    sortOrder: Int(sqlite3_column_int(statement, 6)),
                    isArchived: sqlite3_column_int(statement, 7) == 1
                )
            )
        }
        return projects
    }

    nonisolated static func loadThreads(_ database: OpaquePointer?) throws -> [AgentThread] {
        let statement = try prepare(
            database,
            """
            SELECT
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
            FROM threads
            ORDER BY created_at, display_name
            """
        )
        defer { sqlite3_finalize(statement) }
        var threads: [AgentThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, in: statement)),
                let projectID = UUID(uuidString: text(at: 2, in: statement)),
                let agentCLI = AgentCLIKind(rawValue: text(at: 7, in: statement))
            else {
                throw SQLiteStoreError.executionFailed("Invalid thread id")
            }
            threads.append(
                AgentThread(
                    id: id,
                    displayName: text(at: 1, in: statement),
                    projectID: projectID,
                    workingDirectory: URL(
                        fileURLWithPath: text(at: 3, in: statement), isDirectory: true),
                    agentCLI: agentCLI,
                    launchOptions: launchOptions(
                        fromJSON: optionalText(at: 12, in: statement),
                        agentCLI: agentCLI
                    ),
                    sessionIdentity: optionalText(at: 8, in: statement),
                    canonicalSessionName: optionalText(at: 9, in: statement),
                    pendingSessionRename: optionalText(at: 10, in: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    isArchived: sqlite3_column_int(statement, 6) == 1,
                    isPinned: sqlite3_column_int(statement, 11) == 1
                )
            )
        }
        return threads
    }

    nonisolated static func loadUUID(_ database: OpaquePointer?, key: String) throws -> UUID? {
        let statement = try prepare(database, "SELECT value FROM app_state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return UUID(uuidString: text(at: 0, in: statement))
    }

    nonisolated static func loadBool(_ database: OpaquePointer?, key: String) throws -> Bool? {
        let statement = try prepare(database, "SELECT value FROM app_state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        switch text(at: 0, in: statement) {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    nonisolated static func loadLayoutState(
        _ database: OpaquePointer?,
        fallbackGlobalTerminalExpanded: Bool
    ) throws -> LayoutState {
        LayoutState(
            sidebarWidth: try loadLayoutDouble(database, key: "sidebar_width")
                ?? LayoutState.defaultSidebarWidth,
            rightPanelWidth: try loadLayoutDouble(database, key: "right_panel_width")
                ?? LayoutState.defaultRightPanelWidth,
            globalTerminalHeight: try loadLayoutDouble(database, key: "global_terminal_height")
                ?? LayoutState.defaultGlobalTerminalHeight,
            isSidebarCollapsed: try loadLayoutBool(database, key: "sidebar_collapsed") ?? false,
            isRightPanelCollapsed: try loadLayoutBool(database, key: "right_panel_collapsed")
                ?? false,
            isGlobalTerminalExpanded: try loadLayoutBool(database, key: "global_terminal_expanded")
                ?? fallbackGlobalTerminalExpanded,
            isWorkspaceSwapped: try loadLayoutBool(database, key: "workspace_swapped") ?? false
        )
    }

    nonisolated static func loadLayoutDouble(_ database: OpaquePointer?, key: String) throws
        -> Double?
    {
        guard let value = try loadLayoutValue(database, key: key) else { return nil }
        return Double(value)
    }

    nonisolated static func loadLayoutBool(_ database: OpaquePointer?, key: String) throws -> Bool?
    {
        guard let value = try loadLayoutValue(database, key: key) else { return nil }
        switch value {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    nonisolated static func loadLayoutValue(_ database: OpaquePointer?, key: String) throws
        -> String?
    {
        let statement = try prepare(database, "SELECT value FROM layout_state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(at: 0, in: statement)
    }

    nonisolated static func loadRightPanelModes(_ database: OpaquePointer?) throws -> [UUID:
        RightPanelMode]
    {
        let statement = try prepare(database, "SELECT thread_id, mode FROM right_panel_modes")
        defer { sqlite3_finalize(statement) }
        var modes: [UUID: RightPanelMode] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let threadID = UUID(uuidString: text(at: 0, in: statement)),
                let mode = RightPanelMode(rawValue: text(at: 1, in: statement))
            {
                modes[threadID] = mode
            }
        }
        return modes
    }

    nonisolated static func loadRightPanelStates(
        _ database: OpaquePointer?,
        fallbackModes: [UUID: RightPanelMode],
        threads: [AgentThread]
    ) throws -> [UUID: RightPanelState] {
        let tabsStatement = try prepare(
            database,
            """
            SELECT thread_id, tab_id, kind, title, relative_path, url_string
            FROM right_panel_tabs
            ORDER BY thread_id, tab_order, title
            """
        )
        defer { sqlite3_finalize(tabsStatement) }
        var tabsByThreadID: [UUID: [RightPanelTab]] = [:]
        while sqlite3_step(tabsStatement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: tabsStatement)),
                let kind = RightPanelTabKind(rawValue: text(at: 2, in: tabsStatement))
            else {
                continue
            }
            tabsByThreadID[threadID, default: []].append(
                RightPanelTab(
                    id: text(at: 1, in: tabsStatement),
                    kind: kind,
                    title: text(at: 3, in: tabsStatement),
                    relativePath: optionalText(at: 4, in: tabsStatement),
                    urlString: optionalText(at: 5, in: tabsStatement)
                )
            )
        }

        let stateStatement = try prepare(
            database, "SELECT thread_id, selected_tab_id FROM right_panel_tab_state")
        defer { sqlite3_finalize(stateStatement) }
        var selectedTabIDsByThreadID: [UUID: String] = [:]
        while sqlite3_step(stateStatement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: stateStatement)) else { continue }
            selectedTabIDsByThreadID[threadID] = text(at: 1, in: stateStatement)
        }

        var states: [UUID: RightPanelState] = [:]
        for thread in threads {
            let tabs = tabsByThreadID[thread.id] ?? RightPanelState.defaultTabs
            let selectedTabID =
                selectedTabIDsByThreadID[thread.id]
                ?? fallbackModes[thread.id]?.defaultTabID
                ?? RightPanelTab.filesID
            states[thread.id] = RightPanelState.restoredState(
                tabs: tabs, selectedTabID: selectedTabID)
        }
        return states
    }

    nonisolated static func loadFileIndexMetadata(_ database: OpaquePointer?) throws -> [UUID:
        FileIndexMetadata]
    {
        let statement = try prepare(
            database,
            """
            SELECT
                thread_id,
                cache_key,
                root_path,
                git_identity,
                ignore_rules_fingerprint,
                schema_version,
                indexed_at,
                file_count,
                ignored_directory_count
            FROM file_index_metadata
            """
        )
        defer { sqlite3_finalize(statement) }
        var metadataByThreadID: [UUID: FileIndexMetadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: statement)) else {
                throw SQLiteStoreError.executionFailed("Invalid file index thread id")
            }
            metadataByThreadID[threadID] = FileIndexMetadata(
                threadID: threadID,
                cacheKey: optionalText(at: 1, in: statement),
                rootPath: text(at: 2, in: statement),
                gitIdentity: text(at: 3, in: statement),
                ignoreRulesFingerprint: text(at: 4, in: statement),
                schemaVersion: Int(sqlite3_column_int(statement, 5)),
                indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                fileCount: Int(sqlite3_column_int(statement, 7)),
                ignoredDirectoryCount: Int(sqlite3_column_int(statement, 8))
            )
        }
        return metadataByThreadID
    }

    nonisolated static func loadThreadActivity(_ database: OpaquePointer?) throws -> [UUID:
        ThreadActivityState]
    {
        let statement = try prepare(
            database,
            """
            SELECT
                thread_id,
                status,
                preview,
                is_unread,
                title,
                body,
                source,
                updated_at
            FROM thread_activity_state
            """
        )
        defer { sqlite3_finalize(statement) }
        var activityByThreadID: [UUID: ThreadActivityState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadID = UUID(uuidString: text(at: 0, in: statement)),
                let status = ThreadActivityStatus(rawValue: text(at: 1, in: statement)),
                let source = ThreadActivitySource(rawValue: text(at: 6, in: statement))
            else {
                throw SQLiteStoreError.executionFailed("Invalid thread activity state")
            }
            activityByThreadID[threadID] = ThreadActivityState(
                threadID: threadID,
                status: status,
                preview: optionalText(at: 2, in: statement),
                isUnread: sqlite3_column_int(statement, 3) == 1,
                title: optionalText(at: 4, in: statement),
                body: optionalText(at: 5, in: statement),
                source: source,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
        }
        return activityByThreadID
    }

    nonisolated static func loadBottomTerminalExpandedThreadIDs(_ database: OpaquePointer?) throws
        -> Set<
            UUID
        >
    {
        let statement = try prepare(
            database, "SELECT thread_id FROM bottom_terminal_state WHERE is_expanded = 1"
        )
        defer { sqlite3_finalize(statement) }
        var threadIDs = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(at: 0, in: statement)) {
                threadIDs.insert(id)
            }
        }
        return threadIDs
    }

    nonisolated static func loadSidebarProjectState(_ database: OpaquePointer?) throws
        -> SidebarProjectStateSnapshot
    {
        let statement = try prepare(
            database,
            "SELECT project_id, is_expanded, is_archive_expanded FROM sidebar_project_state"
        )
        defer { sqlite3_finalize(statement) }
        var expandedProjectIDs = Set<UUID>()
        var expandedArchivedProjectIDs = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(at: 0, in: statement)) else { continue }
            if sqlite3_column_int(statement, 1) == 1 {
                expandedProjectIDs.insert(id)
            }
            if sqlite3_column_int(statement, 2) == 1 {
                expandedArchivedProjectIDs.insert(id)
            }
        }
        return SidebarProjectStateSnapshot(
            expandedProjectIDs: expandedProjectIDs,
            expandedArchivedProjectIDs: expandedArchivedProjectIDs
        )
    }

    nonisolated static func loadSidebarProjectState(_ database: OpaquePointer?, projectID: UUID)
        throws
        -> SidebarProjectStateRow?
    {
        let statement = try prepare(
            database,
            "SELECT is_expanded, is_archive_expanded FROM sidebar_project_state WHERE project_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return SidebarProjectStateRow(
            isExpanded: sqlite3_column_int(statement, 0) == 1,
            isArchiveExpanded: sqlite3_column_int(statement, 1) == 1
        )
    }

    nonisolated static func loadCachedFileIndex(_ database: OpaquePointer?, cacheKey: String) throws
        -> CachedFileIndex?
    {
        let metadataStatement = try prepare(
            database,
            """
            SELECT
                root_path,
                git_identity,
                ignore_rules_fingerprint,
                schema_version,
                indexed_at,
                file_count,
                ignored_directory_count
            FROM file_index_cache_metadata
            WHERE cache_key = ?
            """
        )
        defer { sqlite3_finalize(metadataStatement) }
        bind(cacheKey, at: 1, in: metadataStatement)
        guard sqlite3_step(metadataStatement) == SQLITE_ROW else { return nil }
        let metadata = FileIndexMetadata(
            threadID: UUID(),
            cacheKey: cacheKey,
            rootPath: text(at: 0, in: metadataStatement),
            gitIdentity: text(at: 1, in: metadataStatement),
            ignoreRulesFingerprint: text(at: 2, in: metadataStatement),
            schemaVersion: Int(sqlite3_column_int(metadataStatement, 3)),
            indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(metadataStatement, 4)),
            fileCount: Int(sqlite3_column_int(metadataStatement, 5)),
            ignoredDirectoryCount: Int(sqlite3_column_int(metadataStatement, 6))
        )

        let entriesStatement = try prepare(
            database,
            """
            SELECT relative_path, is_directory
            FROM file_index_cache_entries
            WHERE cache_key = ?
            ORDER BY entry_order, relative_path
            """
        )
        defer { sqlite3_finalize(entriesStatement) }
        bind(cacheKey, at: 1, in: entriesStatement)
        var entries: [FileBrowserEntry] = []
        while sqlite3_step(entriesStatement) == SQLITE_ROW {
            entries.append(
                FileBrowserEntry(
                    relativePath: text(at: 0, in: entriesStatement),
                    isDirectory: sqlite3_column_int(entriesStatement, 1) == 1
                )
            )
        }
        return CachedFileIndex(metadata: metadata, entries: entries)
    }
}
