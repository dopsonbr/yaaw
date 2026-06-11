# Chunk C — SessionBindingActor + Declarative CLIManifest Specification

**Status:** Port specification for Chunk C (one of parallel chunks A–E).  
**Blocking:** None after Chunk 0 contracts freeze.  
**Key outcome:** Replace hand-written four CLI adapters with declarative per-family `CLIManifest` driving a `SessionBindingActor`; surface format drift as visible thread state, not silent swallow.

---

## 1. Overview & Architecture Decision

The current `AgentCLISessionBindingService` (single class, ~1,710 lines, `@unchecked Sendable`) hand-codes four adapter classes with duplicated heuristics for catalog parsing, session linking, invocation templating, and output metadata scraping. The rewrite inverts this:

- **Before (hand-coded):**
  - `CodexCLIAdapter`, `ClaudeCLIAdapter`, `OpenCodeCLIAdapter`, `CopilotCLIAdapter` — each implement the `AgentCLIAdapter` protocol (~160 lines of boilerplate per adapter).
  - Catalog readers embedded in `AgentCLISessionCatalog` enum (~1,000 lines of nested match/map/filter).
  - Resume invocation templates hardcoded per adapter (`"resume"` vs `"--resume"` vs `"--session"` vs `"--resume="`) — mixed into `invocation()` method.
  - Permission presets discovered via `AgentPermissionMode.builtInModes()` or scanned from help text.
  - Metadata extraction via regex-like line-prefix parsing in `AgentCLIOutputParser` (~100 lines).

- **After (declarative manifest):**
  - Each CLI family owns a `CLIManifest` YAML/JSON struct (or Codable record) describing: invocation template, resume flag format, catalog paths, metadata extraction patterns, title-as-session-name policy, permission preset sources.
  - `SessionBindingActor` reads manifests and interprets them uniformly; adding a 5th CLI = manifest + test fixtures, no new adapter class.
  - Format drift (catalog rename, metadata field change) surfaced to user as "Drift Detected: Unable to parse session metadata" in thread state, not silent failure.
  - Two-tier strategy preserved: catalog scan (JSONL/JSON files) + live signal via XPC event (replaces polled capture log).

---

## 2. Current Implementation Details

### 2.1 Four Adapter Families (API Surface)

Each implements `AgentCLIAdapter` protocol; all Sendable.

#### **Codex** (`CodexCLIAdapter: AgentCLIAdapter`)
- **Executable name:** `"codex"`
- **Resume invocation template:** `["resume", $sessionID]` → `codex resume <id>`
- **Catalog paths:** `~/.codex/session_index.jsonl`, `~/.codex/history.jsonl`
- **Session identity fields:** `session_id`, `sessionId`, `id`, `conversation_id`, `thread_id`
- **Display name fields:** `thread_name`, `session_name`, `sessionName`, `title`, `name`, `summary`
- **Supports start name:** ✗ `supportsStartName = false`
- **Supports interactive rename:** ✓ `supportsInteractiveRename = true` → `/rename <name>\n` via `startupInput()`
- **Uses terminal title as session name:** ✓ `usesTerminalTitleAsSessionName = true` (title is transient; catalog is authoritative for codex)
- **Metadata output format:** `YAAW_SESSION_ID=codex-xyz`, `YAAW_SESSION_NAME=...`, `YAAW_SESSION_TITLE=...` (case-insensitive line prefixes)
- **Permission presets discovery:** Hardcoded `builtInModes(.codex)` OR scanned from `--help`: match `--ask-for-approval`, `--sandbox`, `--dangerously-bypass-...` flags.
- **Two-tier resume:** Catalog scan → `sessionLinkCandidates()` → `exactSessionLinkCandidate()` for auto-link on new thread; live capture via terminated process output.

**File references:** `AgentCLIAdapter.swift:139-179`, `AgentCLIAdapter.swift:1045-1129` (catalog scan).

---

#### **Claude** (`ClaudeCLIAdapter: AgentCLIAdapter`)
- **Executable name:** `"claude"`
- **Resume invocation template:** `["--resume", $sessionID]` → `claude --resume <id>`
- **Catalog paths:** `~/.claude/projects/<encoded-path>/*.jsonl` (where `<encoded-path>` = working directory with `/` → `-`, e.g. `/home/user/project` → `home-user-project`).
  - **Lossy encoding bug:** Directory `/a-b` and `/a/b` both encode to `a-b`; fixed in rewrite by using precise round-trip encoding.
- **Session identity fields:** `sessionId`, `session_id`, `id`, `uuid`
- **Display name fields (top-level only, no recursion):** 
  - Type `"custom-title"` → `customTitle` (highest precedence)
  - Type `"agent-name"` → `agentName` (fallback)
  - Type `"summary"` → `summary` (fallback)
  - *Note:* Tool use blocks embed `name: "Read"/"Bash"/...` but MUST NOT be recursively extracted (only top-level keys per type).
