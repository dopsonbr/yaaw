# Chunk A — PersistenceActor Specification

## Overview

`PersistenceActor` is an actor-safe wrapper around the raw C-based SQLite3 API, replacing the current god-object coupling with a focused, thread-safe, and high-performance persistence layer. The actor:

- **Preserves** the 16-step migration ladder (v1 → v16) and WAL transaction safety
- **Hardens** incremental operations with prepared-statement caching and UPSERT queries (vs. DELETE+INSERT)
- **Adds** migration v16 → v17 for any schema evolution needs (indexed queries for right-panel-tabs loads)
- **Fixes** the regression: right-panel-tabs save/load asymmetry (persisted tab state now survives relaunch)
- **Meets** strict concurrency: all SQLite access is serialized through the actor boundary; no `@unchecked Sendable` escapes

## Module & Visibility

- **Target:** `YAAWKit` (the library, not the app)
- **Public types:** 
  - `YAAWStore` protocol (existing; unchanged API surface)
  - `SQLiteYAAWStore` class (actor-wrapped; maintains class semantics for storage)
  - `SQLiteStoreError` enum (existing)
- **Internal actor:** `PersistenceActor` (isolated to this module; not exposed)

## Schema (13 tables, indexed at v16)

The store currently manages **13 tables**:

```
1. projects
   - id TEXT PK
   - display_name, root_directory, created_at, last_opened_at
   - is_pinned (v11), sort_order (v11), is_archived (v16)

2. threads
   - id TEXT PK
   - display_name, project_id FK, working_directory
   - created_at, last_opened_at, is_archived
   - agent_cli (v2), session_identity (v4), canonical_session_name (v4)
   - pending_session_rename (v14), is_pinned (v11), launch_options_json (v15)

3. app_state
   - key TEXT PK, value TEXT
   - stores: selected_project_id, selected_thread_id, is_global_terminal_expanded

4. layout_state (v3)
   - key TEXT PK, value TEXT
   - stores: sidebar_width, right_panel_width, global_terminal_height
   - isSidebarCollapsed, isRightPanelCollapsed, isGlobalTerminalExpanded, isWorkspaceSwapped

5. right_panel_modes (v1)
   - thread_id TEXT PK, mode TEXT (files|browser|nvim|git)

6. right_panel_tabs (v8, refactored v13)
   - thread_id TEXT FK, tab_id TEXT
   - kind TEXT (files|browser|git|nvim), title TEXT
   - relative_path TEXT, url_string TEXT, tab_order INT
   - PK(thread_id, tab_id)

7. right_panel_tab_state (v8)
   - thread_id TEXT PK, selected_tab_id TEXT

8. bottom_terminal_state (v7)
   - thread_id TEXT PK, is_expanded INT (0|1)

9. sidebar_project_state (v11)
   - project_id TEXT PK
   - is_expanded INT, is_archive_expanded INT

10. file_index_metadata (v5)
    - thread_id TEXT PK
    - cache_key, root_path, git_identity, ignore_rules_fingerprint (v10)
    - schema_version (v10), indexed_at, file_count, ignored_directory_count

11. file_index_cache_metadata (v10)
    - cache_key TEXT PK
    - root_path, git_identity, ignore_rules_fingerprint
    - schema_version, indexed_at, file_count, ignored_directory_count

12. file_index_cache_entries (v10)
    - cache_key TEXT FK, relative_path TEXT
    - is_directory INT, entry_order INT
    - PK(cache_key, relative_path)
    - INDEX: idx_file_index_cache_entries_order (cache_key, entry_order)

13. thread_activity_state (v12)
    - thread_id TEXT PK
    - status (working|needsInput|complete|inactive)
    - preview TEXT, is_unread INT, title TEXT, body TEXT
    - source (helper|terminalNotification|terminalLifecycle)
    - updated_at REAL
```

### v16 → v17 Migration (TODO for this spec)

The plan notes that v16→v17 should address the right-panel-tabs load regression. The current issue:
- `save()` writes all tabs with `tab_order` (insertion order).
- `loadRightPanelStates()` sorts by `(thread_id, tab_order, title)`, but the tab_order is reset on each save.
- **Fix:** Add an index on `right_panel_tabs(thread_id, tab_order)` and ensure tab_order is stable across reloads (seed from existing rows if upgrading, or preserve order on incremental upserts).

