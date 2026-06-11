# Chunk E — AppModel Decomposition into @MainActor @Observable Stores

## Overview

Decompose the 3188-line `AppModel` god object into five focused `@MainActor @Observable` stores, eliminating the poll-everything concurrency model and hand-rolled generation counters in favor of Swift 6 strict concurrency and `Task` cancellation. Each store owns one domain and owns the persistence path to its dependencies.

**Target architecture:**
- `WorkspaceStore` — projects, threads, selection, nav history, session-link prompts
- `LayoutStore` — sidebar/right-panel/bottom-terminal widths, collapses, swap state
- `ActivityStore` — thread status, unread dots, activity previews, system notifications, dock badge
- `SettingsStore` — validated configuration, hot-reload, `resolvedTheme` against live `systemAppearanceIsDark`
- `RightPanelStore` — per-thread modes/tabs + now-persisted per-thread UI state

All stores depend on a new `AppEnvironment` that injects actors and collaborators at construction.

---

## 17 @Published Properties → Store Assignment

| @Published property | Store | Type | Notes |
|---|---|---|---|
| `projects` | WorkspaceStore | `[Project]` | All projects (active + archived) |
| `threads` | WorkspaceStore | `[AgentThread]` | All threads across all projects |
| `selectedProjectID` | WorkspaceStore | `UUID` | Current project selection |
| `selectedThreadID` | WorkspaceStore | `UUID?` | Current thread selection (nil for Global project) |
| `expandedProjectIDs` | WorkspaceStore | `Set<UUID>` | Set of expanded projects in sidebar |
| `expandedArchivedProjectIDs` | WorkspaceStore | `Set<UUID>` | Set of expanded archived projects in section |
| `sessionLinkRequiredThreadIDs` | WorkspaceStore | `Set<UUID>` | Threads needing explicit session link (moved from poll) |
| `navigationHistory` | WorkspaceStore | `NavigationHistory` | Back/forward stack (non-published; owned by store) |
| `layoutState` | LayoutStore | `LayoutState` | Widths + collapse flags |
| `fileBrowserState` | ActivityStore* | `FileBrowserState` | File index + search state (left-panel file browser) |
| `selectedFileRelativePath` | RightPanelStore | `String?` | Selected file in file browser (per-thread remembered) |
| `browserUnavailableMessagesByThreadID` | RightPanelStore | `[UUID: String]` | Browser tab error messages per thread |
| `rightPanelModesByThreadID` | RightPanelStore | `[UUID: RightPanelMode]` | Primary mode per thread |
| `rightPanelStatesByThreadID` | RightPanelStore | `[UUID: RightPanelState]` | **NOW PERSISTED**: tabs, selected tab per thread |
| `bottomTerminalExpandedThreadIDs` | LayoutStore | `Set<UUID>` | Threads with expanded bottom terminal |
| `configuration` | SettingsStore | `YAAWConfiguration` | YAML settings (validated + hot-reloaded) |
| `systemAppearanceIsDark` | SettingsStore | `Bool` | OS appearance (dark mode) pushed by `SystemAppearanceObserver` |
| `agentCLIOptionCatalog` | SettingsStore | `AgentCLIOptionCatalog` | Available agent options + permission presets |
| `threadActivityByThreadID` | ActivityStore | `[UUID: ThreadActivityState]` | Status, preview, unread flag, notification suppression per thread |

*fileBrowserState: Left-panel file browser is driven by selected thread; ActivityStore manages thread identity tracking. Consider scoping it or keeping as its own mini-store if tightly bound to selection lifecycle.

---

## Persisted @Published Properties (New in Rewrite)

The plan calls for "per-thread UI state to NOW persist: expanded folders, selected file, nvim path" (§Chunk E in master plan). These currently live in **non-persisted** in-memory dictionaries in AppModel:

| In-Memory Dict | New Persistence Behavior | Store | Notes |
|---|---|---|---|
| `expandedFoldersByThreadID` | Persist | RightPanelStore | Expanded folders in file browser per thread |
| `selectedFileByThreadID` | Persist | RightPanelStore | Last selected file per thread |
| `nvimRelativePathsByThreadID` | Persist | RightPanelStore | Last opened file in nvim per thread |