- **Supports start name:** ✓ `supportsStartName = true` → `--name <name>` on invocation
- **Supports interactive rename:** ✓ `supportsInteractiveRename = true` → `/rename <name>\n` but only if already resumed (i.e. `sessionIdentity != nil`)
- **Uses terminal title as session name:** ✗ `usesTerminalTitleAsSessionName = false` (Claude uses title for transient tool activity like "Bash", "Read"; catalog is authoritative)
- **Metadata output format:** `session id: claude-xyz`, `session name: ...`, `session title: ...`, or prefixed with CLI: `claude session id: ...`
- **Permission presets discovery:** Scanned from `--help`: must contain `--permission-mode`; if not found, fallback to empty (builtin modes not used for claude).
- **Signature for caching:** All `.jsonl` files under matching project directory.

**File references:** `AgentCLIAdapter.swift:181-233`, `AgentCLIAdapter.swift:1131-1295` (catalog & candidate parsing).

---

#### **OpenCode** (`OpenCodeCLIAdapter: AgentCLIAdapter`)
- **Executable name:** `"opencode"`
- **Resume invocation template:** `["--session", $sessionID]` → `opencode --session <id>`
- **Catalog paths:** `~/.local/share/opencode/storage/session/*/` (one session per JSON file)
- **Session identity fields:** `id`, `sessionID`, `sessionId`, `session_id`, or fallback to filename without extension
- **Display name fields:** `title`, `name`, `summary`, `description`
- **Supports start name:** ✗ `supportsStartName = false`
- **Supports interactive rename:** ✗ `supportsInteractiveRename = false`
- **Uses terminal title as session name:** ✓ `usesTerminalTitleAsSessionName = true`
- **Metadata output format:** `opencode session id: ...`, `session id: ...`, or prefixed
- **Permission presets discovery:** Always returns empty (no permission mode support).
- **Directory matching:** **Strict** — candidate MUST have exact `directory` field (no `allowUnknownDirectory`), unlike others.

**File references:** `AgentCLIAdapter.swift:235-266`, `AgentCLIAdapter.swift:1154-1200` (catalog scan).

---

#### **Copilot** (`CopilotCLIAdapter: AgentCLIAdapter`)
- **Executable name:** `"copilot"`
- **Resume invocation template:** `["--resume=\(sessionID)"]` → `copilot --resume=<id>` (note: `=`, not space)
- **Catalog paths:** `~/.copilot/session-state/*/vscode.metadata.json` (per-session metadata) + `~/.copilot/session-state/*/events.jsonl` (per-session events)
- **Session identity fields:** `session_id`, `sessionId`, `id` (from metadata or events)
- **Display name fields:** `name`, `title`, `sessionName`, `session_name`, `firstUserMessage`, `first_user_message`
- **Supports start name:** ✓ `supportsStartName = true` → `--name <name>` on invocation
- **Supports interactive rename:** ✓ `supportsInteractiveRename = true` → `/rename <name>\n` but only if already resumed
- **Uses terminal title as session name:** ✓ `usesTerminalTitleAsSessionName = true`
- **Metadata output format:** `copilot_session_id=...`, `copilot session id: ...`, or plain `session id: ...`
- **Permission presets discovery:** Scanned from `--help`: match flags like `--plan`, `--autopilot`, `--allow-all-tools`, `--allow-all`, `--yolo`.
- **Directory matching:** Strict (metadata or events must contain exact `cwd`/`directory`/`working_directory`).

**File references:** `AgentCLIAdapter.swift:268-317`, `AgentCLIAdapter.swift:1202-1359` (catalog & candidate parsing).

---

### 2.2 Current Invocation & Launch Options

**Invocation template flow:**
1. Adapter's `invocation()` method returns `AgentCLIInvocation`:
   ```swift
   public struct AgentCLIInvocation: Equatable, Sendable {
       public var executableName: String
       public var resolvedExecutablePath: String?
       public var arguments: [String]
       public var command: [String] { [resolvedExecutablePath ?? executableName] + arguments }
   }
   ```
2. Path resolved via `PATHAgentCLIExecutableResolver` (search `PATH` env var + fallback directories).
3. Permission arguments prepended by `AgentLaunchOptions.permissionArguments()` before adapter arguments.
4. Additional arguments from `AgentLaunchOptions.additionalArguments` appended.

**Current duplication bug:** `ToolSettings.agents` (executable name overrides) live in config YAML; `AgentLaunchOptions.permissionModeID` + `additionalArguments` live in per-thread SQLite `launch_options_json` column. Single source of truth missing.

**File references:** `AgentCLIAdapter.swift:510-551` (invocation construction), `src/Threads/AgentLaunchOptions.swift:1-125`.

---

### 2.3 Catalog Caching & Signatures

`AgentCLISessionBindingService` maintains an LRU cache (64 entries, NSLock-protected):
- **Key:** `(agentCLIKind, workingDirectoryPath)`
- **Value:** `(signature, candidates)`
- **Signature:** Combined hash of file sizes + mtime for all catalog files. Detects in-place edits; false negatives on same-size rewrites within one mtime tick (acceptable).
- **Stale check:** If cached signature == current signature, use cache without re-scanning.

