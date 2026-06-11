# Chunk G — E2E Harness & Acceptance Testing Specification

## Overview

The E2E subsystem bridges the new architecture's multi-process topology with deterministic, headless acceptance testing. It validates per-panel crash isolation, compositing integrity, terminal lifecycle transitions, and the full no-mock user journey (create → resume → archive → relaunch → persist). All probes must run headless by default with no focus steal between checks.

### Scope

- ScreenCaptureKit composite screenshots scoped to the app's own windows + owner-pid-scoped overlays.
- PID-targeted CGEvents for input (`postToPid`), removing dependency on frontmost app state.
- AXIdentifier-based control targeting instead of coordinate-click brittle coupling.
- Debug command channel over XPC for deterministic state setup without UI journeys.
- Per-helper PID scoping in assertions and lifecycle probes.
- Crash-isolation probe: `kill -9` a render helper; assert app + siblings survive, frontmost unchanged, killed pane recovers.
- Screenshot-parity comparison vs baseline images in `/Users/BXD5017/github/dopsonbr/yaaw/docs/examples/screenshots/current/`.
- Performance benchmark gates wired to `RUN_BENCHMARKS=1 swift test -c release`.

---

## Key Design Decisions

### Headless-Default Architecture

Per `test-e2e.sh` lines 12–17, headless is the primary mode:
- Passes `--headless` to environment; legacy `--headed` flag available.
- E2E app launched with `-g` flag (background, no focus steal).
- No AppleScript window raise operations; only layout adjustments.
- Frontmost app is polled via `frontmost` driver command; must never be the E2E app itself (line 184–194).

### ScreenCaptureKit Compositing

**Current state** (`E2EDriverCommands.swift:36–103`):
- Selects main window by PID; finds largest on-screen window.
- Filters to display holding most of the window; clamps sourceRect to that display.
- Includes owner-pid-scoped overlays (helper windows) that intersect the main frame (line 56–58).
- Scales per `pointPixelScale` for retina displays.
- Exports to PNG via `CGImageDestination`.

**Baseline images**:
- `docs/examples/screenshots/current/` contains reference images:
  - `main-workspace-files-terminal.png` (main + project terminal visible)
  - `main-workspace-browser-preview.png` (HTML/MD/PDF preview in right panel)
  - `appearance-settings-theme-fonts.png` (settings window, themes/fonts panels)
  - `agents-settings-launch-defaults.png` (agents launch defaults)
- Visual-state databases generate transient screenshots in `$ARTIFACT_DIR/screenshots/{launch,files,nvim,git,…}.png`.

### PID-Targeted Input (No Focus Steal)

**CGEvent posting** (`E2EDriverCommands.swift:115–182`):
- `send-key --pid <pid> --key <name> [--modifiers command,shift,option,control]`
- `send-click --pid <pid> --x <n> --y <n>`
- Events posted via `CGEvent.postToPid(pid)` with 60ms inter-event sleep.
- Key codes hardcoded in `virtualKeyCodesByName` (line 107–113): ASCII letters, numbers, special keys (return, brackets, comma, period, space).
- Modifiers bitmask combined from flags.

**Headless keyboard probe** (`test-e2e.sh:871–921`):
- Sets env var `YAAW_E2E_KEYBOARD_PROBE=1` in command doubles.
- Doubles print `YAAW_KEYBOARD_PROBE_READY` and block reading stdin.
- Test sends `Cmd+V` (paste) + Enter via `send-key` to selected terminal helper PID.
- Doubles echo `YAAW_ENTER_RECEIVED=<pasted-text>` to capture log.

### AXIdentifier Targeting (Upgraded)

**Current baseline** (`test-e2e.sh:752–789`):
- AppleScript `findByIdentifier` recursively searches AX tree for `AXIdentifier` attributes.
- Example: `settings-sidebar-config-file`, `settings-yaml-editor`, `settings-save-button`, `open-settings-button`, `toggle-sidebar-button`, `toggle-right-panel-button`.
- `selectSidebarRow` helper climbs AX parent chain to find `AXRole == "AXRow"` and sets `AXSelected = true`.