**Schema impact:** Add tables or columns to SQLite to track per-thread UI state. Version migration v16 → v17 handles this.

---

## Concurrency Model: Generation Counters → Task Cancellation

### Today (AppModel)

Hand-rolled cancellation via generation counters + in-flight booleans:

```swift
private var isAgentCLICapturePollInFlight = false
private var isAgentCLISessionSyncInFlight = false
private var agentCLIPollGenerationByThreadID: [UUID: Int] = [:]
```

When a stale result lands (e.g., after thread switch), the generation is checked:
```swift
if agentCLIPollGeneration(for: threadID) == request.generation { /* apply */ }
```

### Target (Stores)

Replace with `Task` lifecycle:
- Each async operation is a `Task` spawned from a store method
- When `selectedThreadID` changes → `cancel()` pending file-browser and capture-log tasks
- When thread is deleted/archived → `cancel()` its activity-poll task
- When helper exit → `cancel()` and relaunch is managed by `RenderHostClient` actor (Chunk D), not store

**Benefit:** Compiler-checked, structured cancellation; no manual generation bump; one source of truth (Task identity).

---

## Public API Surface by Store

### WorkspaceStore: @MainActor @Observable

**Observed properties:**
```swift
@Published var projects: [Project]
@Published var threads: [AgentThread]
@Published var selectedProjectID: UUID
@Published var selectedThreadID: UUID?
@Published var expandedProjectIDs: Set<UUID>
@Published var expandedArchivedProjectIDs: Set<UUID>
@Published var sessionLinkRequiredThreadIDs: Set<UUID>
```

**Computed properties:**
```swift
var selectedProject: Project?
var selectedThread: AgentThread?
var activeProjects: [Project]
var archivedProjects: [Project]
var windowTitle: String
var activeThreadsForSelectedProject: [AgentThread]  // O(1) via cached lookup
var archivedThreadsForSelectedProject: [AgentThread]
```

**Public methods:**
```swift
// Project CRUD
func createProject(displayName: String, rootDirectory: URL, now: Date) throws -> UUID
func selectProject(id: UUID)
func archiveProject(id: UUID)
func archiveSelectedProject()
func unarchiveProject(id: UUID)
func toggleProjectPinned(id: UUID)
func moveProject(id: UUID, direction: ProjectMoveDirection)
func reorderProject(id: UUID, before targetID: UUID)
func setProjectExpanded(_ projectID: UUID, isExpanded: Bool)

// Thread CRUD
func createThread(...) throws -> UUID
func selectThread(id: UUID)
func archiveThread(id: UUID)
func unarchiveThread(id: UUID)
func toggleThreadPinned(id: UUID)

// Session linking (auto-detect + manual)
func sessionLinkCandidates(for threadID: UUID) -> [SessionLinkCandidate]
func linkSession(threadID: UUID, candidate: SessionLinkCandidate)
func startNewSessionForUnlinkedThread(threadID: UUID)

// Navigation
func navigateBack()
func navigateForward()
```

**Cached lookups (performance critical, ≤0.1 ms @ 10k):**
```swift
// Thread index for O(1) lookups by ID
private var threadIndexByID: [UUID: Int]

// Per-project cached active/archived thread lists (sorted + maintained)
private var cachedActiveThreadsByProject: [UUID: [AgentThread]]
private var cachedArchivedThreadsByProject: [UUID: [AgentThread]]
```

**Implementation detail:** When thread list is mutated, rebuild indexes + re-sort cached lists. This is the only place that touches the `threadIndexByID` and project caches.

---

### LayoutStore: @MainActor @Observable

**Observed properties:**
```swift
@Published var layoutState: LayoutState
@Published var bottomTerminalExpandedThreadIDs: Set<UUID>
```

Where `LayoutState` contains:
```swift
public var sidebarWidth: Double
public var rightPanelWidth: Double
public var globalTerminalHeight: Double
public var isSidebarCollapsed: Bool
public var isRightPanelCollapsed: Bool
public var isGlobalTerminalExpanded: Bool
public var isWorkspaceSwapped: Bool
```