**File references:** `AgentCLIAdapter.swift:382-403` (cache structure), `AgentCLIAdapter.swift:581-622` (lookup + update).

---

### 2.4 Session Linking Strategy (Two-Tier)

**Tier 1: Catalog scan** (happens on thread creation or `ThreadChoiceSheet` shown)
- `sessionLinkCandidates(for: thread)` → per-thread working directory
- Sort by: directory match > recency > name
- Filter by thread working directory

**Tier 2: Live capture (replaces timer in rewrite)**
- `terminalLaunchDescriptor()` → creates capture log + activity log URLs
- Terminal output written to capture log (8 MB circular buffer, truncation surfaced as event)
- `pollSelectedAgentCLICaptureLog()` reads capture log after offset (for recovery on relaunch)
- Metadata extracted via `AgentCLIOutputParser.metadata()` and stored in thread's `sessionIdentity` + `canonicalSessionName`

**Exact link:** `exactSessionLinkCandidate()` attempts automatic linking:
1. Normalize thread names (collapse whitespace, remove control chars)
2. Match against candidates by normalized display name + working directory
3. Return if exactly one match; else `nil`
4. Prevents ambiguous auto-link (e.g. two sessions named "test" in same dir → user must choose)

**File references:** `AgentCLIAdapter.swift:631-651` (exact link logic), `AgentCLIAdapter.swift:581-622` (candidate sorting).

---

### 2.5 Metadata Extraction (Output Parser)

**Patterns:**
- Line-by-line scan for patterns: `YAAW_SESSION_ID=`, `session_id=`, `<kind>_session_id=`, `<kind> session id:`, `session id:` (case-insensitive)
- Top-level keys (no recursion) for CLI output with nested structures (e.g. Claude JSON lines)
- Terminal control characters stripped before extraction
- Quotes stripped from values: `"session-id"` → `session-id`
- All three fields optional (identity required, name + title fallback to each other or identity)

**Return type:**
```swift
public struct AgentCLISessionMetadata: Equatable, Sendable {
    public var identity: String
    public var reportedName: String?
    public var title: String?
    public var canonicalName: String { reportedName ?? title ?? identity }
}
```

**File references:** `AgentCLIAdapter.swift:1608-1709` (output parser + string helpers).

---

### 2.6 Permission Presets

**Dual source:**
1. **Hardcoded:** `AgentPermissionMode.builtInModes(for: kind)` — static fallback
2. **Discovered:** `AgentCLIOptionCatalogParser.permissionPresets(kind:helpText:)` — scans `--help` output for supported flags

**Catalog entry:** `AgentCLIOptionCatalogEntry` stores `permissionPresets` array + diagnostic message.

**Validation:** `AgentLaunchOptions.validated(for:permissionModes:)` checks if `permissionModeID` is in supported list; if unsupported, drops it (no error, silent discard).

**File references:** `src/Threads/AgentLaunchOptions.swift:138-246` (built-in modes), `AgentCLIOptionCatalogService.swift:267-304` (parser).

---

## 3. Concurrency Model (Current)

**Thread safety:**
- `AgentCLISessionBindingService` is `@unchecked Sendable` (documented escape hatch for API compatibility).
- `catalogCacheLock = NSLock()` protects the three fields: `catalogCacheByKey`, `catalogCacheInsertionOrder`.
- All file I/O on main queue (no explicit async).
- `AgentCLIOptionCatalogService` also `@unchecked Sendable`, with internal file I/O.

**Generation counters:** Not present; instead: capture log offset tracking (`AgentCLICapturedOutput.nextOffset`) and cache signatures prevent stale reads.

**Cancellation:** No active cancellation; relies on Process timeout in `captureMetadataByRunningCLI()` (3s default).

---

## 4. Concurrency Model (Target Swift 6 Strict)

**New structure:**
```swift
actor SessionBindingActor {
    // Private state
    private let adaptersByKind: [AgentCLIKind: CLIManifest]
    private let resolver: any AgentCLIExecutableResolving
    private let environment: [String: String]
    private var catalogCacheByKey: [SessionCatalogCacheKey: SessionCatalogCacheEntry]
    // ... other immutable config
    
    // Public API (all async)
    func terminalCommand(for: AgentThread) -> [String]
    func sessionLinkCandidates(for: AgentThread) async -> [SessionLinkCandidate]
    func catalogMetadata(for: AgentThread) async -> AgentCLISessionMetadata?
    func capturedOutput(for: AgentThread, after: UInt64) async -> AgentCLICapturedOutput?
}
```

**Migration from `@unchecked Sendable`:**
- All public methods become `async`.
- Manifest storage shifts to immutable Codable struct (no lock needed for reads).
- Cache (mutable) stays private to actor; lock replaced by serial queue guarantee.
- File I/O remains main-thread-safe but must be explicitly awaited.

---

## 5. Declarative CLIManifest Schema

### 5.1 Structure