**Rewrite upgrade**:
- Every interactive control gets stable `accessibilityIdentifier` (Chunk F mandate).
- E2E scripts use ID-based targeting; coordinate clicks only as fallback.
- Reduces flakiness from layout changes.

### Command Doubles (Deterministic Fixtures)

**Layout** (`YAAWE2E.swift:133–311`):
- Written to `$ARTIFACT_DIR/bin/` (earlier in PATH before real CLIs).
- Five families: `codex`, `claude`, `opencode`, `copilot`, `nvim`, `lazygit`, `vim`, `vi`, `git`.
- Each responds to `--help`, `--version`, and family-specific session flags (`resume`, `--resume`, `--session`, `--resume=`).
- Output deterministic YAML: `YAAW_SESSION_ID=<identity>`, `YAAW_SESSION_NAME=<display-name>`.
- On TTY, codex/claude loop with ticks; others sleep 1s; nvim/vim/vi/git/lazygit sleep 1s then exit.

**Current doubles** (lines 136–302):
- `codex` / `claude` / `opencode` / `copilot` — agent CLIs returning session metadata.
- `nvim` / `vim` / `vi` — editors returning `NVIM_DOUBLE`, `VIM_DOUBLE`, `VI_DOUBLE` + args.
- `git` / `lazygit` — returning `GIT_DOUBLE` or `LAZYGIT_DOUBLE`; lazygit has no fallback.

### Deterministic Fixture Databases

**Setup** (`YAAWE2E.swift:45–57`):
- Resets artifacts directory (line 59–78).
- Writes fixture project with sample files: `README.md`, `.git/HEAD`, `.env`, `index.html`, `diagram.svg`, `src/App/RootView.swift`.
- Seeded with sandbox project and fixture project; theme pinned to `ghostty-default` (not System mode).

**Focused behavior database** (lines 320–785):
- Single comprehensive flow testing all domain behaviors.
- Creates 4 threads (codex, claude, opencode, copilot); threads are named, pinned, archived.
- Records agent output; simulates metadata capture and rename interactions.
- Tests file indexing, browser tabs, nvim/git launches, layout state (widths, swap, terminal height).
- Persists and reloads to verify session resumption.

**Visual state databases** (lines 829–883):
- For each `VisualState` enum case, generates a fresh database and screenshots:
  - `.launch` — empty new project
  - `.projectCreation` — skipped (no visual diff)
  - `.files` — file index cached, README.md visible
  - `.nvim` — nvim launched on README.md
  - `.git` — lazygit tab selected
  - `.missingDirectory` — project root deleted then re-indexed
  - `.missingTool` — lazygit removed from PATH; tests fallback to `git diff`
  - `.bottomTerminal` — bottom terminal expanded
  - `.panelResize` — sidebar/right-panel/terminal resized; window swapped
  - `.panelCollapse` — sidebar and right panel collapsed
  - `.keyboardInput` — keyboard probe prepped

### No-Focus-Steal Assertions

**Headless contract** (`test-e2e.sh:184–195`):
- After every major probe, `frontmost` driver command verifies app bundle ID is not `dev.dopsonbr.YAAW.E2E`.
- Asserts logged to `$FOCUS_BLOCKER` file; CI warning only (line 1229–1235).

---

## Current Test Structure

### Script Entry Points

#### `scripts/test-e2e.sh` (top-level orchestrator)

**High-level flow** (line 27–1240):
1. Build app variant (line 31).
2. Define helper functions (line 39–195):
   - `running_e2e_app_pids()` — grep for binary in process list.
   - `terminal_helper_pids()` — find YAAWToolHost processes by args.
   - `helper_window_count_with_prefix()` — AppleScript AX count visible windows.
   - `launch_e2e_app(database_path, app_path, context)` — kill old, set env, open app, wait for window.
   - `capture_window(output_path)` — ScreenCaptureKit capture or region fallback.