**Public methods:**
```swift
func toggleSidebarCollapsed()
func toggleRightPanelCollapsed()
func toggleWorkspaceSwap()
func toggleBottomTerminal(for threadID: UUID)
func setSidebarWidth(_ width: Double, persist: Bool = true)
func setRightPanelWidth(_ width: Double, persist: Bool = true)
func setGlobalTerminalHeight(_ height: Double, availableWindowHeight: Double?, persist: Bool = true)
func resetSidebarWidth(persist: Bool = true)
func resetRightPanelWidth(persist: Bool = true)
func resetGlobalTerminalHeight(persist: Bool = true)
func commitLayoutResize()  // Batches persist for drag operations
func isBottomTerminalExpanded(for threadID: UUID) -> Bool
```

**Constants in LayoutState:**
```swift
defaultSidebarWidth = 250.0
defaultRightPanelWidth = 360.0
defaultGlobalTerminalHeight = 140.0
minimumSidebarWidth = 180.0
maximumSidebarWidth = 520.0
minimumRightPanelWidth = 280.0
minimumGlobalTerminalHeight = 96.0
maximumGlobalTerminalHeight = 420.0
```

---

### ActivityStore: @MainActor @Observable

**Observed properties:**
```swift
@Published var threadActivityByThreadID: [UUID: ThreadActivityState]
@Published var fileBrowserState: FileBrowserState  // File index + search state
```

**Computed properties:**
```swift
var unreadThreadActivityCount: Int
```

**Public methods:**
```swift
// Activity recording (from terminal lifecycle events)
func recordAgentCLIOutput(threadID: UUID, output: String, terminalTitle: String?)
func recordAgentCLITerminalTitle(threadID: UUID, title: String)
func recordAgentTerminalFocus(threadID: UUID, focused: Bool)
func recordAgentTerminalNotification(threadID: UUID, title: String, body: String)
func recordAgentTerminalClosed(threadID: UUID)
func recordAgentCommandFinished(threadID: UUID, exitCode: Int?)

// File browser refresh (driven by selected thread)
func refreshSelectedFileBrowser()
func updateFileSearchQuery(_ query: String)
func selectFile(relativePath: String?)
func selectAdjacentFile(direction: ProjectMoveDirection)
func openFileInNvim(relativePath: String)
func openFileInBrowser(relativePath: String) -> Bool
func openBrowserTab(urlString: String?)

// Polling (will move to push-based events from RenderHostClient in later chunk)
func pollSelectedAgentCLICaptureLog()
func pollAgentCLIActivityLogs()
func pollAgentCLIStateInBackground()
```

**Activity logic (behavior-parity critical):**

1. **Activity → Unread → Badge/Notification chain** (line 3045-3099 in current AppModel):
   - `applyThreadActivity()` receives `ThreadActivityEvent` + `isUnread` + `shouldNotify` flags
   - If focused selected thread + app active → suppress notification
   - Activity is published to `@Published` + persisted idempotently
   - If content differs from previous → update dock badge
   - Every update checks `hasSamePublishedActivity()` to skip redundant `@Published` updates (line 3111-3118)

2. **Focus suppression** (line 3120-3124):
   - Notification suppressed if: `isApplicationActive() && selectedThreadID == threadID && focusedProjectTerminalThreadID == threadID`
   - `focusedProjectTerminalThreadID` is set by `recordAgentTerminalFocus()`

3. **Activity downgrade on launch** (line 185-186, 250-293):
   - Loaded "working" activities downgrade to "inactive" on app start (captures in-flight state before crash)
   - Persisted back if it changed