```swift
public struct CLIManifest: Codable, Equatable, Sendable {
    public var kind: AgentCLIKind
    public var executableName: String
    
    // Invocation template
    public var resumeTemplate: ResumeTemplate
    public var startNameCapability: StartNameCapability  // none / via-flag / via-startup-input
    public var renameCapability: RenameCapability       // none / via-startup-input
    public var usesTerminalTitleAsSessionName: Bool
    
    // Catalog locations & parsing
    public var catalogLocations: [CatalogLocation]
    public var sessionIdentityKeys: [String]  // priority-ordered field names
    public var displayNameKeys: [String]
    public var workingDirectoryKeys: [String]
    public var timestampKeys: [String]
    public var catalogMetadataExtractionRules: CatalogMetadataRules?
    
    // Output metadata scraping
    public var outputMetadataPatterns: [OutputMetadataPattern]  // line-prefix patterns
    
    // Permission presets
    public var permissionPresetSource: PermissionPresetSource  // hardcoded / discoverable / none
}

public enum ResumeTemplate: Codable, Equatable, Sendable {
    case positional(prefix: [String])  // ["resume"]           → "resume X"
    case flagSpaced(flag: String)      // "--resume"           → "--resume X"
    case flagEquals(flag: String)      // "--resume"           → "--resume=X"
}

public enum StartNameCapability: Codable, Equatable, Sendable {
    case none
    case viaFlag(flag: String)  // ["--name"]   → "--name X"
}

public enum RenameCapability: Codable, Equatable, Sendable {
    case none
    case viaStartupInput(command: String)  // "/rename {name}\n"
    case viaStartupInputIfResumed(command: String)  // only if sessionIdentity != nil
}

public struct CatalogLocation: Codable, Equatable, Sendable {
    public var basePath: String  // "~/.codex", "~/.claude/projects", etc.
    public var pattern: String   // "session_index.jsonl", "*.jsonl", "*/<id>.json"
    public var fileFormat: CatalogFileFormat
}

public enum CatalogFileFormat: String, Codable {
    case jsonl
    case json
}

public struct OutputMetadataPattern: Codable, Equatable, Sendable {
    public var field: OutputMetadataField  // .sessionIdentity / .displayName / .title
    public var prefixes: [String]  // case-insensitive prefix list
    public var topLevelOnly: Bool  // if true, only search dict top level (Claude use case)
}

public enum OutputMetadataField: String, Codable {
    case sessionIdentity
    case displayName
    case title
}

public enum PermissionPresetSource: Codable, Equatable, Sendable {
    case hardcoded  // use builtInModes()
    case discoverable  // scan --help output
    case none
}

public struct CatalogMetadataRules: Codable, Equatable, Sendable {
    public var topLevelFields: [String: String]  // "type" -> field name for type-dependent extraction
    public var recursionBehavior: RecursionBehavior
}

public enum RecursionBehavior: String, Codable {
    case full  // recurse into nested objects/arrays
    case topLevelOnly  // only top-level keys
    case conditional  // recurse except in certain keys
}
```

### 5.2 Manifest Instances (YAML/JSON)

**Codex manifest:**
```yaml
kind: codex
executableName: codex
resumeTemplate: { positional: { prefix: ["resume"] } }
startNameCapability: none
renameCapability: { viaStartupInput: "/rename {name}\n" }
usesTerminalTitleAsSessionName: true
catalogLocations:
  - basePath: "~/.codex"
    pattern: "session_index.jsonl"
    fileFormat: jsonl
  - basePath: "~/.codex"
    pattern: "history.jsonl"
    fileFormat: jsonl
sessionIdentityKeys: ["session_id", "sessionId", "id", "conversation_id", "thread_id"]
displayNameKeys: ["thread_name", "session_name", "sessionName", "title", "name", "summary"]
workingDirectoryKeys: ["cwd", "working_directory", "workingDirectory", "directory", "path"]
timestampKeys: ["updated_at", "updatedAt", "timestamp", "created_at", "createdAt"]
outputMetadataPatterns:
  - field: sessionIdentity
    prefixes: ["yaaw_session_id=", "session_id=", "codex_session_id=", "codex session id:", "session id:"]
    topLevelOnly: false
  - field: displayName
    prefixes: ["yaaw_session_name=", "session_name=", "codex_session_name=", "codex session name:", "session name:", "name:"]
    topLevelOnly: false
permissionPresetSource: discoverable
```

**Claude manifest:**
```yaml
kind: claude
executableName: claude
resumeTemplate: { flagSpaced: { flag: "--resume" } }
startNameCapability: { viaFlag: { flag: "--name" } }
renameCapability: { viaStartupInputIfResumed: "/rename {name}\n" }
usesTerminalTitleAsSessionName: false
catalogLocations:
  - basePath: "~/.claude/projects"
    pattern: "{encoded-workdir}/*.jsonl"  # encoded = path with / -> -
    fileFormat: jsonl
sessionIdentityKeys: ["sessionId", "session_id", "id", "uuid"]
displayNameKeys: ["customTitle", "agentName", "summary"]  # custom-title > agent-name > summary
workingDirectoryKeys: ["cwd", "working_directory", "workingDirectory", "directory"]
timestampKeys: ["timestamp", "updated_at", "updatedAt", "created_at", "createdAt"]
catalogMetadataRules:
  topLevelFields:
    type: "type"  # the key that disambiguates line type
    customTitle: { ifType: "custom-title", field: "customTitle" }
    agentName: { ifType: "agent-name", field: "agentName" }
    summary: { ifType: "summary", field: "summary" }
  recursionBehavior: topLevelOnly
outputMetadataPatterns:
  - field: sessionIdentity
    prefixes: ["yaaw_session_id=", "session_id=", "claude_session_id=", "claude session id:", "session id:"]
    topLevelOnly: false
permissionPresetSource: discoverable
```