3. Run Swift E2E runner (`swift run YAAWE2E --artifacts`), collect exit code (line 178).
4. If runner exits 0, launch transient visual states + probe sequences:
   - `run_keyboard_input_probe()` (line 871–921) — paste + Enter to focused helper.
   - `run_isolated_terminal_visibility_probe()` (line 923–1020) — toggle bottom terminal, switch tabs, resize window, verify helpers remain visible.
   - `run_workspace_shortcut_probe()` (line 792–869) — Cmd+J/Cmd+[/]/1/2/3/Cmd+Q shortcuts and settings open.
   - `run_settings_editor_probe()` (line 1022–1197) — open settings via button, edit YAML, save, close, verify toolbar buttons.
5. Launch visual state screenshots (line 1216–1220).
6. Check `$SCREENSHOT_BLOCKER` and `$FOCUS_BLOCKER` files for failures (line 1222–1237).

**Exit codes**:
- 0 → all probes + screenshots passed.
- nonzero → runner failed OR a probe/screenshot failed.

#### `src/E2E/YAAWE2E.swift` (focused behavior runner)

**Main flow** (`main()` line 7–19):
- Parses `--artifacts <dir>`.
- Creates `E2ERunner`, calls `run()`.
- Catches errors, writes to stderr, exits 1.

**E2ERunner.run()** (line 44–57):
1. `resetArtifacts()` — clean `$ARTIFACT_DIR`, create subdirectories.
2. `writeFixtureProject()` — populate `fixture-project` with markdown/HTML/code.
3. `writeCommandDoubles()` — create shell script mocks in `bin/`.
4. `reloadConfiguration()` — write pinned theme to `settings.yaml`.
5. `runFocusedBehaviorAssertions()` — full state machine test (lines 320–785).
6. `writeVisualStateDatabases()` — generate per-state screenshots (lines 829–883).
7. `assertStateDatabasesAvoidProtectedUserDirectories()` — security check (lines 1125–1147).
8. `writeManifest()` — dump paths and IDs to `manifest.txt`.

**Assertion macros** (lines 1304–1308):
- `try assert(condition, "message")` — throws `E2EFailure` on false.
- `try unwrap(value, "description")` — unwraps optional or throws.
- `try waitUntil(description, condition)` — polls condition up to 5s.

#### `src/E2E/E2EDriverCommands.swift` (headless subcommands)

**Routes** (line 12–33):
- `screenshot --output <png> --main-pid <pid> [--owner-pid <pid> ...]` — ScreenCaptureKit.
- `send-key --pid <pid> --key <name> [--modifiers comma-list]` — CGEvent keyboard.
- `send-click --pid <pid> --x <n> --y <n>` — CGEvent mouse.
- `frontmost` — prints bundle ID of frontmost app.

---

## Existing Behaviors to Preserve (Port-From References)

### Terminal Stack (Chunk D will move these to YAAWRenderHost)

**Location**: `src/Terminal/`

| Component | File | What to Preserve |
|-----------|------|-----------------|
| Backpressure gate | `TerminalBackpressureGate.swift` | 1 MB high water, 256 KB low water; blocks PTY read on overflow |
| PTY process | `AgentTerminalProcess.swift` | `forkpty(3)` call, PID tracking, signal handling |
| Output pump | `AgentTerminalCaptureLog.swift` | 32 KB read chunks, delivery watchdog, circular buffer (~8 MB) |
| Capture log API | `AgentTerminalCaptureLog.swift` | Truncation reporting as event (not silent swallow) |
| Session identity | `TerminalSession.swift` | Resume identity storage, metadata extraction patterns |

**Tests to port** (`src/Tests/YAAWKitTests/`):
- `TerminalBackpressureGateTests.swift` — verify overflow → blocking → unblock.
- `TerminalPasteTests.swift` — linefeeds, binary safety.
- `TerminalDriverTests.swift` — process launch, I/O, exit code capture.

### Protocol & Message Types

**Current** (`src/IsolatedTools/IsolatedToolProtocol.swift`):