For v17, implement:
```sql
CREATE INDEX IF NOT EXISTS idx_right_panel_tabs_order 
  ON right_panel_tabs(thread_id, tab_order)
```

No data migration needed; the index alone ensures `loadRightPanelStates()` can reliably order tabs on reload.

## YAAWStore Protocol (Public API Surface)

All methods are `async`, isolated to the actor:

```swift
public protocol YAAWStore: AnyObject {
  // Snapshot I/O (full transactional save/load)
  func load() -> YAAWSnapshot
  func save(_ snapshot: YAAWSnapshot)

  // Incremental upserts (single-row, per-transaction)
  func upsertProject(_ project: Project)
  func upsertThread(_ thread: AgentThread)
  func deleteThread(id: UUID)
  func setRightPanelMode(threadID: UUID, mode: RightPanelMode)
  func setRightPanelState(threadID: UUID, state: RightPanelState)
  func setBottomTerminalExpanded(threadID: UUID, isExpanded: Bool)
  func setSelectedProject(_ projectID: UUID)
  func setSelectedThread(_ threadID: UUID?)
  func persistSelectionChange(
    selectedProjectID: UUID,
    selectedThreadID: UUID?,
    touchedProject: Project?,
    touchedThread: AgentThread?,
    expandedProjectID: UUID?
  )
  func setLayoutState(_ state: LayoutState)
  func setProjectExpanded(_ projectID: UUID, isExpanded: Bool)
  func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool)
  func upsertFileIndexMetadata(_ metadata: FileIndexMetadata)
  func upsertThreadActivity(_ activity: ThreadActivityState)
  func cachedFileIndex(cacheKey: String) -> CachedFileIndex?
  func upsertCachedFileIndex(_ index: CachedFileIndex)
}
```

**Concurrency model:** 
- In the rewrite, all methods become `async` and must be called from the caller's async context.
- The actor guarantees serialization; concurrent calls queue internally.
- No `@unchecked Sendable` needed; callers pass `Sendable` value types (Project, AgentThread, etc.).

## Current Implementation Details (for port reference)

### Snapshot Load (`load()` @ ~10 ms @10k threads)

**SQLiteYAAWStore.load()** executes in a single implicit transaction:

1. **loadProjects()** — all projects sorted by: Global first, then pinned (DESC), sort_order, created_at, display_name.
   - If empty: seed with `InMemoryYAAWStore.helloWorld()` and auto-save.
2. **loadThreads()** — all threads sorted by created_at, display_name. Unpacks `launch_options_json` back to `AgentLaunchOptions`.
3. **loadUUID/loadBool** for app_state keys: selected_project_id, selected_thread_id, is_global_terminal_expanded.
4. **loadRightPanelModes** — dict[threadID] → mode.
5. **loadRightPanelStates(fallbackModes)** — loads tabs and selected_tab_id; falls back to mode's defaultTabID if no tab_state row.
   - Queries: `SELECT … FROM right_panel_tabs ORDER BY thread_id, tab_order, title`
   - Then: `SELECT thread_id, selected_tab_id FROM right_panel_tab_state`
   - **REGRESSION RISK:** tab_order is reset on each full save(), so ordering may shift. v17 migration + index needed.
6. **loadLayoutState(fallback)** — seven keys from layout_state table.
7. **loadFileIndexMetadata** — thread-scoped metadata.
8. **loadThreadActivity** — thread-scoped activity state.
9. **loadBottomTerminalExpandedThreadIDs** — set of thread IDs with is_expanded=1.
10. **loadSidebarProjectState** — two sets (expanded, archiveExpanded).

**Return:** Assembled into `YAAWSnapshot`.

**Error handling:** On any exception, returns `InMemoryYAAWStore.helloWorld().load()` and records diagnostic event.

### Snapshot Save (`save()` @ ~381 ms @10k threads [to be optimized to ≤30 ms])

**SQLiteYAAWStore.save()** executes as a single IMMEDIATE transaction:

1. **DELETE FROM** all 13 tables (hardcoded list, no dynamic generation).
2. **INSERT** all rows:
   - `insertProject()` for each project
   - `insertThread()` for each thread (repacks launch_options to JSON)
   - `insertRightPanelMode()` for each threadID
   - `insertRightPanelState()` for each thread (deletes old tabs, reinserts sorted)
   - `insertBottomTerminalState()` for expanded threads
   - `insertFileIndexMetadata()` for each metadata
   - `insertThreadActivity()` for each activity
   - `insertSidebarProjectState()` for each project
   - `insertAppState()` for 3 app-state keys
   - `insertLayoutState()` for 7 layout-state keys

**Perf problem:** O(n) INSERT statements, each allocates a new statement. No prepared-statement caching. Full table DELETEs even if only 1 thread changed.

### Incremental Operations (all @ ~2 ms @10k corpus)

Single-row upserts use prepared `INSERT … ON CONFLICT(pk) DO UPDATE SET`:

- **upsertProject()** — `INSERT projects (…) VALUES (…) ON CONFLICT(id) DO UPDATE SET …`
- **upsertThread()** — `INSERT threads (…) VALUES (…) ON CONFLICT(id) DO UPDATE SET …`
- **setRightPanelMode()** — UPSERT into right_panel_modes
- **setRightPanelState()** — DELETE old tabs, INSERT new tabs, UPSERT tab_state
- **setLayoutState()** — upserts each layout_state row by key (7 calls)
- **setProjectExpanded()** — UPSERT sidebar_project_state (preserves archive state)
- **upsertFileIndexMetadata()** — UPSERT with full row
- **upsertThreadActivity()** — UPSERT with full row
- **setRightPanelMode()** — single-row UPSERT

Each runs in its own `transaction()` block. Error caught, logged, **swallowed** (no throw).

### Prepared Statements (current: re-prepared on every call)

**SQLiteYAAWStore.prepare()** — calls `sqlite3_prepare_v2()` each time.

- ~1,063 line range: `prepare(_ sql: String) throws -> OpaquePointer?`

**Problem:** `save()` at 10k threads will prepare 13×10k+ statements, one per row. Heavy allocation.

**Fix:** Implement `StatementCache` (private):

```swift
private var statementCache: [String: OpaquePointer] = [:]

private func cachedPrepare(_ sql: String) throws -> OpaquePointer? {
  if let cached = statementCache[sql] { return cached }
  let stmt = try prepare(sql)
  statementCache[sql] = stmt
  return stmt
}

private func reset(_ stmt: OpaquePointer?) throws {
  guard sqlite3_reset(stmt) == SQLITE_OK else {
    throw SQLiteStoreError.executionFailed(errorMessage)
  }
  sqlite3_clear_bindings(stmt)
}
```

On each operation, `cachedPrepare()` + `bind()` + `stepDone()` + `reset()`. When swapping statements, call `reset()` to clear bindings and reset to initial state.

Cache life = store instance life; on deinit, iterate cache and `sqlite3_finalize()` all.

### PRAGMAs (current setup)

**open()** sets (lines 467–485):
```sql
PRAGMA journal_mode = WAL
PRAGMA synchronous = NORMAL
```

Verifies WAL actually took effect (fallback to roll-back journal on unsupported filesystems).

**migrate()** sets (line 488):
```sql
PRAGMA foreign_keys = ON
```

**Schema design implications:**
- WAL = write-ahead log; enables concurrent reads during writes.
- NORMAL synchronous = commit only waits for data to reach OS (not disk); reasonable for local SQLite.
- Foreign keys ON = cascading deletes work correctly.

Do **not** change or remove these; the app depends on them. The rewrite simply keeps them as-is.

### Interpolated Table Name PRAGMA (REMOVE IN REWRITE)

Current code **line 1088** uses:
```swift
let statement = try prepare("PRAGMA table_info(\(table))")
```

This interpolates the table name into SQL, which is unsafe (though table names come from literals in the migration code, so not a real injection vector). However:
1. It's still bad practice.
2. It's the only place with interpolation.

**Fix:** Replace with proper binding... except SQLite doesn't support binding `PRAGMA` parameter names. **Acceptable exception:** since table names are hardcoded migration literals (not user input), leave as-is but document the exception. Or refactor to a switch statement on table name.