**OpenCode manifest:**
```yaml
kind: opencode
executableName: opencode
resumeTemplate: { flagSpaced: { flag: "--session" } }
startNameCapability: none
renameCapability: none
usesTerminalTitleAsSessionName: true
catalogLocations:
  - basePath: "~/.local/share/opencode/storage/session"
    pattern: "*.json"
    fileFormat: json
sessionIdentityKeys: ["id", "sessionID", "sessionId", "session_id"]
displayNameKeys: ["title", "name", "summary", "description"]
workingDirectoryKeys: ["directory", "cwd", "working_directory", "workingDirectory", "path"]
timestampKeys: ["updated", "updated_at", "updatedAt", "time", "created_at"]
outputMetadataPatterns:
  - field: sessionIdentity
    prefixes: ["yaaw_session_id=", "session_id=", "opencode_session_id=", "opencode session id:", "session id:"]
    topLevelOnly: false
permissionPresetSource: none
directoryMatchingStrict: true  # must have explicit directory, no unknownDirectory
```

**Copilot manifest:**
```yaml
kind: copilot
executableName: copilot
resumeTemplate: { flagEquals: { flag: "--resume" } }
startNameCapability: { viaFlag: { flag: "--name" } }
renameCapability: { viaStartupInputIfResumed: "/rename {name}\n" }
usesTerminalTitleAsSessionName: true
catalogLocations:
  - basePath: "~/.copilot/session-state"
    pattern: "*/vscode.metadata.json"
    fileFormat: json
  - basePath: "~/.copilot/session-state"
    pattern: "*/events.jsonl"
    fileFormat: jsonl
sessionIdentityKeys: ["session_id", "sessionId", "id"]
displayNameKeys: ["name", "title", "sessionName", "session_name", "firstUserMessage", "first_user_message"]
workingDirectoryKeys: ["cwd", "directory", "working_directory", "workingDirectory", "path"]
timestampKeys: ["updated_at", "updatedAt", "timestamp", "created_at"]
outputMetadataPatterns:
  - field: sessionIdentity
    prefixes: ["yaaw_session_id=", "session_id=", "copilot_session_id=", "copilot session id:", "session id:"]
    topLevelOnly: false
permissionPresetSource: discoverable
directoryMatchingStrict: true
```

---

## 6. Tests & Behavior Parity

All existing behavior tests in `AgentCLIAdapterTests.swift` (1,099 lines) MUST pass without modification:

### Key Test Categories:

1. **Command construction** (`testResumeCommandConstructionUsesStoredIdentity`, etc.) — verify exact template output
2. **Launch options** (`testLaunchOptionsPrependPermissionAndAdditionalArgumentsBeforeResume`) — permission + additional args ordering
3. **Option parsing** (`testLaunchOptionsArgumentParserSupportsQuotesAndEscapes`, `testLaunchOptionsArgumentParserRejectsUnclosedQuote`)
4. **PATH resolution** (`testPATHResolverSearchesFallbackDirectoriesAfterProcessPath`)
5. **Adapter-specific resume flags** (`testClaudeResumeCommandUsesCurrentResumeFlag`, `testOpenCodeResumeCommandUsesSessionFlag`, `testCopilotResumeCommandUsesEqualsResumeFlag`)
6. **Capabilities** (`testStartNameAndInteractiveRenameCapabilitiesUseAdapterContracts`) — which adapters support what
7. **Terminal title policy** (`testUsesTerminalTitleAsSessionNameIsFalseOnlyForClaude`)
8. **Session catalog readers** (`testSessionCatalogReadersReturnWorkingDirectoryCandidates`) — all four families parse their catalog format
9. **Exact candidate linking** (`testExactSessionLinkCandidateRejectsUniqueCodexNameWithoutWorkingDirectory`, `testExactSessionLinkCandidateUsesCodexHistoryWhenIndexIsMissingSession`, `testExactSessionLinkCandidateReadsClaudeCustomTitle`, `testClaudeCandidateIgnoresNestedToolUseNames`)
10. **Ranking** (`testManualSessionLinkCandidatesRankDirectoryMatchesBeforeRecency`)
11. **Metadata parsing** (`testCanonicalNamePrefersReportedNameThenTitleThenIdentity`, `testMetadataParserIgnoresScriptTerminalControls`)
12. **Live capture** (`testCommandDoublesExerciseLaunchCaptureAndResumeCapture`, `testTerminalLaunchDescriptorUsesShellWithoutNestedScriptWhenCaptureIsConfigured`)
13. **Capture rotation recovery** (`testCapturedOutputRecoversAfterCaptureLogRotation`)
14. **Notify helper** (`testNotifyHelperWritesActivityEventAndTerminalNotification`)
15. **Persistence roundtrip** (`testCapturedMetadataPersistsThroughSQLiteReload`)