| Type | Scope | Use |
|------|-------|-----|
| `IsolatedToolKind` | enum | `.browser`, `.terminal` |
| `IsolatedToolRuntimePhase` | enum | `.idle`, `.launching`, `.ready`, `.loading`, `.failed`, `.crashed`, `.exited` |
| `IsolatedToolEnvelope` | struct | Versioned message: `protocolVersion=2`, `toolKind`, `instanceID`, `type`, `payload: [String:String]` |
| `IsolatedTerminalLaunch` | struct | Launch config: command, environment, workingDirectory, captureLogPath, startupInput, agentCLI, theme, font, rendering flags |
| `IsolatedTerminalRendering` | struct | Hot-reload config (theme/font/ligatures) applied without restarting hosted process |
| `IsolatedToolRuntimeAction` | enum | `.launch`, `.ready`, `.stateChanged`, `.titleChanged`, `.error`, `.exited(code)`, `.crashed(msg)` |
| `IsolatedToolRuntimeReducer` | enum | Pure state machine: reduces (snapshot, action) → snapshot |

**Message type strings** (current hardcoded):
- Down (app → helper): `launchTerminal`, `focus`, `input`, `resize`, `setRenderingConfiguration`, `shutdown`.
- Up (helper → app): `ready`, `frameReady`, `title`, `activity`, `sessionId`, `bell`, `notification`, `pwd`, `commandFinished`, `exit`, `captureTruncated`.

### Existing Test Assertions (Parity Spec)

**Test file**: `src/Tests/YAAWKitTests/AppModelTests.swift` (~3,403 lines)

**Key assertions to preserve**:
- Project creation + selection.
- Thread lifecycle (create, pin, archive, rename, session resumption).
- Agent CLI option catalog refresh.
- Permission preset discovery and launch-option defaults.
- Configured default CLI + permission defaults.
- File index and fuzzy search.
- Browser tab management (HTML/SVG/Markdown files, URLs).
- Theme resolution (fixed theme, system mode light/dark pairing, custom pairings).
- Layout state persistence (sidebar width, right-panel width, swap flag, terminal height).
- Activity/notification updates.
- External-open targeting (project root, thread working directory).

**Tests to port**:
- `PersistenceTests.swift` — migration ladder, WAL, save/load round-trip.
- `FileBrowserTests.swift` — ignore rules, fuzzy ranking, visible-row limiting.
- `AgentCLIAdapterTests.swift` — command construction, option parsing, resume invocation.
- `KeyboardShortcutEventMatchingTests.swift` — keybinding matching.
- `DraculaThemeTests.swift` — color tokens, system appearance tracking.

---

## Rewrite Upgrades (Chunk G Specific)

### 1. Debug Command Channel (Deterministic State Setup)

**Problem solved**: Current E2E uses UI journeys (AppleScript clicks, screenshots) to set up state. Brittle to layout changes.

**Solution**: Add XPC endpoint in main app for debug commands. E2E runner calls these before launching app for visual screenshots.

**Commands**:
- `setSelectedThread(threadID: UUID)` — select without clicking.
- `setRightPanelMode(mode: RightPanelMode)` — switch without Cmd+1/2/3.
- `toggleBottomTerminal()` — expand/collapse without Cmd+J.
- `setLayerWidths(sidebar: Int, rightPanel: Int, terminal: Int)` — resize without dragging.
- `archiveThread(threadID: UUID)` — archive without context menu.

**Implementation**: Codable request/response over XPC during E2E variant.

### 2. AX-Identifier Targeting (vs Coordinate Clicks)

**Migrate script functions** to query AX tree for `AXIdentifier`:

```swift
// Example: Instead of clicking at hardcoded (x,y), find button by ID
on findAndClickButtonByIdentifier(processName, buttonID)
  tell application "System Events"
    tell process processName
      set foundButton to my findByIdentifier(window 1, buttonID)
      if foundButton is not missing value then
        click foundButton
        return true
      end if
    end tell
  end tell
  return false
end findAndClickButtonByIdentifier
```

**Controls to ID**:
- All toolbar buttons: `toggle-sidebar-button`, `toggle-right-panel-button`, `open-settings-button`.
- Settings sidebar rows: `settings-sidebar-general`, `settings-sidebar-agents`, `settings-sidebar-appearance`, `settings-sidebar-keyboard`, `settings-sidebar-config-file`.
- Settings editor: `settings-yaml-editor`, `settings-save-button`.
- Workspace: file browser cells by index or name.