**Rewrite approach:** Refactor `tableColumns()` to take enum or literal match:

```swift
private func tableColumns(_ table: TableName) -> Set<String> {
  let sql = "PRAGMA table_info(\(table.sqlName))"
  // … execute …
}

enum TableName: String {
  case projects, threads, appState, layoutState, rightPanelModes, rightPanelTabs, rightPanelTabState, …
  var sqlName: String { rawValue.replacingOccurrences(of: "_", with: "_") } // or map via switch
}
```

Or simply document that migration table names are safe (hardcoded, not user-driven).

## Rewrite Strategy: UPSERT + Prepared-Statement Cache

### 1. Replace `save()` with UPSERT snapshot persist

Old (lines 113–176):
```swift
public func save(_ snapshot: YAAWSnapshot) {
  do {
    try transaction {
      try execute("DELETE FROM right_panel_modes")
      try execute("DELETE FROM right_panel_tab_state")
      // … 11 more DELETEs …
      for project in snapshot.projects {
        try insertProject(project)
      }
      // … insert all rows …
    }
  } catch { … log … }
}
```

New approach (**perf target: ≤30 ms @10k**):

```swift
public func save(_ snapshot: YAAWSnapshot) {
  do {
    try transaction {
      // Track which rows to delete (only those not in snapshot)
      let existingProjectIDs = try loadProjectIDs()
      let rowsToDelete = existingProjectIDs.subtracting(snapshot.projects.map(\.id))
      for id in rowsToDelete {
        try deleteProject(id: id)
      }
      
      // UPSERT all snapshot rows (idempotent)
      for project in snapshot.projects {
        try upsertProjectStatement(project)  // reuse existing prepared-statement friendly version
      }
      for thread in snapshot.threads {
        try upsertThreadStatement(thread)
      }
      // … etc for other tables …
      
      // Right-panel-tabs: DELETE old tabs for threads being updated, INSERT new ones
      let threadIDsToRefresh = Set(snapshot.threads.map(\.id))
      for threadID in threadIDsToRefresh {
        let deleteTabsStatement = try cachedPrepare(
          "DELETE FROM right_panel_tabs WHERE thread_id = ?"
        )
        bind(threadID.uuidString, at: 1, in: deleteTabsStatement)
        try stepDone(deleteTabsStatement)
        try reset(deleteTabsStatement)
        
        // Insert new tabs
        if let state = snapshot.rightPanelStatesByThreadID[threadID] {
          let tabs = RightPanelState.normalizedTabs(state.persistenceSnapshot.tabs)
          for (index, tab) in tabs.enumerated() {
            let insertStatement = try cachedPrepare(
              """
              INSERT INTO right_panel_tabs (
                thread_id, tab_id, kind, title, relative_path, url_string, tab_order
              ) VALUES (?, ?, ?, ?, ?, ?, ?)
              """
            )
            bind(threadID.uuidString, at: 1, in: insertStatement)
            bind(tab.id, at: 2, in: insertStatement)
            bind(tab.kind.rawValue, at: 3, in: insertStatement)
            bind(tab.title, at: 4, in: insertStatement)
            bindOptional(tab.relativePath, at: 5, in: insertStatement)
            bindOptional(tab.urlString, at: 6, in: insertStatement)
            sqlite3_bind_int(insertStatement, 7, Int32(index))
            try stepDone(insertStatement)
            try reset(insertStatement)
          }
        }
      }
    }
  } catch {
    recordSQLiteError(name: "sqlite_save_failed", error: error)
  }
}
```