### New Tests (Manifest-Driven):

- **Fixture-based conformance:** For each family, test a recorded JSONL/JSON fixture catalog and verify exact candidate extraction (identity, name, dir, timestamp).
- **Drift detection:** Mock a catalog with a missing field; verify thread state shows "Unable to parse session metadata (drift detected)" instead of silent nil.
- **Resume invocation per manifest:** Parameterized test verifying each `ResumeTemplate` variant produces correct argument structure.
- **Output metadata pattern matching:** For each pattern list, provide CLI output samples and verify extraction order/fallback.

**File references:** `src/Tests/YAAWKitTests/AgentCLIAdapterTests.swift` (all 1,099 lines), `src/Tests/YAAWKitTests/AgentCLIOptionCatalogTests.swift` (82 lines).

---

## 7. Key Behaviors & Constants

### 7.1 Resume Invocation Per Family

| Family | Template | Example | Code line |
|--------|----------|---------|-----------|
| Codex | `["resume", $id]` | `codex resume abc-123` | 153 |
| Claude | `["--resume", $id]` | `claude --resume abc-123` | 194 |
| OpenCode | `["--session", $id]` | `opencode --session abc-123` | 249 |
| Copilot | `["--resume=$id"]` | `copilot --resume=abc-123` | 281 |

### 7.2 Launch Descriptor (Wrapper Shell)

When `captureDirectory` is set (i.e. terminal with capture), the returned descriptor wraps the agent command in a shell:
```
sh -lic "
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  <agent-command>
  yaaw_exit_status=$?
  if [ \"$yaaw_exit_status\" -ne 0 ]
    then printf '\\nYAAW: agent command exited with status %s\\n' \"$yaaw_exit_status\"
  fi
  exec <shell> -l
"
```

**Purpose:** Catch agent exit status for logging, then drop to interactive shell (prevents terminal from closing).

**File references:** `AgentCLIAdapter.swift:500-507`.

### 7.3 Capture Log Management

- **Path:** `${CAPTURE_DIR}/${thread.id.uuidString}.log`
- **Max size:** 8 MB (circular, truncation surfaced as XPC event)
- **Write:** Direct append via PTY backpressure gate (no buffering)
- **Read:** Offset-based (`after: UInt64`) with stale-window detection
- **Stale window:** 8 MB default; if file > window and offset beyond file, clamp to `file.size - maxBytes`

**File references:** `AgentCLIAdapter.swift:857-915` (captured output API), `AgentCLIAdapter.swift:857` (staleWindow const).

### 7.4 Activity Log (NDJSON Events)

- **Path:** `${ACTIVITY_DIR}/${thread.id.uuidString}.ndjson`
- **Format:** One JSON object per line, written by `yaaw-notify` helper
- **Fields:** `thread_id`, `status` (needs-input / working / complete / inactive), `title`, `body`, `source` (helper), `created_at` (unix timestamp)
- **Read:** Via `capturedActivityEvents(for:after:)` same offset-based API as capture log

**File references:** `AgentCLIAdapter.swift:716-779` (notifyHelperScript).

### 7.5 Catalog Cache

- **Capacity:** 64 LRU entries (oldest evicted on overflow)
- **Key:** `(agentCLIKind, workingDirectoryPath.standardized)`
- **Signature:** Combined SHA-like hash of (path, kind, mtime, size) for all catalog files
- **Hit rate improvement:** Durable across app lifetime (single `AppModel` instance)

**File references:** `AgentCLIAdapter.swift:382-403`, `AgentCLIAdapter.swift:581-622`.

### 7.6 Lossy Path Encoding (Claude) — Bug to Fix

**Current behavior:**
```swift
let encoded = workingDirectory.path.replacingOccurrences(of: "/", with: "-")
// /home/user/a-b  →  home-user-a-b
// /home/user/a/b  →  home-user-a-b  (COLLISION!)
```

**Fixed behavior:**
Use reversible encoding:
```swift
let encoded = workingDirectory.path
  .split(separator: "/")
  .map { part in part.replacingOccurrences(of: "-", with: "--") }
  .joined(separator: "-")
// /home/user/a-b  →  home-user-a---b  (escapes the - in a-b)
// /home/user/a/b  →  home-user-a-b
```

**File references:** `AgentCLIAdapter.swift:1226` (bug location in claude project directory lookup).

### 7.7 Permission Preset Discovery & Fallback

**Strategy:**
1. Try `AgentCLIOptionCatalogParser.permissionPresets(kind:helpText:)` from cached `--help` output
2. If found, use discovered list; cache in `AgentCLIOptionCatalogEntry.permissionPresets`
3. If discovery fails (timeout, missing, unrecognized format), fallback to `AgentPermissionMode.builtInModes(for:kind)`
4. Validation: `AgentLaunchOptions.validated(for:permissionModes:)` drops unsupported mode IDs (no error)