### 3. Per-Helper PID Scoping in Assertions

**Current** (`test-e2e.sh:117–140`):
```bash
allowed_pids=",$(all_helper_pids | tr '\n' ',')"
# AppleScript checks if process PID is in allowed_pids
if allowedPids contains ("," & processPid & ",") then …
```

**Rewrite**: Track helper PIDs by instance prefix (e.g., `project:abc`, `bottom:def`). Assertions target specific helpers.

```bash
helper_pid_for_instance_prefix "project:" # returns PID of project terminal helper
helper_pid_for_instance_prefix "nvim:" # returns PID of nvim helper (if running)
```

### 4. Crash-Isolation Probe

**Test**: `kill -9` one terminal helper; verify app + siblings survive.

**Steps**:
1. Launch app with 2+ threads (project terminal + bottom terminal).
2. Query helper PID for project terminal via `ps`.
3. `kill -9 <pid>`.
4. Assert:
   - App process still running.
   - Frontmost app unchanged.
   - Other helpers still rendering (check window count).
   - Killed pane transitions to "reconnecting" state (UI state).
   - Relaunch helper via XPC or auto-relaunch.
   - Killed pane recovers with cached viewport.

**Assertion functions** (new):
```bash
assert_app_still_running()  # grep app PID; fail if gone
assert_helper_recovered()   # wait for new helper PID with same instance ID
assert_sibling_panes_unchanged() # count helpers before/after kill
```

**Exit code**: nonzero if app crashes or pane does NOT recover.

### 5. Screenshot-Parity Comparison

**Current**: E2E generates screenshots but does not compare to baselines.

**Upgrade**:
- Store reference images in `docs/examples/screenshots/baseline-rewrite-<date>/`.
- E2E runner compares generated screenshots via pixel-diff tool (e.g., `ImageMagick`, `fuzzy-diff`).
- Allow small pixel-diff tolerance (1–2%) for antialiasing/render-timing jitter.
- Fail if visual states diverge beyond threshold.

**Integration**:
```bash
compare_screenshot "$generated" "$baseline" --tolerance 1.5 || {
  echo "Screenshot parity failed: $generated vs $baseline"
  exit 1
}
```

### 6. Performance Benchmark Gates

**Env var**: `RUN_BENCHMARKS=1 swift test -c release --filter YAAWKitBenchmarks`

**Targets** (per master plan):
- **Chunk A (PersistenceActor)**: single-edit save ≤ 2 ms, snapshot save ≤ 30 ms @10k, load ≤ 10 ms.
- **Chunk B (FileIndexActor)**: fuzzy 50k/3-char ≤ 400 ms, cold index 50k ≤ 1.5 s, tree 50k ≤ 61 ms.
- **Chunk D (RenderHost + compositing)**: terminal render lag ≈ 0, idle CPU ≈ 0 (no viewport timers).
- **Chunk E (Stores)**: `activeThreadsForSelectedProject` reads ≤ 0.1 ms @10k.

**CI gate**: Assert all benchmarks pass before merge.

---

## Message Types & Protocol (for Chunk D integration)

### Rewrite: Typed Codable + XPC (vs NDJSON base64)

**Replace**: Current NDJSON `[String:String]` with Codable enums.

```swift
// Down: app → helper
enum HelperIntentMessage: Codable {
  case launch(TerminalLaunchPayload)
  case input(InputPayload)
  case resize(ResizePayload)
  case setRendering(RenderingPayload)
  case shutdown
}

// Up: helper → app
enum HelperEventMessage: Codable {
  case ready
  case frameReady(IOSurfacePayload) // or CAContextID
  case title(String)
  case activity(ActivityPayload)
  case sessionId(String)
  case bell
  case notification(NotificationPayload)
  case pwd(String)
  case commandFinished(String)
  case exited(Int32)
  case captureTruncated(TruncationPayload)
}
```

**Advantages**:
- Binary-safe (no base64 encoding).
- Versioning via enum cases (not hardcoded protocol version).
- Compiler type-checking.
- Native IOSurface/CAContextID passing via `NSSecureCoding`.

### Version Negotiation