**Key changes:**
- Instead of DELETE all, only delete rows not in snapshot.
- UPSERT instead of INSERT (ON CONFLICT … DO UPDATE).
- Use `cachedPrepare()` + `reset()` to avoid re-preparing.
- For right-panel-tabs, only refresh threads present in snapshot (assumes partial saves don't happen; if they do, preserve tabs for unmentioned threads).

**Expected perf gain:**
- 381 ms (DELETE all + INSERT all) → ~30 ms (UPSERT + diff-based deletes + prepared-statement cache reuse).

### 2. Add PreparedStatementCache

Private cache member:

```swift
private var statementCache: [String: OpaquePointer?] = [:]

private func cachedPrepare(_ sql: String) throws -> OpaquePointer? {
  if let cached = statementCache[sql] {
    return cached
  }
  let stmt = try prepare(sql)
  statementCache[sql] = stmt
  return stmt
}

private func resetStatement(_ stmt: OpaquePointer?) throws {
  guard sqlite3_reset(stmt) == SQLITE_OK else {
    throw SQLiteStoreError.executionFailed(errorMessage)
  }
  sqlite3_clear_bindings(stmt)
}
```

In `deinit`, finalize all cached statements:

```swift
deinit {
  for (_, stmt) in statementCache {
    sqlite3_finalize(stmt)
  }
}
```

**Validation test:** `test_bench_save_10k_threads` should run ≤ 30 ms (from 381 ms baseline).

### 3. Add v16 → v17 Migration

In `migrateToVersionSeventeen()`:

```swift
fileprivate func migrateToVersionSeventeen() throws {
  try execute(
    """
    CREATE INDEX IF NOT EXISTS idx_right_panel_tabs_order 
      ON right_panel_tabs(thread_id, tab_order)
    """
  )
}
```

Call from `migrate()` after v16 check:

```swift
if currentVersion < 17 {
  try transaction {
    try migrateToVersionSeventeen()
    try execute("PRAGMA user_version = 17")
  }
}
```

Update schema version constant:

```swift
public static let schemaVersion = 17
```

## Concurrency Model (Swift 6 Strict)

### Current (to be replaced)

- `SQLiteYAAWStore` is a final class, not thread-safe by design.
- Callers (AppModel) run on `@MainActor` or dispatch to DispatchQueue.main.
- No locks; relies on single-threaded access.

### Rewrite Target

- `SQLiteYAAWStore` becomes `actor` (or wraps a private `PersistenceActor`).
- All public methods are `async`.
- Callers use `await`: `await store.load()`, `await store.upsertThread(thread)`.
- Compiler enforces `Sendable` on all parameters.

**Implementation option A: Direct actor class**

```swift
public actor SQLiteYAAWStore: YAAWStore {
  private let databasePath: URL
  private var database: OpaquePointer?
  private var statementCache: [String: OpaquePointer?] = [:]
  private let diagnosticRecorder: DiagnosticEventRecording

  public nonisolated init(databasePath: URL, diagnosticRecorder: …) throws { … }
  
  public func load() -> YAAWSnapshot { … }
  public func save(_ snapshot: YAAWSnapshot) { … }
  // … etc, all isolated to actor boundary …
}
```

**Implementation option B: Wrapper around private actor**

```swift
public final class SQLiteYAAWStore: YAAWStore {
  private let actor: PersistenceActor
  
  public init(databasePath: URL, …) throws {
    self.actor = try PersistenceActor(databasePath: databasePath, …)
  }
  
  public func load() -> YAAWSnapshot {
    // Must be async in protocol; handle via wrapper
  }
}

private actor PersistenceActor { … actual implementation … }
```

**Recommendation:** Option A (direct actor). The protocol can be updated to use `async`; callers transition to `await`.

**Sendable conformance:**
- `YAAWSnapshot`, `Project`, `AgentThread`, `LayoutState`, etc. are already `Sendable` (value types, `Sendable` children).
- `FileIndexMetadata`, `ThreadActivityState`, `RightPanelState`, `RightPanelTab` must be `Sendable`.
- Error enum `SQLiteStoreError` is already `Equatable` and `Sendable`.

## Transactions & Error Handling

### Transaction Semantics (unchanged)

```swift
fileprivate func transaction(_ work: () throws -> Void) throws {
  try execute("BEGIN IMMEDIATE TRANSACTION")
  do {
    try work()
    try execute("COMMIT")
  } catch {
    try? execute("ROLLBACK")
    throw error
  }
}
```

**IMMEDIATE** ensures the transaction acquires a write lock immediately, preventing read-write conflicts.

### Error Handling Policy

**Current (incremental ops):**
- Exception caught, logged via `recordSQLiteError()`, **swallowed** (no throw).
- Callers unaware if operation failed.
- **Problem:** Silent failures, hard to debug, regression in activity state (e.g., unread count disappears silently).

**Rewrite (explicit failures):**
- Keep `runIncremental()` for local calls to reduce boilerplate, but:
- Callers in `ActivityStore` or high-level operations should surface errors to the UI (thread state = "error: persistence failed").
- `save()` errors = loud (throw); callers must decide recovery.
- Incremental upserts = log + swallow (since they're fire-and-forget updates); or migrate to async error handling in `ActivityStore`.

**Recommendation:**
- For now, keep current swallow behavior (no API change to callers).
- Add a diagnostic event with full stacktrace so errors are recoverable via logs.
- In Chunk E (ActivityStore), add error-surfacing logic for critical operations (activity updates that fail).

## Performance Targets & Baselines

From `SQLitePersistenceBenchmarks.swift` and post-perf-fix doc (`docs/perf/post-merge-2026-05-21.md`):

| Operation | Baseline | Target | Notes |
|---|---|---|---|
| Single-thread edit @ 10k corpus | ~2 ms | ≤ 2 ms | PRESERVE (upsertThread already fast) |
| Full snapshot save @ 10k | 381 ms | ≤ 30 ms | MAJOR: DELETE+INSERT → UPSERT + cache |
| Full snapshot load @ 10k | (not benchmarked; typical ~10 ms) | ≤ 10 ms | PRESERVE |
| `activeThreadsForSelectedProject` lookup @ 10k | 0.1 ms | ≤ 0.1 ms | O(1) via snapshot; no regression |

### Benchmark Test Coverage

Port from `SQLitePersistenceBenchmarks.swift`:

- `test_bench_save_100threads`, `test_bench_save_1k_threads`, `test_bench_save_10k_threads`
- `test_bench_load_100threads`, `test_bench_load_1k_threads`, `test_bench_load_10k_threads`
- `test_bench_save_singleThreadEdit_in10kCorpus`

Run with `RUN_BENCHMARKS=1 swift test -c release` and validate targets are met before merging.

## Test Coverage (Behavior Parity Spec)

**All tests from `PersistenceTests.swift` must pass unchanged** (or with minimal port to async calls):

1. **Schema & migration:**
   - `testSQLiteMigrationInitializesCurrentSchema` — v1 from fresh DB
   - `testSQLiteStoreUsesWALJournalMode` — WAL verified
   - `testSQLiteStoreDoesNotReportWALFailureOnSupportedFilesystem` — diagnostic event only on actual failure
   - `testSQLiteMigrationRecoversPartialVersionZeroSchema` — partial v0 recovery
   - `testSQLiteMigrationAddsAgentCLIToVersionOneThreads` — v1 → v2
   - `testSQLiteMigrationRejectsVersionOneThreadsWithoutExplicitAgentCLI` — v2 gate
   - `testSQLiteMigrationFailureRecordsDiagnosticEvent` — logging works
   - All version-specific migration tests (v3, v4, v5, … v16) must keep passing

2. **Snapshot save/load:**
   - `testSQLiteStorePersistsPlanOneSnapshot` — roundtrip with all field types
   - `testSQLiteStorePersistsSelectionChangeInBatch` — multi-row transactional update
   - `testPersistSelectionChangeMatchesAcrossStores` — parity between SQLiteYAAWStore and InMemoryYAAWStore
   - `testSQLitePersistsPendingThreadRename` — session rename state
   - `testSQLiteStorePersistsThreadActivityState` — activity state roundtrip
   - `testSQLiteLayoutStatePersistsThroughReload` — layout state roundtrip
   - `testSQLiteTransactionRejectsPartialInvalidThreadWrite` — transaction rollback on FK error
   - `testSQLiteLoadFallsBackWhenPersistedUUIDIsInvalid` — recovery to helloWorld

3. **Right-panel-tabs (regression fix):**
   - `testSQLiteDoesNotRestoreTransientRightPanelNvimTabs` — nvim tabs filtered out
   - `testSQLiteDoesNotRestoreTransientRightPanelBrowserTabs` — browser tabs filtered out
   - `testSQLiteMigrationSeedsRightPanelTabsFromVersionSevenModes` — v7 → v13 seed
   - **NEW:** `testSQLiteRightPanelTabOrderPersistedOnReload` — tabs preserve order across save/load cycles (validates v17 fix)

4. **File index & activity:**
   - `testSQLiteFileIndexMetadataPersistsThroughReload` — metadata roundtrip
   - `testSQLiteCachedFileIndexPersistsThroughReload` — cache persistence
   - All agent CLI kind tests

5. **Bottom terminal & sidebar:**
   - `testSQLitePersistsBottomTerminalExpandedThreads` — bottom-term state
   - `testSQLitePersistsPinsProjectOrderAndSidebarExpansion` — pins, order, archive state

## InMemoryYAAWStore (double/test double)

Remains unchanged API, but must also support strict concurrency (if used as an actor substitute):

```swift
public final class InMemoryYAAWStore: YAAWStore {
  private var snapshot: YAAWSnapshot
  private var cachedFileIndexesByKey: [String: CachedFileIndex] = [:]
  private(set) var layoutStateWriteCount = 0
  private(set) var threadActivityWriteCount = 0
  private(set) var selectionChangeWriteCount = 0
  
  public func load() -> YAAWSnapshot { snapshot }
  public func save(_ snapshot: YAAWSnapshot) { self.snapshot = snapshot; rebuildIndexes() }
  // … etc …
}
```

If wrapped in an actor for test compatibility:

```swift
public actor InMemoryYAAWStoreActor: YAAWStore {
  private let impl: InMemoryYAAWStore
  
  public init(snapshot: YAAWSnapshot) {
    self.impl = InMemoryYAAWStore(snapshot: snapshot)
  }
  
  public func load() -> YAAWSnapshot { impl.load() }
  // … forwarding …
}
```

Tests use `InMemoryYAAWStore(snapshot: …)` directly (synchronous); app uses `SQLiteYAAWStore` (async).

## File Paths & Key Code Sections

### Source locations

- `/Users/BXD5017/github/dopsonbr/yaaw/src/Persistence/SQLiteYAAWStore.swift`
  - **Entire file rewrite needed** (2,039 lines)
  - Key methods to port:
    - `load()` @ ~62–111 (refactor to load parts incrementally)
    - `save()` @ ~113–176 (replace with UPSERT + diff-based deletes)
    - `prepare()` @ ~1063–1069 (wrap in cache)
    - `transaction()` @ ~1043–1052 (unchanged)
    - All `migrate*()` methods @ ~487–734 (copy verbatim, add v17)
    - All `upsertProjectStatement()`, `upsertThreadStatement()`, etc. (refactor to use cache)
    - Helper methods: `bind()`, `bindOptional()`, `text()`, `optionalText()`, `stepDone()` (unchanged)
    - `open()`, `userVersion()`, `errorMessage` (unchanged)

- `/Users/BXD5017/github/dopsonbr/yaaw/src/Persistence/InMemoryYAAWStore.swift`
  - Minimal changes: ensure Sendable (already is)
  - Optionally wrap in actor for test symmetry

- `/Users/BXD5017/github/dopsonbr/yaaw/src/Persistence/YAAWConfiguration.swift`
  - Add `schemaVersion` field (for future config-driven migration version, not used yet)
  - Minimal changes

### Test file

- `/Users/BXD5017/github/dopsonbr/yaaw/src/Tests/YAAWKitTests/PersistenceTests.swift` (1,934 lines)
  - Must pass unchanged (or minimal async adaptation)
  - Add new tests:
    - `testSQLiteRightPanelTabOrderPersistedOnReload` (validates v17 tab-order fix)
    - `testPreparedStatementCacheReusedAcrossOperations` (validates cache hit rate)

### Benchmark file

- `/Users/BXD5017/github/dopsonbr/yaaw/src/Tests/YAAWKitBenchmarks/SQLitePersistenceBenchmarks.swift` (92 lines)
  - Runs unchanged; assertions validated against targets

## Plan Row References (from 00-master-plan.md)

| Reference | Relevant text |
|---|---|
| Chunk A Scope | "Wrap the C-API store in a `PersistenceActor`... Replace the full-snapshot DELETE+INSERT `save()` with **UPSERT**... add a **prepared-statement cache**... Keep WAL, the 16-step migration ladder, per-op transactions; add migration **v16 → v17**... Keep `InMemoryYAAWStore` double with write counters." |
| Port-from | "SQLiteYAAWStore.swift (esp. `save()` ~115-176, `prepare()` ~1063-1069), InMemoryYAAWStore.swift." |
| Tests | "port `PersistenceTests.swift` (migrations, WAL, schema evolution — behavior-level, survives); add UPSERT-correctness + statement-cache-reuse tests; port `SQLitePersistenceBenchmarks`." |
| Acceptance + perf gate | "single-thread edit @10k ≤ **2 ms** (preserve); full snapshot save @10k ≤ **30 ms** (was 381 ms); load @10k ≤ **10 ms**; migration round-trips green; no metadata in user dirs." |
| Decision context | "Harden raw sqlite3 (no GRDB)"; "No new dependency; keep `YAAWStore` protocol + `InMemoryYAAWStore` double." |

## Gotchas & Mitigations

### 1. Prepared-statement cache lifetime

**Risk:** Statements cached but database connection closes or schema changes; cached statements become stale.

**Mitigation:** Cache invalidated on re-migration or graceful shutdown. Rewrite doesn't support online schema changes; migrations happen on init. If a migration adds a column, the old cached statement is invalid; **solution:** invalidate cache on successful migration. Current approach avoids this (migrations happen once at startup, before any app code runs).

### 2. Right-panel-tabs tab_order regression

**Risk:** Full `save()` followed by `load()` may not preserve tab order if tab_order is recomputed from insertion order and insertion order changes.

**Mitigation:** v17 adds index; `loadRightPanelStates()` sorts by (thread_id, tab_order); tab_order is now stable. **Test:** `testSQLiteRightPanelTabOrderPersistedOnReload` must pass (cycle save → load 5 times, assert tabs stay in same order).

### 3. UPSERT correctness on partial snapshots

**Risk:** If a caller passes a partial snapshot (missing some threads), UPSERT leaves old threads untouched, but old tabs may be orphaned.

**Mitigation:** Design contract: `save(snapshot)` is **full snapshot**, not delta. Doc this clearly. For deltas, use incremental ops (`upsertThread()`, etc.). Current usage (AppModel → save whole snapshot at quit) matches this.

### 4. Async migration for callers

**Risk:** Changing `YAAWStore` protocol methods to `async` requires all callers to `await`.

**Mitigation:** This is a design-level decision (Chunk 0 contracts); all callers in `AppModel` / Stores transition together. Not a gotcha, but a cross-module dependency.

### 5. Error swallowing in incremental ops

**Risk:** `runIncremental()` swallows exceptions; callers don't know if a `setRightPanelMode()` actually persisted.

**Mitigation:** For critical operations (activity state changes), wrap in explicit error handling in `ActivityStore` (Chunk E). For UI state (panel modes, layout), swallowing is acceptable (state is in-memory; next save will fix it). Document in code.

---

## Summary of Changes

### Files modified:

1. **SQLiteYAAWStore.swift**
   - Wrap as actor or introduce PersistenceActor wrapper
   - Add prepared-statement cache
   - Rewrite `save()` to use UPSERT + diff-based deletes
   - Add v17 migration
   - Update `schemaVersion = 17`
   - Document migration ladder in comments

2. **InMemoryYAAWStore.swift**
   - Ensure Sendable (already is)
   - Optionally wrap in test actor

3. **YAAWConfiguration.swift**
   - Add schemaVersion comment (or field for future use)

### Tests:

- All PersistenceTests must pass (1,934 lines unchanged structure)
- Add `testSQLiteRightPanelTabOrderPersistedOnReload`
- All benchmarks must hit targets

### No breaking changes to:

- YAAWStore protocol (methods stay public, same signature)
- Domain model types (Project, AgentThread, etc.)
- YAML configuration (unrelated)

---

**This specification is complete and implements the requirements of Chunk A from the master plan. Implementer should follow the file:line references and test assertions to ensure parity with the current system while achieving the 10× speedup in full-snapshot persistence.**