**Hardcoded builtin modes:**
- **Codex:** on-request, never, on-failure, untrusted, read-only, workspace-write, full-access, bypass
- **Claude:** plan, auto, accept-edits, dont-ask, bypass-permissions
- **OpenCode:** (empty; no permission mode support)
- **Copilot:** plan, autopilot, allow-all-tools, allow-all, yolo

**File references:** `src/Threads/AgentLaunchOptions.swift:138-246` (builtInModes), `AgentCLIOptionCatalogService.swift:146-184` (probe + fallback), `AgentCLIAdapter.swift:510-551` (invocation with permission args).

### 7.8 Executable Resolution

**Precedence:**
1. `AgentLaunchOptions.executableName` override (user-set, e.g. `codex-beta`)
2. Adapter's `executableName` (e.g. `"codex"`)
3. Resolve via `PATHAgentCLIExecutableResolver`: search process `PATH` env var, then fallback dirs

**Fallback dirs:** `/opt/homebrew/bin`, `/opt/homebrew/sbin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`.

**File references:** `AgentCLIAdapter.swift:323-361` (PATHAgentCLIExecutableResolver).

---

## 8. Plan References & Acceptance Criteria

### Chunk C scope from master plan:

> **Chunk C — SessionBindingActor + declarative CLI manifests**
> - **Scope:** Quarantine the heuristics. Replace the four hand-written adapters with a `SessionBindingActor` driving a **declarative `CLIManifest` per family** (invocation templates, catalog paths, metadata-extraction patterns, title-as-session-name policy). Keep the two-tier strategy (catalog scan + live capture signal — but the live signal now arrives as an **XPC event** from the helper, not a polled capture log). **Loud failure**: format drift surfaces as a visible thread state, not silent. Recorded-fixture conformance tests per CLI. Fix the lossy path encoding (`/a-b` vs `/a/b`).
> - **Acceptance:** all four families resume correctly from fixtures; unsupported permission modes ignored per family; manifest-driven (adding a 5th CLI = a manifest + fixtures, no new adapter class).

**Acceptance Checklist:**

- [ ] `SessionBindingActor` replaces `AgentCLISessionBindingService` with all public methods async
- [ ] Four `CLIManifest` instances (Codex, Claude, OpenCode, Copilot) fully define invocation/catalog/metadata behavior
- [ ] All 1,099 lines of `AgentCLIAdapterTests.swift` pass without modification (behavior parity)
- [ ] Fixture-based tests for each family catalog + resume invocation
- [ ] **Drift detection:** Catalog format change (missing field) surfaces as visible thread state "Drift Detected: Unable to parse metadata for <identity>" instead of silent nil return
- [ ] **Lossy encoding fix:** Claude path encoding reversible; `/a-b` ≠ `/a/b`
- [ ] **Loud permission failure:** Unsupported `permissionModeID` logged/visible, not silently dropped (change from current behavior)
- [ ] Live capture signal via XPC event stream (not polled capture log) — integration point with Chunk D
- [ ] Two-tier strategy preserved: catalog scan for listing + live capture for linking

---

## 9. Edge Cases & Error Handling

### 9.1 Missing Catalog Files
- If `~/.codex/session_index.jsonl` missing: return empty candidates, fallback to `history.jsonl`
- If `~/.claude/projects` missing: return empty candidates, no error
- Signature still valid (fingerprints missing files as "missing" in hash)

### 9.2 Malformed JSONL/JSON
- Parse error on single line: skip that line, continue (resilient to corruption)
- Empty file: return empty candidates
- Invalid JSON on entire file: return empty candidates, log diagnostic

### 9.3 Metadata Extraction Failure
- **Current (silent):** `metadata()` returns `nil` if no identity found
- **Target (loud):** Thread state updated to `.driftDetected(reason: "...format change...topic")` ; thread still functional but user sees signal

### 9.4 Permission Mode Validation
- **Current (silent):** `validated()` drops unsupported modes without error
- **Target (loud change):** Log diagnostic or update ActivityStore if mode is unsupported but was explicitly requested

### 9.5 Capture Log Rotation
- Offset beyond file size: reset to 0 (assume rotation)
- Truncation detected (file shrunk): reset to 0
- Stale window exceeded (offset > file - 8MB): clamp to file - maxBytes

### 9.6 Session Linking Ambiguity
- Multiple candidates with same normalized name + directory: `exactSessionLinkCandidate()` returns `nil` (user must choose manually)
- Zero candidates: `nil` (user must enter session ID manually or catalog needs refresh)

---

## 10. Implementation Sequence & Dependencies

**Phase 1: Manifest definition**
- Define `CLIManifest` + enums (Codable, Swift 6 strict)
- Hardcode four manifests or load from YAML (defer YAML parsing to integration)

**Phase 2: SessionBindingActor**
- Refactor current service logic into actor
- Replace catalog scanning with manifest-driven loop
- Preserve cache (now private to actor)