**Handshake** (on helper launch):
1. App sends minimum protocol version.
2. Helper responds with list of supported versions.
3. Both agree on highest common version OR fail loudly.

---

## E2E Test Failure Modes & Recovery

### Loud Failures (Fail Fast)

- **Database corruption**: schema migration fails → exit 1 immediately.
- **Missing fixtures**: command doubles, fixture project, config file → exit 1.
- **App launch timeout**: no window appears after 3 attempts → exit 1.
- **Screenshot blocked by privacy prompt**: fail + hint about sandbox setup.
- **AX tree unavailable**: accessibility permission missing → fail with guidance.

### Silent Fallbacks (Acceptable)

- **Focus-steal warnings on CI**: Headless mode on CI runners (no user at screen) → warn only.
- **Old screenshot baseline missing**: skip parity check on first run; generate baseline.
- **Helper window count off by 1**: retry up to 80 times (8s) before failing.

---

## File Paths & Artifacts Structure

```
$ARTIFACT_DIR/
├── bin/                                 # Command doubles
│   ├── codex, claude, opencode, copilot
│   ├── nvim, vim, vi
│   ├── git, lazygit
├── bin-missing-lazygit/                 # Copies for fallback testing
├── config/
│   └── settings.yaml                    # Pinned theme
├── captures/                            # Terminal capture logs (NDJSON)
├── activity/                            # OSC notification logs
├── helper-bin/                          # yaaw-notify + other helpers
├── sandbox-workspace/                   # E2E workspace (~/yaaw analog)
├── fixture-project/                     # Sample project with README, HTML, code
│   ├── README.md
│   ├── index.html
│   ├── diagram.svg
│   ├── .env
│   └── src/App/RootView.swift
├── missing-directory-project/           # For missing-dir recovery tests
├── screenshots/                         # Generated visual-state PNGs
│   ├── launch.png
│   ├── project-creation.png
│   ├── files.png
│   ├── nvim.png
│   ├── git.png
│   ├── missing-directory.png
│   ├── missing-tool.png
│   ├── bottom-terminal.png
│   ├── panel-resize.png
│   ├── panel-collapse.png
│   ├── keyboard-input.png
│   ├── workspace-shortcuts.png
│   ├── isolated-terminal-visibility.png
│   └── settings-editor.png
├── states/                              # SQLite databases
│   ├── focused-behavior.sqlite
│   ├── launch.sqlite
│   ├── files.sqlite
│   ├── nvim.sqlite
│   ├── git.sqlite
│   ├── missing-directory.sqlite
│   ├── missing-tool.sqlite
│   ├── bottom-terminal.sqlite
│   ├── panel-resize.sqlite
│   ├── panel-collapse.sqlite
│   ├── keyboard-input.sqlite
│   ├── workspace-shortcuts.sqlite
│   ├── isolated-terminal-visibility.sqlite
│   ├── settings-editor.sqlite
│   └── focused-behavior.sqlite
├── SCREENSHOT_BLOCKER.md                # Privacy/permissions errors
├── FOCUS_BLOCKER.md                     # Focus-steal violations
└── manifest.txt                         # Paths + thread IDs
```

**Baseline screenshots**: `/Users/BXD5017/github/dopsonbr/yaaw/docs/examples/screenshots/current/`
- `main-workspace-files-terminal.png`
- `main-workspace-browser-preview.png`
- `appearance-settings-theme-fonts.png`
- `agents-settings-launch-defaults.png`

---

## Concurrency Model (Current → Rewrite)

### Current

- **E2E runner**: synchronous Swift, single-threaded (blocks on assertions).
- **App under test**: `DispatchQueue.main.async` hops, generation counters, in-flight booleans.
- **Helper processes**: polled via window-count AppleScript + ps grep.

### Rewrite

- **E2E runner**: async/await on `Task`s, no generation counters.
- **App under test**: `@MainActor @Observable` stores, actor services, `AsyncStream` event feeds.
- **XPC layer**: Codable messages typed at compile time; no string-based payload parsing.
- **Helpers**: XPC faceless (no window), IOSurface or CAContext compositing, per-helper relaunch on crash.