4. **Terminal title heuristics** (line 1158-1176, 2446-2533 in tests):
   - Some CLIs use title as session name (Claude doesn't); others do (Codex)
   - If title is terminal-title-only, show as activity subtitle not thread name
   - If title == thread name, omit subtitle to avoid redundancy

---

### SettingsStore: @MainActor @Observable

**Observed properties:**
```swift
@Published var configuration: YAAWConfiguration  // Validated + hot-reloaded
@Published var systemAppearanceIsDark: Bool
@Published var agentCLIOptionCatalog: AgentCLIOptionCatalog
```

**Computed properties:**
```swift
var resolvedTheme: ThemeDefinition  // config.resolvedTheme(systemAppearanceIsDark)
var defaultAgentCLI: AgentCLIKind
```

**Public methods:**
```swift
// Configuration lifecycle
func reloadConfiguration(_ configuration: YAAWConfiguration)
func updateSystemAppearance(isDark: Bool)
func refreshAgentCLIOptionCatalog() -> AgentCLIOptionCatalog
func permissionModes(for agentCLI: AgentCLIKind) -> [AgentPermissionMode]
func configuredLaunchOptions(for agentCLI: AgentCLIKind) -> AgentLaunchOptions
func keyboardShortcutDefinition(for action: KeyboardShortcutAction) -> KeyboardShortcutDefinition
func isKeyboardShortcutEnabled(for action: KeyboardShortcutAction) -> Bool
```

**Hot-reload behavior:**
- `reloadConfiguration()` validates config, clears in-flight state, resets terminal descriptors
- Theme change applies to live terminals without restart (Chunk D: `RenderHostClient` receives notification)
- Font change applies to live terminals without restart

**Dependencies:**
- Receives `systemAppearanceIsDark` pushed by `SystemAppearanceObserver` (line 13 SystemAppearanceObserver.swift: installed in app layer)
- Calls into `YAAWConfiguration.resolved​Theme(systemAppearanceIsDark:)` to merge System pairing

---

### RightPanelStore: @MainActor @Observable

**Observed properties:**
```swift
@Published var rightPanelModesByThreadID: [UUID: RightPanelMode]
@Published var rightPanelStatesByThreadID: [UUID: RightPanelState]  // NOW PERSISTED
@Published var selectedFileRelativePath: String?
@Published var browserUnavailableMessagesByThreadID: [UUID: String]
```

**Computed properties:**
```swift
var selectedRightPanelMode: RightPanelMode
var selectedRightPanelState: RightPanelState
var selectedRightPanelTab: RightPanelTab
var selectedBrowserUnavailableMessage: String?
```

**Public methods:**
```swift
// Mode/tab selection
func selectRightPanelMode(_ mode: RightPanelMode)
func selectRightPanelTab(id tabID: String)
func closeRightPanelTab(id tabID: String)
func cycleRightPanelModeForward()
func cycleRightPanelModeBackward()

// File browser state (per-thread in-memory, now persisted)
func expandedFolders(forThreadID: UUID) -> Set<String>
func setExpandedFolders(_ folders: Set<String>, forThreadID: UUID)
```

**New persistence behavior:**

The current AppModel keeps three thread-scoped dictionaries **in-memory only**, losing state on relaunch:

```swift
private var expandedFoldersByThreadID: [UUID: Set<String>] = [:]
private var selectedFileByThreadID: [UUID: String] = [:]
private var nvimRelativePathsByThreadID: [UUID: String] = [:]
```

In the rewrite, these move to persistent storage (SQLite tables or JSON in `RightPanelState`). The master plan says (§Chunk E):

> "the now-**persisted** per-thread UI state: expanded folders, selected file, nvim path"

This fixes the asymmetry noted in the plan's inventory: "the per-thread UI state — expanded folders, selected file, nvim path — now **persisted**, fixing the current unpersisted-dictionary asymmetry."

**RightPanelState changes:**

Current `RightPanelState`:
```swift
public var tabs: [RightPanelTab]
public var selectedTabID: String
```

Add fields to track expanded state:
```swift
public var expandedFolders: Set<String>  // Relative paths
public var selectedFilePath: String?     // Relative path
public var nvimPath: String?             // Relative path (last opened)
```

On store load, restore these from persistence for each thread.

---

## Actor Dependencies (Injected via AppEnvironment)

RightPanelStore and other stores consume async results from actors over `AsyncStream`:

### FileIndexActor (Chunk B contract)

Protocol stub (actual impl in Chunk B):
```swift
actor FileIndexActor {
    func index(root: URL, ignoreRules: IgnoreRules) -> AsyncStream<FileIndexResult>
    func search(entries: [FileBrowserEntry], query: String) -> [FileBrowserEntry]
}
```

Used by: ActivityStore when refreshing file browser for selected thread.

### AgentCLISessionBindingActor (Chunk C contract)

Stub:
```swift
actor AgentCLISessionBindingActor {
    func capturedOutput(for thread: AgentThread, after offset: UInt64) -> AgentCLICapturedOutput?
    func capturedActivityEvents(for thread: AgentThread, after offset: UInt64) -> AgentCLICapturedOutput?
    func exactSessionLinkCandidate(for thread: AgentThread) -> SessionLinkCandidate?
    func catalogMetadata(for thread: AgentThread) -> AgentCLISessionMetadata?
}
```

Used by: WorkspaceStore for session linking; ActivityStore for capture polling.

### PersistenceActor (Chunk A contract)

Stub:
```swift
actor PersistenceActor: YAAWStore {
    func load() -> YAAWSnapshot
    func upsertProject(_ project: Project)
    func upsertThread(_ thread: AgentThread)
    func upsertThreadActivity(_ activity: ThreadActivityState)
    func setLayoutState(_ state: LayoutState)
    func setRightPanelMode(threadID: UUID, mode: RightPanelMode)
    func setRightPanelState(threadID: UUID, state: RightPanelState)
    // ... etc
}
```

Used by: Every store calls its methods (persist on every mutation).

---

## AppEnvironment: Constructor Injection

New top-level dependency container (replaces scattered init params):

```swift
@MainActor
struct AppEnvironment {
    let persistenceActor: PersistenceActor
    let fileIndexActor: FileIndexActor
    let sessionBindingActor: AgentCLISessionBindingActor
    let renderHostClient: RenderHostClient
    let notificationDispatcher: any ThreadActivityNotificationDispatching
    let badgeUpdater: any ThreadActivityBadgeUpdating
    let diagnosticRecorder: DiagnosticEventRecording
    let externalToolResolver: any AgentCLIExecutableResolving
    let agentCLIOptionCatalogService: any AgentCLIOptionCatalogServicing
    let terminalManager: TerminalSessionManaging
    let systemAppearanceObserver: SystemAppearanceObserver
    let isApplicationActive: () -> Bool
    let environment: [String: String]
    let homeDirectory: URL
    
    init(
        persistenceActor: PersistenceActor = .default,
        fileIndexActor: FileIndexActor = .default,
        sessionBindingActor: AgentCLISessionBindingActor = .default,
        notificationDispatcher: any ThreadActivityNotificationDispatching = NoopThreadActivityNotificationDispatcher(),
        badgeUpdater: any ThreadActivityBadgeUpdating = NoopThreadActivityBadgeUpdater(),
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared,
        externalToolResolver: any AgentCLIExecutableResolving = PATHAgentCLIExecutableResolver(),
        agentCLIOptionCatalogService: any AgentCLIOptionCatalogServicing = AgentCLIOptionCatalogService(),
        terminalManager: TerminalSessionManaging = PlaceholderTerminalSessionManager(),
        systemAppearanceObserver: SystemAppearanceObserver = SystemAppearanceObserver(),
        renderHostClient: RenderHostClient = RenderHostClient(),
        isApplicationActive: @escaping () -> Bool = { false },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) { ... }
}
```

Stores are constructed from `AppEnvironment`:

```swift
@MainActor
final class WorkspaceStore: ObservableObject {
    init(environment: AppEnvironment) {
        self.persistenceActor = environment.persistenceActor
        self.sessionBindingActor = environment.sessionBindingActor
        // ... load initial state
    }
}
```

---

## Persistence Model

### Idempotency (Critical for Hot-Reload)

Every store mutation persists via actor calls:

```swift
persistenceActor.upsertProject(project)
persistenceActor.setLayoutState(layoutState)
persistenceActor.setRightPanelState(threadID: id, state: state)
```

These calls must be **idempotent**: calling `upsertProject(p1)` twice in a row saves once (UPSERT by ID). This is enforced by SQLite `INSERT … ON CONFLICT … DO UPDATE` in Chunk A.

### Snapshot Load Pattern (§Chunk 0.3)

On initialization, `AppEnvironment` creates stores in this order:

1. Load snapshot from `persistenceActor.load()` (one call)
2. Initialize each store with its slice of the snapshot
3. Stores reference `persistenceActor` for ongoing mutations

Snapshot contains:
```swift
struct YAAWSnapshot {
    let projects: [Project]
    let threads: [AgentThread]
    let selectedProjectID: UUID
    let selectedThreadID: UUID?
    let expandedProjectIDs: Set<UUID>
    let layoutState: LayoutState
    let rightPanelModesByThreadID: [UUID: RightPanelMode]
    let rightPanelStatesByThreadID: [UUID: RightPanelState]  // Now includes expanded/selected/nvim
    let bottomTerminalExpandedThreadIDs: Set<UUID>
    let threadActivityByThreadID: [UUID: ThreadActivityState]
    let fileIndexMetadataByThreadID: [UUID: FileIndexMetadata]
}
```

---

## Key Algorithms & Performance Targets

### activeThreadsForSelectedProject: O(1) @ 10k threads

**Current implementation (line 716):**
```swift
public var activeThreadsForSelectedProject: [AgentThread] {
    cachedActiveThreadsByProject[selectedProjectID] ?? []
}
```

**Mechanism:**
- Maintain `cachedActiveThreadsByProject: [UUID: [AgentThread]]`
- Whenever `threads` or `selectedProjectID` changes:
  1. Rebuild `threadIndexByID` (UUID → array index)
  2. Rebuild per-project caches, sorted by `threadPrecedes()`
- Every access is a dictionary lookup: **O(1) worst-case**

**Test assertion** (AppModelTests line 716-725):
```swift
func testThreadListsAreScopedToSelectedProject() {
    // Verify activeThreadsForSelectedProject returns only non-archived threads
    // for the selected project, in sorted order (pinned first, then recent)
}
```

**Target:** ≤ 0.1 ms read @ 10k threads (preserve current perf).

---

### Activity → Unread → Badge → Notification

**Current flow (line 3045-3099):**

1. `recordAgentTerminalNotification()` calls `applyThreadActivity(…, isUnread: true, shouldNotify: true)`
2. `applyThreadActivity()` computes:
   - `status` = event status or inferred from title/body
   - `preview` = truncated title+body for notification
   - `suppressNotification` = `shouldSuppressSystemNotification(threadID)` (line 3120-3124)
3. If `!hasSamePublishedActivity()` → update `@Published`:
   - `threadActivityByThreadID[threadID] = activity`
   - Persist via `persistThreadActivity()`
   - Call `updateDockBadge()` (sum unread count)
4. If `shouldNotify && activity.isUnread && !suppressNotification` → dispatch system notification

**Idempotency:** Identical activity (same status/preview/title/body) is not republished or persisted again. Timestamp updates alone do not trigger persistence.

**Test assertions** (AppModelTests):
- Line 83: `testTerminalNotificationUpdatesThreadActivityAndDispatchesSystemNotification()` — new unread activity → notification dispatched
- Line 110: `testFocusedSelectedThreadSuppressesUnreadAndSystemNotification()` — focused selected thread → no notification, unread set to false
- Line 293: `testPollingHelperActivityEventsUpdatesThreadActivity()` — activity lines parsed from capture log → status inferred, unread set correctly

---

### Session Linking (Auto-Detect + Manual)

**Behavior parity** (from AppModelTests; quoted from master plan §Chunk C):

1. **Auto-link on load** (line 1177-1201, 1304-1363, 1427-1494):
   - Unbound loaded threads (sessionIdentity == nil) attempt exact-name match
   - If unique match found → auto-link, set identity
   - If ambiguous → mark `sessionLinkRequiredThreadIDs`
   - If no match → mark required (user must manually link or start new)

2. **Auto-link during sync** (line 1551-1604, 1605-1686):
   - Selected thread with nil identity → poll for exact-name candidate
   - If found → auto-link without relaunching terminal if running
   - If not found but has identity → poll catalog metadata for updates

3. **Manual link** (line 1745-1796):
   - User selects candidate from `sessionLinkCandidates(for:)`
   - `linkSession()` applies identity + name

4. **Loud failure** (plan §Chunk C):
   - Format drift → visible thread state (not silent swallow)
   - Currently no "missing-tool" or "format-error" state; plan calls for it

---

## Test Behavior Parity (AppModelTests ~3403 lines)

Tests are grouped by domain; all must pass against new store APIs:

### Activity & Notifications (23 tests)
- Lines 36-312: Activity inference from output, terminal titles, command finish
- Lines 83-132: Notification dispatch + focus suppression
- Lines 148-232: Capture output + metadata metadata interaction
- **Asserts:** Status inference, unread flags, notification dispatch/suppression, dock badge updates

### Layout & Resize (11 tests)
- Lines 396-463: Bottom terminal toggle, panel collapse, resize, swap
- Lines 481-511: Persist on mutation, reset to defaults
- **Asserts:** State persisted on every operation, clamping applied, window-ratio max height

### Workspace & Selection (19 tests)
- Lines 520-714: Project/thread selection, archive/unarchive, pin/reorder, nav history
- Lines 1798-1880: Sorting by pin + recent interaction
- **Asserts:** Selection pushes history, archived hidden, pinned first, global project last

### Terminal & CLI (16 tests)
- Lines 2072-2157: Terminal launch requests per role, agent CLI options
- Lines 2182-2227: Configured defaults + launch option overrides
- **Asserts:** Agent PTY descriptor built, env/args applied, executable name resolved

### File Browser (12 tests)
- Lines 759-866: Selected thread working dir state, missing directory handling
- Lines 812-865: Snapshot reuse when same dir threads opened
- **Asserts:** Entries indexed, browser unavailable state set on missing dir

### Session Linking (10 tests)
- Lines 1137-1687: Stored identity resume, auto-link on load, manual link, start new
- Lines 2420-2558: Metadata capture during terminal run
- **Asserts:** Session identity restored, auto-link exact-name match, ambiguous marked required

### Configuration & Theme (6 tests)
- Lines 2261-2350: Config reload, system appearance, theme resolution, fonts
- **Asserts:** Hot-reload applies theme/font, system appearance drives resolved theme

---

## File:Line References for Trickiest Bits

| Concept | Current File:Lines | Notes |
|---|---|---|
| Activity idempotency check | AppModel.swift:3111-3118 | `hasSamePublishedActivity()` skips redundant publishes |
| Focus suppression logic | AppModel.swift:3120-3124 | Three-part conjunction: isApplicationActive && selectedThreadID && focusedProjectTerminalThreadID |
| Thread index rebuild | AppModel.swift:303-321 | Rebuild on every threads mutation; O(n) but amortized |
| Per-project cache | AppModel.swift:195-200 | Sorted insertion on thread move; cache validation in `updateCachedThread()` |
| Generation counters | AppModel.swift:1440-1446, 122 | Bumped on terminal close/link; checked in `finishAgentCLICaptureAndActivityPoll()` |
| Activity downgrade on launch | AppModel.swift:185-186, 3036-3043 | Loaded "working" → "inactive"; persisted back if changed |
| Terminal title heuristics | AppModel.swift:1158-1176, 2358-2361 | Title is authoritative (catalog) vs transient (tool activity) |
| Session link candidates | AppModel.swift:2021-2025 | User shown candidates; `linkSession()` applies |
| Browser URL normalization | AppModel.swift:1538-1553, 1729 | Adds `http://` or `https://` if needed |
| Nvim path per thread | AppModel.swift:999, 1695-1715 | Per-thread remembered; new UUID on open → terminates old |
| Subtree lazy expansion | AppModel.swift:2391-2427 | Pruned dirs re-loaded on expand; merged into existing index |

---

## Generation Counters to Replace with Task Cancellation

| Current Counter | Context | Replacement Strategy |
|---|---|---|
| `agentCLIPollGenerationByThreadID[UUID]` | Capture/activity poll dedup | Cancel poll Task on thread reselect, thread delete, or terminate |
| `isAgentCLICapturePollInFlight` | Guard against concurrent polls | Use Task lifecycle; single `Task` per thread for capture |
| `isAgentCLISessionSyncInFlight` | Guard against concurrent sync | Use Task lifecycle; cancel on thread reselect |
| `latestFileBrowserRequestIDByThreadID[UUID]` | Discard stale index results | Cancel file-index Task on reindex or thread switch |
| `pendingSubtreeLoadsByThreadID[UUID]` | Track in-flight lazy expansions | Cancel expansion Task when full index reloads |

**Pattern:** When a store method triggers a new async operation, store the `Task` handle. When preconditions change (thread selected/deleted/reselected), call `cancel()` on stored Task. No manual generation tracking needed.

---

## Error Handling & Loud Failure

The plan calls for "Typed errors surfaced to `ActivityStore`; truncation/drift = visible thread state" (§0.4 standards).

**Today:** Errors are logged to diagnostics but not surfaced to UI.

**Target:** Add error states to `ThreadActivityState`:
```swift
public enum ThreadActivityError: Equatable, Sendable {
    case missingWorkingDirectory(String)
    case missingTool(String)
    case agentCLIFormatDrift(String)  // e.g., session catalog unparseable
    case captureTruncated(bytesLost: Int)
}

public struct ThreadActivityState {
    // ... existing fields ...
    public var error: ThreadActivityError?
}
```

Thread UI displays error state (gray background, message) instead of silently swallowing.

---

## Decisions & Non-Decisions

### KEEP (from plan)

- **Durable file-index cache** (keyed by root + git identity + ignore fingerprint)
- **Lazy pruned-subtree expansion** (do not load all files on index)
- **350 ms FSEvents debounce** for file browser updates
- **Backpressure gate** (1 MB / 256 KB) for PTY output — stays in Chunk D helper
- **Hot-reload vs relaunch distinction**: rendering change (theme/font) → keep process; command/env → relaunch
- **Viewport replay on relaunch** (recoverable helper death)
- **Per-panel crash isolation** (helper process per surface, not in-process rendering)

### DELETE (from plan)

- **Overlay windows** (replaced by native composited helper output)
- **0.15 s viewport-polling loop** (replaced by push events)
- **Visibility leases** and orphan watchdogs
- **Z-order repair hacks**
- **NDJSON framing** (replaced by typed Codable + IOSurface/CAContext)
- **Generation counters** (replaced by Task cancellation)

### FIX (from plan)

- **Right-panel UI state persistence** (now saved in v16→v17 migration)
- **Lossy path encoding** (e.g., `/a-b` vs `/a/b`)
- **Idempotent snapshot save** (UPSERT + statement cache in Chunk A)

---

## Summary of Top Risks & Gotchas

1. **Circular dependency on systemAppearanceIsDark**: SettingsStore.resolvedTheme reads the live `systemAppearanceIsDark` published property. Ensure `SystemAppearanceObserver` pushes changes to SettingsStore before view reads. (Mitigate: single source of truth for appearance in SettingsStore, no re-deriving in views.)

2. **Thread index rebuild on every mutation**: When threads array mutates, all three caches (threadIndexByID, cachedActive/Archived) are rebuilt. This is O(n) but happens in response to user actions (new thread, archive, rename), not on every render. Monitor for large thread counts (10k+).

3. **Persisted right-panel UI state migration**: v16→v17 migration must safely add columns. Test round-trip: create thread → open file → expand folders → save → reload → verify state restored.

4. **Task cancellation race**: If a Task is cancelled while a database write is in-flight, the write may complete after cancellation (actor will ignore the result). Ensure PersistenceActor write methods are idempotent (they are, via UPSERT).

5. **File-browser cache invalidation**: If cache key (root + git identity + ignore rules fingerprint) doesn't change but .gitignore was edited, stale index is used. Mitigation: refresh button always forces re-index; file-watcher triggers full re-index on ignore-rule changes.

6. **Activity stream ordering**: If two activity updates arrive out of order (e.g., activity log reader races with terminal title reader), later update with older timestamp is discarded. Mitigate: always use server/app timestamp, not event timestamp.

7. **No retry on actor failure**: If PersistenceActor crashes during a write, the mutation is silently dropped (no retry). Mitigate: PersistenceActor is the most stable component; wrap its init in try/catch and fail fast if database is unusable on startup.