**Phase 3: Metadata & invocation interpretation**
- Build `invocation()` from manifest templates
- Build metadata extractor from manifest patterns
- Catalog reader from manifest locations + format

**Phase 4: Output metadata error handling**
- On parse failure, surface to `ActivityStore` as drift event
- Update thread state display

**Phase 5: Integration with Chunk D (XPC event stream)**
- Replace polled capture log with AsyncStream from helper
- Activity log now pushed as event, not polled

**Dependencies:**
- None on other chunks (A–E independent)
- Chunk D integration point: XPC event stream for live metadata capture
- Chunk E integration point: ActivityStore for drift state display

---

## 11. Concurrency Migration Hazards

**Sources of data races (current):**
1. `@unchecked Sendable` escape hatch hides true unsafety of mutable cache
2. NSLock synchronization is manual and error-prone
3. File I/O assumed main-thread-safe (no explicit guarantees)

**Fixes in rewrite:**
1. Cache made private to actor (no public mutation)
2. NSLock removed; actor serial guarantees ordering
3. File I/O explicitly bounded to actor (async wrapper)
4. Manifests immutable after init (no need for locks)

**Remaining hazard:**
- Helper process output read via `FileHandle` (non-async); must not block main actor (defer to background queue or use `AsyncSequence` wrapper)

---

## 12. Files to Port & Delete

### Port (largely as-is, reintegrated into actor):
- `AgentCLIAdapter.swift:510-551` → invocation builder (manifest-driven)
- `AgentCLIAdapter.swift:581-622` → candidate ranking + cache (moved into actor)
- `AgentCLIAdapter.swift:631-651` → exact linking (moved into actor)
- `AgentCLIAdapter.swift:857-915` → capture log reading (moved into actor)
- `AgentCLIAdapter.swift:1608-1709` → output metadata parser (manifest-driven)
- `AgentCLIAdapter.swift:1608-1709` → string utilities (nilIfBlank, etc.) → stdlib/helpers

### Delete (replaced by declarative manifests):
- `CodexCLIAdapter`, `ClaudeCLIAdapter`, `OpenCodeCLIAdapter`, `CopilotCLIAdapter` classes (~160 lines each)
- `AgentCLISessionCatalog` enum (~1,000 lines nested scanning logic)
- Hand-written per-adapter session/metadata extraction (~600 lines)

### Keep (no change needed):
- `AgentCLIInvocation`, `AgentCLISessionMetadata`, `SessionLinkCandidate` DTOs
- `PATHAgentCLIExecutableResolver` (PATH search logic, unchanged)
- `AgentLaunchOptions` + `AgentPermissionMode` (validation + parsing, unchanged)
- `AgentCLIOptionCatalogService` (discovery + caching, renamed role to manifest-discovery)
- Test utilities (`StaticExecutableResolver`, `temporaryDirectory()`, etc.)

---

## 13. Tightened Standards (Chunk C New Code)

Applies to all new SessionBindingActor + CLIManifest code:

- **Swift 6 strict concurrency:** `complete` mode, zero `@unchecked Sendable`, zero `@unchecked Sendable` in new public APIs
- **File length:** warn 400 LOC / err 800 LOC
- **Cyclomatic complexity:** warn 8 / err 12
- **Function body length:** warn 50 / err 120
- **Type body length:** warn 250 / err 400
- **Zero new `swiftlint:disable` directives**
- **Public docs:** All public types + methods documented per `AllPublicDeclarationsHaveDocumentation: true`

---

## 14. Top Risks & Mitigations

| Risk | Likelihood | Mitigation |
|------|------------|-----------|
| Manifest YAML parsing complexity | Medium | Start with Codable Swift structs; defer YAML parsing to integration phase. Hardcode four manifests for this chunk. |
| Fixture test maintenance (4 families × catalog format changes) | Low-Medium | Recorded fixtures in test bundle; update on CLI version bump; conformance tests parameterized. |
| Drift detection surfacing too verbose or too silent | Medium | Define error categories (format change / missing field / encoding error) and display rules in Chunk E ActivityStore. Test with recorded broken catalogs. |
| XPC integration for live signal (Chunk D dependency) | Medium | Live capture polled from capture log remains as fallback; async event stream (Chapter D) overlays gracefully. |
| Permission preset discovery timeout (3s default) | Low | Timeout already in place; fallback to builtInModes() tested; increase timeout if needed in integration. |
| Lossy path encoding regression (Claude) | Low | Comprehensive test with directories like `/a-b`, `/a/b`, `/a-b-c`; round-trip encode/decode verification. |

---

## Summary

Chunk C replaces hand-coded adapter heuristics with data-driven `CLIManifest` structs and moves session binding logic into a `SessionBindingActor`. The four families (Codex, Claude, OpenCode, Copilot) each define their invocation template, catalog locations, metadata extraction patterns, and permission preset strategy in a declarative record. All existing behavior tests pass; new tests verify fixture conformance and drift detection. The two-tier linking strategy (catalog scan + live capture) is preserved; drift is surfaced as visible thread state, not silent failure. Adding a fifth CLI requires only a manifest + fixtures, no new code.