**Swift 6 strict concurrency impact**:
- No `@unchecked Sendable` in E2E code.
- All shared state guarded by actors or `@MainActor`.
- Test assertions do NOT race app mutations (E2E runner is not on main thread during app run).

---

## Exact Constants & Thresholds

| Constant | Value | Use |
|----------|-------|-----|
| Max wait time (window appear) | 15s (150 × 0.1s) | `wait_for_window` retries |
| Max wait time (helper visible) | 8s (80 × 0.1s) | `assert_helper_window_visible_with_prefix` |
| ScreenCaptureKit scale clamp | Display intersection | `captureRect` bounded to display frame |
| CGEvent inter-event sleep | 60ms | Between keyDown/keyUp and mouseDown/mouseUp |
| Keyboard probe TTY loop | ∞ until stdin read | Command doubles simulate blocked I/O |
| Terminal region white-pixel threshold | >45% | Indicates Ghostty render failure |
| Screenshot region analysis | Center 12–78% X, 8–45% Y | Ghostty error text detection region |
| File index cache debounce | 350ms | FSEvents coalesce before re-index |

---

## Acceptance Criteria (DoD for Chunk G)

✓ **No-mock user journey**: Create project → create thread → launch agent → record metadata → rename → archive → relaunch → verify session resumed.

✓ **All per-feature probes pass**:
  - Keyboard input (paste + Enter via `send-key`).
  - Workspace shortcuts (Cmd+J, Cmd+1/2/3, Cmd+[/], Cmd+,, Cmd+Q).
  - Terminal visibility (helpers appear/disappear with bottom-terminal toggle, tab switch).
  - Settings editor (open, edit, save, close).
  - Missing-directory recovery (delete root, re-create, verify relaunch succeeds).
  - Missing-tool fallback (lazygit → git diff, nvim → vim → vi).

✓ **No-focus-steal between every probe** (headless mode).

✓ **Crash isolation**:
  - `kill -9` one helper → app survives, sibling helpers render, killed pane recovers.
  - Exit code 0 on success, 1 if app crashes or recovery fails.

✓ **Screenshot parity**: All visual-state PNGs match baselines within tolerance (after first run establishes baseline).

✓ **Perf gates**: All benchmark targets met (Chunks A/B/D/E).

✓ **No privacy prompts**: E2E fixtures use sandbox paths; test fails with guidance if prompt appears.

---

## Risk Summary

| Risk | Likelihood | Mitigation |
|------|------------|-----------|
| ScreenCaptureKit frame scale drift on resize | Medium | Double/triple-buffer IOSurface ring; frame/contextId handshake; replicate `onPostRender` `contentsScale` correction. |
| AXIdentifier targeting too strict | Medium | Provide both ID-based + coordinate fallback; warn on coordinate use. |
| Crash-isolation probe hangs on relaunch | Medium | Add timeout (5s) on relaunch wait; fail if exceeded. |
| Screenshot baseline first-run setup | Low | Auto-generate baseline on first run if missing; CI check warns, does not fail. |
| Keyboard probe IME / dead-keys | Medium-High | Current minimum bar = ASCII/modifiers/paste/Enter; IME tracked as known limitation. |
| Helper PID re-use race on rapid kill | Low | Use instance IDs + PID pair; instance ID persists across crashes. |

---

## Implementation Checklist

- [ ] Upgrade `E2EDriverCommands.swift` with headless-friendly error messages and retry logic.
- [ ] Port all `test-e2e.sh` AppleScript functions to use AX identifiers.
- [ ] Implement debug XPC command channel in main app (debug variant only).
- [ ] Add per-helper PID tracking in E2E runner.
- [ ] Implement crash-isolation probe (kill -9, verify recovery).
- [ ] Add screenshot-parity comparison (fuzzy diff).
- [ ] Wire performance benchmark gates to `RUN_BENCHMARKS=1 swift test -c release`.
- [ ] Port `AppModelTests.swift` assertions to new store APIs.
- [ ] Port terminal, persistence, filebrowser behavior tests.
- [ ] Document new baseline screenshot location.
- [ ] Verify zero-dependency focus steal in headless mode.

