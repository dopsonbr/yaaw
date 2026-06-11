# YAAW First-Principles Rewrite — Master Plan

> **How to use this doc:** This is the canonical work order for the rewrite. All
> rewrite work happens on a dedicated branch in a separate git worktree and lands
> as a single clean cutover — **no feature flags, no strangler/dual
> implementation.** Chunk 0 is blocking; chunks A–E run in parallel after it; F/G
> follow. As execution proceeds, split per-chunk detail into sibling files
> (`01-spike-and-contracts.md`, `A-persistence.md`, … `Z-cutover.md`) under this
> directory.

---

## Context — why this rewrite

YAAW's engineering culture (PTY backpressure, durable file-index cache, the
SQLite migration ladder, E2E-first testing, local-first privacy) outruns its
skeleton. `architecture-review.html` (2026-06-10) isolates the strain to three
early structural bets that now tax every feature:

1. **`AppModel` god object** — `src/Core/AppModel.swift` is ~3,188 lines, 17
   `@Published` properties spanning eight domains, `@unchecked Sendable`, with
   per-thread *generation counters* and in-flight booleans hand-rolling
   cancellation. `src/App/RootView.swift` (~2,261 lines) observes all of it.
2. **Overlay-window rendering** — every terminal/browser pane is a separate
   `YAAWToolHost` process drawing a borderless floating `NSWindow` over a
   placeholder, steered by a 0.15 s viewport-polling loop with visibility leases,
   z-order repair, and 0.2 s orphan watchdogs. NDJSON `[String:String]` IPC with
   base64 input (~33 % overhead), hardcoded protocol v2.
3. **Poll-everything concurrency** — capture-log polls, session-sync polls,
   viewport timers, watchdogs, all coordinated with `DispatchQueue.main.async`
   hops and generation counters that predate Swift structured concurrency.

The redesign keeps every product invariant and most subsystem internals but
inverts those three bets. The intended outcome: terminals that clip/scroll/layer
natively, near-zero idle CPU, instant (event-pushed) activity updates,
compile-time data-race safety, a UPSERT persistence path, and a codebase where a
contributor can touch one domain without reading 3,000 lines of unrelated state
— **with zero user-facing regressions and unchanged appearance.**

### Locked decisions (from owner)

| Decision | Choice | Consequence for this plan |
|---|---|---|
| Terminal rendering | **Out-of-process render helper, composited into the main view hierarchy** (Option-B family) | The hard requirement is **per-panel crash isolation** (a crash in one agent panel/terminal must never crash the app — see below). The emulator + PTY therefore stay in a separate per-surface helper process. The helper's rendered output is composited inside the *real* pane via the best cross-process layer mechanism (chosen by spike — IOSurface sharing **or** `CAContext`/`CALayerHost` remote-layer hosting), so there are no overlay windows, no viewport polling, no z-order repair. Typed Codable/XPC replaces NDJSON. In-process rendering is **ruled out** because it would let a libghostty crash take down the app. |
| Execution model | **Clean-room rewrite on a separate branch/worktree, single no-flag cutover** | No strangler-fig, no dual implementation, no runtime flags. Parallel chunks are bounded by module against frozen interface contracts; the branch merges once, at parity. |
| Persistence engine | **Harden raw sqlite3** (no GRDB) | `PersistenceActor` over the existing C-API store: UPSERT snapshot save + prepared-statement cache + migration ladder kept (v16 → v17). No new dependency; keep `YAAWStore` protocol + `InMemoryYAAWStore` double. |

### Invariants that MUST NOT change

- **Per-panel crash isolation (hard requirement).** A crash in one agent panel or
  terminal (the libghostty emulator or its child CLI) MUST NOT crash the whole app
  or other panels. This is satisfied by running the emulator + PTY in a separate
  helper process **per surface**, and by treating helper death in the main app as a
  recoverable event — relaunch the helper, replay the cached viewport, and resume
  the thread's bound CLI session — never as an app crash. This invariant is *why*
  in-process rendering is rejected; the implementation mechanism for compositing the
  helper's output is otherwise free to optimize for performance.
- **BYO-CLI** — never a harness; child CLIs (`claude`/`codex`/`opencode`/
  `copilot`/`nvim`/`lazygit`/shells) stay ordinary OS-isolated child processes.
- **Local-first, no telemetry** — SQLite + YAML on device, sanitized notification
  previews, no scrollback retention, no network path. (`docs/requirements/non-functional-requirements.md` MUST clauses.)
- **No focus steal** — app and helpers never raise/steal focus; the headless E2E
  suite asserts this between every probe.
- **Apple Silicon + latest macOS only** — `Package.swift` pins `.macOS(.v26)`.
- **Appearance unchanged** — see "Appearance parity" below (this is the *current*
  liquid-glass / native-titlebar / System-theme look, newer than the review's
  screenshots).

---

## Recent changes since the review that MUST be preserved

The review's figures predate a 2026-06-10/11 flurry. The rewrite reproduces the
**current** behavior, not the review's screenshots. Port-from references:

| Area | What to preserve | Current source |
|---|---|---|
| Window chrome | Native titlebar toolbar (the custom chrome header was removed in `1abc922`), `.windowToolbarStyle(.unifiedCompact)` | `src/App/YAAWApp.swift`, `src/App/RootView.swift` |
| Materials ("liquid glass") | Sidebar behind-window `NSVisualEffectView` (`.sidebar`, `.behindWindow`, `.followsWindowActiveState`) + theme tint overlay; native materials in Settings window; glass sheets; reduce-transparency honored | `src/App/WorkspaceSplitView.swift:215-282`, `src/App/WorkspaceSupportViews.swift`, `src/App/Settings/SettingsWindowView.swift`, `src/App/ThreadChoiceSheet.swift`, `src/App/ChromeMetrics.swift` |
| Theme system | System mode + light/dark pairing pickers; live OS-appearance following; `macos-light`/`macos-dark` + explicit ANSI palettes; Dracula preserved as built-in; default = System | `src/Theme/DraculaTheme.swift`, `src/Persistence/YAAWConfiguration.swift` (`ThemeSettings.resolvedTheme`), `src/App/SystemAppearanceObserver.swift`, `src/App/Settings/AppearanceSettingsView.swift` |
| Fonts | JetBrains Mono vendored + registered + default editor/terminal family; `fonts.ligatures` toggle plumbed to SwiftUI editor *and* terminal (Ghostty `font-feature`) | `src/Fonts/`, `src/App/YAAWApp.swift`, `src/App/Settings/AppearanceSettingsView.swift`, `src/ToolHostSupport/TerminalHostRenderingConfiguration.swift` |
| About/Settings | Build commit (`YAAWBuildCommit`) shown in About + General settings | `src/App/AppBuildInfo.swift`, `src/App/Settings/GeneralSettingsView.swift` |
| Single-instance | SIGTERM older same-bundle-id instances at launch from `YAAWApp.init` (LaunchServices `open` never fires delegate launching callbacks) | `src/App/YAAWApp.swift` `duplicateInstanceSweep`, `script/build_and_run.sh` |
| Settings window | Dedicated sidebar Settings window (moved out of inline panel in `8cf4fbb`) | `src/App/Settings/*` |
| Terminal lifecycle | Apply rendering changes (theme/font/ligatures) to live terminals **without restarting** the agent (hot-reload vs relaunch distinction); drop per-instance caches on explicit shutdown; replay cached viewport on relaunch | `src/App/IsolatedToolRuntime.swift`, `src/IsolatedTools/IsolatedToolProtocol.swift` (`IsolatedTerminalLaunchTransition`) |
| Dependency | `libghostty-spm` pinned `from: "1.2.4"` (upstream deleted the 1.1.4 tag) | `Package.swift`, `Package.resolved` |

Two of the review's three "step 1" perf fixes **already shipped**
(`docs/perf/post-merge-2026-05-21.md`): single-edit save 100 ms → **2 ms**, and
`activeThreadsForSelectedProject` reads 225 ms → **0.1 ms** @10k. The rewrite must
*preserve* these and additionally fix the remaining debt (full-snapshot `save()`
still DELETE+INSERTs all 13 tables — now ~381 ms @10k after the right-panel-tabs
feature — and re-prepares statements per call).

---

## Target architecture

### Process topology (Option B)

```
┌─ YAAW (main process) ─ SwiftUI + AppKit · Swift 6 strict concurrency ─────────┐
│  Feature views (Sidebar / Workspace / RightPanel / Settings)                  │
│  TerminalSurfaceHostView (NSViewRepresentable):                               │
│     wantsLayer view · layer.contents = current shared IOSurface               │
│     forwards key/mouse/focus to helper over XPC (input proxying)              │
│  @MainActor @Observable stores: Workspace · Layout · Activity · Settings ·    │
│     RightPanel                                                                │
│  actor services: PersistenceActor · FileIndexActor · SessionBindingActor ·    │
│     RenderHostClient (one per surface) — AsyncStream event feeds              │
│  AppEnvironment (constructor injection)                                       │
└───────────────┬───────────────────────────────────────────────────────────────┘
                │ NSXPCConnection (typed Codable msgs + IOSurface via NSSecureCoding)
                │ intents down  ·  events + frameReady(IOSurface) up
   ┌────────────┴─────────────┐        (one connection per surface; faceless helper)
   ▼                          ▼
┌─ YAAWRenderHost ─ terminal ┐   ┌─ YAAWRenderHost ─ browser ┐
│ libghostty surface         │   │ WKWebView                 │
│ PTY child (forkpty)        │   │ renders → shared IOSurface │
│ backpressure gate (KEEP)   │   └───────────────────────────┘
│ capture writer · pump      │
│ session/activity parser →  │   No NSWindow shown. Accessory/faceless.
│   XPC events (push)        │   Renders → shared IOSurface ring.
│ renders → IOSurface ring   │
└──────────┬─────────────────┘
           ▼  forkpty (unchanged)
   child CLI: claude / codex / opencode / copilot / nvim / lazygit / zsh
```

**Key property:** terminal *byte* output never crosses the process boundary —
only zero-copy IOSurface frames + small typed event messages do. Keystrokes are
proxied main→helper (small). The entire terminal stack (PTY, backpressure,
capture, emulator) stays in the helper, so a libghostty crash kills one helper
and one pane; the app survives and the thread resumes its bound CLI session on
helper relaunch (CLIs own the real state). **This per-panel crash isolation is
the hard requirement that ruled out in-process rendering.**

> Honest scope note: Option B does **not** collapse N processes into one (that
> was the rejected in-process option). Per-pane helper processes remain, but they
> become headless renderers — no visible window-server window, no per-helper
> event monitors, no overlay coordination. The memory win is modest; the latency,
> correctness, idle-CPU, and complexity wins are large.

### Main-app layers

| Layer | Responsibility | Notes |
|---|---|---|
| UI (SwiftUI feature views) | Declarative; read only the store properties they render | `@Observable` → per-property invalidation; AX identifiers on all controls |
| `@MainActor @Observable` stores | One owner per domain | Workspace, Layout, Activity, Settings, RightPanel (200–500 LOC each) |
| Actor services | I/O off main; `Sendable` boundaries compiler-checked | Persistence, FileIndex, SessionBinding, RenderHostClient |
| OS & disk | forkpty/PTY (in helper), SQLite (WAL), settings.yaml, FSEvents, CLI catalogs | unchanged |

Intents flow **down** as typed `async` calls; results flow **up** as observable
mutations and `AsyncStream` events consumed inside plain `Task`s, where
**cancellation replaces every generation counter** (switch thread → cancel task →
stale result has nowhere to land).

### Module / target layout (new `Package.swift`)

| Target | Kind | Path | Imports | Holds |
|---|---|---|---|---|
| `YAAW` | executable (app) | `src/App` | `YAAWKit`, `YAAWRenderProtocol` | SwiftUI entry, composition, stores, feature views, theme/appearance, settings |
| `YAAWKit` | library | `src/Kit` | `Yams`, `sqlite3`, `YAAWRenderProtocol` | domain model, actors (Persistence/FileIndex/SessionBinding), config, theme tokens, RenderHostClient. **No Ghostty types.** |
| `YAAWRenderProtocol` | library | `src/RenderProtocol` | (pure Swift) | Codable message types + `@objc` XPC protocols + rendering-config DTOs shared by app & helper. **No Ghostty types.** |
| `YAAWRenderHost` | executable (helper) | `src/RenderHost` | `YAAWRenderProtocol`, `GhosttyTerminal` | PTY + emulator + IOSurface ring + XPC service + parsers |
| `YAAWE2E` | executable | `src/E2E` | `YAAWKit`, `YAAWRenderProtocol` | enhanced E2E driver + debug command channel |
| Tests | test targets | `src/Tests/*` | per-target | behavior-first XCTest + benchmarks |

This keeps the **libghostty wrapper boundary narrow** (Ghostty only in
`YAAWRenderHost`; never in `YAAWKit`/`YAAW`) per `docs/standards/dependency/libghostty.md`.
(`YAAWRenderHost` replaces `YAAWToolHost`; the old `YAAWToolHostSupport` rendering
config moves into `YAAWRenderHost` + shared DTOs into `YAAWRenderProtocol`.)

---

## Tightened standards (apply to all new code)

| Control | Current | Rewrite target | Where |
|---|---|---|---|
| Swift 6 concurrency | `@unchecked Sendable` escape hatch | **Strict concurrency = `complete`**, warnings-as-errors in CI; zero `@unchecked Sendable` | `Package.swift` `swiftSettings: [.enableUpcomingFeature/.swiftLanguageMode(.v6)]`, `scripts/lint.sh` |
| `file_length` (swiftlint) | warn 500 / err 3000 | **warn 400 / err 800** | `.swiftlint.yml` |
| `cyclomatic_complexity` | warn 10 / err 20 | **warn 8 / err 12** | `.swiftlint.yml` |
| `function_body_length` | warn 60 / err 350 | **warn 50 / err 120** | `.swiftlint.yml` |
| `type_body_length` | disabled | **re-enabled** (warn 250 / err 400) | `.swiftlint.yml` |
| `swiftlint:disable` directives | 5 file_length + 1 cyclomatic + 2 function_body | **Zero in new code** (the god-objects that needed them are gone) | all new files |
| Public-API docs | not enforced | **`AllPublicDeclarationsHaveDocumentation: true`** for `YAAWKit`/`YAAWRenderProtocol` | `.swift-format` |
| Error handling | `try?` swallowing, silent truncation | Typed errors surfaced to `ActivityStore`; truncation/drift = visible thread state | all chunks |
| Accessibility IDs | partial (settings only) | **Every interactive control** has a stable `accessibilityIdentifier` | Chunk F |

Keep the deliberate `swift-format` ↔ `swiftlint` split (force-unwrap/try/cast,
`trailing_comma`, `opening_brace`, `line_length` stay swiftlint-disabled because
swift-format owns them). `scripts/{build,test,check,lint,format}.sh` keep their
contracts; `scripts/lint.sh` must fail on the new stricter thresholds.

---

## Feature-parity inventory (the zero-regression baseline / DoD spec)

Derived from `docs/requirements/technical-requirements.md` + current behavior.
**Every item below must pass an acceptance test (E2E or ported behavior test) on
the rewrite branch before cutover.**

- **Projects:** create (named, root dir), select, pin (sort-first), manual sort,
  archive/unarchive, expand/collapse, archived-project section; global project
  scoped to `~/yaaw` (configurable). No metadata written into project dirs.
- **Threads:** belong to one project, bound permanently to one CLI family; display
  name from CLI metadata or user name (trimmed); pin, archive, rename; resume the
  same stored session identity on close/reopen; working dir = project root or
  worktree.
- **Agent CLI:** ask-on-new-thread (`ThreadChoiceSheet`); validate against
  `--help`; permission presets discovered + cached + fallback; per-CLI command
  override + permission default + additional args (single source of truth — fix
  the `ToolSettings.agents` vs `launch_options_json` duplication); resume
  invocation per family (`codex resume X`, `claude --resume X`,
  `opencode --session X`, `copilot --resume=X`); never a harness.
- **Terminals:** every thread gets an agent CLI terminal; selected thread gets a
  bottom terminal (collapsed default, `Cmd+J` toggle, resizable); rendering
  hot-reload without restart; lossless PTY backpressure.
- **Right panel:** Files (fuzzy search, ignore rules, capped visible rows, preview
  context), Browser (local HTML/MD/PDF/images + URL nav, isolated WebKit), nvim
  (embedded; fallback vim→vi), Git (lazygit; fallback `git diff`); multi-tab
  state per thread; mode switch + cycling (`Cmd+Shift+[`/`]`); resizable; swap
  with main workspace.
- **Layout:** collapsible sidebar with project nesting + thread list; central
  agent CLI area; resizable right side; resizable bottom terminal; layout/mode/
  panel state remembered across relaunch (and the per-thread UI state — expanded
  folders, selected file, nvim path — now **persisted**, fixing the current
  unpersisted-dictionary asymmetry).
- **Global nav:** `Cmd+[` back / `Cmd+]` forward history; `Cmd+1/2/3` panel tabs;
  `Cmd+,` settings; `Cmd+Q` quit; all keyboard shortcuts configurable with stable
  action ids, `key:""`+`modifiers:[]` = intentionally unbound, duplicate-shortcut
  detection.
- **Activity/notifications:** unread dots/counts, title changes, "needs input"
  system notifications + dock badge; focused selected thread suppresses
  notification; sanitized previews only; **now event-pushed (instant), not polled.**
- **Settings:** YAML at `~/Library/Application Support/YAAW/settings.yaml`
  (override `YAAW_CONFIG_PATH`); in-app editor with validation (never overwrite on
  parse error, never rewrite user YAML on load); forgiving parse (unknown keys
  ignored, missing → defaults + diagnostic); atomic writes; commented template on
  first run; **add `schemaVersion` + migration hook** (currently absent).
- **Resilience:** tolerate missing project dirs / missing tools (the
  `missing-directory` / `missing-tool` states); recover from helper exits; isolated
  sessions; transactional SQLite.

---

## Appearance parity (must be pixel-faithful)

Reproduce the **current** look exactly. Verification = screenshot diff against the
committed baselines in `docs/examples/screenshots/current/` (and the other
state screenshots) via the E2E ScreenCaptureKit path.

Checklist: native unified-compact titlebar toolbar; sidebar behind-window
`.sidebar` material with theme tint + reduce-transparency fallback; glass settings
window + sheets; System theme mode following live OS appearance; `macos-light`/
`macos-dark` palettes; Dracula + other built-ins; JetBrains Mono default editor/
terminal; ligature toggle effect; divider colors from theme tokens; build-commit
string in About/General. Terminal panes must composite seamlessly inside their
panes (no lag/flicker/peek-over-sheet) — the central Option-B win.

---

## CHUNK 0 — Spike, scaffolding, contracts, domain port (BLOCKING, sequential)

**This chunk gates all others. Nothing parallel starts until §0.4 contracts are
frozen and §0.1 go/no-go passes.**

### 0.1 Cross-process compositing spike (mechanism-selection gate)

The fixed point is **per-panel crash isolation**: the emulator + PTY run in a
per-surface helper process, full stop. What the spike decides is *how* to composite
that helper's rendered output inside the real pane with native clipping/layering
and the best performance. Evaluate the two cross-process compositing candidates —
**both preserve crash isolation and eliminate overlay windows + viewport polling** —
and pick by robustness × performance on libghostty-spm 1.2.4:

- **Candidate 1 — Remote layer hosting (`CAContext` + `CALayerHost`).** The helper
  keeps rendering into its existing `CAMetalLayer`, publishes a `CAContext`
  `contextId` over XPC; the main app hosts it with `CALayerHost` inside the pane
  view. *Likely lower integration risk* — it does **not** require touching
  libghostty's render target; the wrapper renders exactly as today. `CAContext`/
  `CALayerHost`/`contextId` are SPI but long-stable (the mechanism WebKit/video use
  for cross-process layer compositing).
- **Candidate 2 — Shared IOSurface.** The helper renders into a shared IOSurface
  (the package's own AppKit code already references an **`IOSurfaceLayer` for
  IOSurface-backed compositing** —
  `.build/checkouts/libghostty-spm/Sources/GhosttyTerminal/Platform/AppKit/AppTerminalView+Lifecycle.swift:176` —
  and `TerminalSurfaceCoordinator` discusses "the underlying IOSurface",
  `…/Surface/TerminalSurfaceCoordinator.swift:52-55`); pass it over `NSXPCConnection`
  (IOSurface is `NSSecureCoding`), `caLayer.contents = surface` in a `wantsLayer`
  host view, double/triple-buffered ring + `frameReady(generation:)` handshake.
  Exposing the per-frame IOSurface may need a thin SPI bridge in `YAAWRenderHost` or
  a narrow patch via the package's existing `Patches/` mechanism (keep Ghostty types
  out of `YAAWKit`/`YAAW`).

Whichever is chosen, the spike must also demonstrate, in a throwaway main↔helper demo:

- **Resize correctness** — main → helper pixel size; helper re-fits grid; enforce
  correct `contentsScale` per backing scale (the coordinator flags a known
  scale-drift "jump" on layout change; replicate its `onPostRender` correction). No
  visible jump on pane drag, sidebar collapse, or theme toggle.
- **Input proxying** — main pane view is first responder; forward
  keyDown/keyUp/flagsChanged + mouse down/drag/up/scroll over XPC; helper injects
  into the surface. **Minimum bar:** ASCII text, modifiers, paste, Enter (matches
  the E2E keyboard probe). **Flagged risk:** IME / marked-text / dead-keys — record
  exact behavior; if not achievable, file an acceptance exception with a tracked
  follow-up (never silently regress).
- **No focus steal** — helper is faceless/accessory with no window; main owns focus
  (E2E `frontmost` check).
- **Crash isolation** — `kill -9` the helper mid-render; the demo app survives, the
  pane goes to a recoverable "reconnecting" state, and relaunch+replay restores it.

**Mechanism choice & fallback (no dead-end):** prefer Candidate 1 if it composites
cleanly at display rate (lowest risk to the wrapper); else Candidate 2. If *neither*
cross-process compositing path is viable on 1.2.4, the **last-resort fallback is an
improved out-of-process overlay window** (event-driven positioning, no 150 ms poll)
— uglier and keeps some overlay edge cases, but still satisfies the crash-isolation
requirement; surface that outcome to the owner with the perf/UX trade-off before
adopting it. Record the decision in
`docs/plans/rewrite/01-spike-and-contracts.md` and a new
`docs/decisions/004-render-helper-compositing.md` ADR.

### 0.2 Worktree, branch, package skeleton, CI

- New git worktree + branch (e.g. `rewrite/option-b`).
- New `Package.swift` with the target layout above; Swift 6 language mode +
  strict-concurrency complete.
- Tightened `.swiftlint.yml` / `.swift-format` (per "Tightened standards").
- Wire `scripts/{build,test,check,lint,format}.sh` + `scripts/test-e2e.sh` +
  `script/build_and_run.sh` to the new targets (rename `YAAWToolHost` →
  `YAAWRenderHost`, helper path `Contents/Helpers/YAAWRenderHost`).

### 0.3 Domain model port (low-risk, mostly verbatim)

Port these value types + their tests largely as-is (they're well-tested,
behavior-level, and not coupled to the god object). They become the shared
vocabulary the parallel chunks build against:

- `src/Projects/*`, `src/Threads/*` (Project, AgentThread, AgentLaunchOptions,
  ThreadActivity), `src/Layout/LayoutState.swift`, `src/RightPanel/*`,
  `src/Theme/DraculaTheme.swift` (verbatim — appearance), `src/Icons/IconSystem.swift`,
  `src/Fonts/BundledFontCatalog.swift`, `src/MarkdownPreview/*`,
  `src/Persistence/YAAWConfiguration.swift` (+ add `schemaVersion`),
  `src/Diagnostics/*`, `src/Core/ExternalOpen.swift`.

### 0.4 Freeze interface contracts (the linchpin for parallelism)

Author the protocol/type seams that let A–G proceed in parallel without merge
conflicts. **These are append-only after freeze; changes require a sync point.**

- `YAAWStore` protocol (load/save/incremental persist ops) — Chunk A implements.
- `FileIndexing` actor protocol (index/search/watch) — Chunk B implements.
- `AgentCLISessionBinding` actor protocol + `CLIManifest` schema — Chunk C.
- `YAAWRenderProtocol`: the `@objc` XPC service + client protocols, the Codable
  message envelopes (launch/resize/input/setRendering/shutdown ↓; frameReady/
  title/activity/sessionId/bell/notification/pwd/commandFinished/exit/
  captureTruncated ↑), and the rendering-config DTO — Chunk D implements both ends.
- Store interfaces (Workspace/Layout/Activity/Settings/RightPanel) + `AppEnvironment`
  init signature — Chunk E implements; Chunk F consumes.

**Acceptance for Chunk 0:** new package builds empty/stub targets green under
strict concurrency; lint passes at tightened thresholds; spike demo runs; domain
tests pass; contracts committed.

---

## Parallel chunks (start after Chunk 0; A–E independent, F/G follow)

Each chunk below is a self-contained work order: scope → port-from → tests →
acceptance + perf gate. Chunks A, B, C, D, E touch disjoint modules and use the
frozen contracts (faking peers where needed), so they run concurrently.

### Chunk A — PersistenceActor (raw sqlite3 hardened)

- **Scope:** Wrap the C-API store in a `PersistenceActor` conforming to `YAAWStore`.
  Replace the full-snapshot DELETE+INSERT `save()` with **UPSERT** (`INSERT … ON
  CONFLICT … DO UPDATE`) + deletion only of rows actually removed; add a
  **prepared-statement cache** keyed by SQL text; remove the interpolated-table-name
  PRAGMA. Keep WAL, the 16-step migration ladder, per-op transactions; add migration
  **v16 → v17** (any indexes needed for `load ORDER BY`; address the right-panel-tabs
  save/load regression). Keep `InMemoryYAAWStore` double with write counters.
- **Port-from:** `src/Persistence/SQLiteYAAWStore.swift` (esp. `save()` ~115-176,
  `prepare()` ~1063-1069), `src/Persistence/InMemoryYAAWStore.swift`.
- **Tests:** port `PersistenceTests.swift` (migrations, WAL, schema evolution —
  behavior-level, survives); add UPSERT-correctness + statement-cache-reuse tests;
  port `SQLitePersistenceBenchmarks`.
- **Acceptance + perf gate:** single-thread edit @10k ≤ **2 ms** (preserve);
  full snapshot save @10k ≤ **30 ms** (was 381 ms); load @10k ≤ **10 ms**;
  migration round-trips green; no metadata in user dirs.

### Chunk B — FileIndexActor

- **Scope:** Move walk/cache/fuzzy/watch behind a `FileIndexActor`. **Keep** the
  durable shared cache (keyed by root + git identity + ignore fingerprint + schema),
  dedup, lazy pruned-subtree expansion, capped visible rows, 350 ms FSEvents
  debounce. **Fix:** replace the full re-sort on subtree merge with sorted
  insertion/merge; **session-cache** the `.git/HEAD` read (was per index call).
  Expose incremental re-rank via `AsyncStream`.
- **Port-from:** `src/FileBrowser/FileIndexCache.swift`,
  `FileBrowserTreeBuilder.swift` (merge ~205-218), `FileBrowserIndex.swift`,
  `FileIndexCacheCoordinator`, directory watcher.
- **Tests:** port `FileBrowserTests.swift` (ignore rules, fuzzy ranking, visible
  rows, large-index — behavior-level); port `FuzzyMatcherBenchmarks`,
  `FileIndexerBenchmarks`, `TreeBuilderBenchmarks`.
- **Acceptance + perf gate:** fuzzy 50k/3-char perceived ≤ **400 ms** (debounced;
  916 ms uncapped baseline); cold index 50k ≤ **1.5 s** (no regression); tree
  builder 50k ≤ **61 ms** (no regression); UI stays responsive during indexing.

### Chunk C — SessionBindingActor + declarative CLI manifests

- **Scope:** Quarantine the heuristics. Replace the four hand-written adapters with
  a `SessionBindingActor` driving a **declarative `CLIManifest` per family**
  (invocation templates, catalog paths, metadata-extraction patterns,
  title-as-session-name policy). Keep the two-tier strategy (catalog scan + live
  capture signal — but the live signal now arrives as an **XPC event** from the
  helper, not a polled capture log). **Loud failure**: format drift surfaces as a
  visible thread state, not silent. Recorded-fixture conformance tests per CLI.
  Fix the lossy path encoding (`/a-b` vs `/a/b`).
- **Port-from:** `src/AgentCLI/AgentCLIAdapter.swift` (adapters ~139-317,
  scraping ~983-1350), `AgentCLIOptionCatalogService.swift`, `AgentCLISessionCatalog`.
- **Tests:** port `AgentCLIAdapterTests.swift` (command construction, option
  parsing, quote/escape, PATH resolution — behavior-level); add fixture-based
  catalog-parse + resume-invocation tests + a "drift → surfaced error" test;
  port `AgentCLIOptionCatalogTests`.
- **Acceptance:** all four families resume correctly from fixtures; unsupported
  permission modes ignored per family; manifest-driven (adding a 5th CLI = a
  manifest + fixtures, no new adapter class).

### Chunk D — RenderHost (helper) + RenderHostClient (XPC + cross-process compositing)

- **Scope (the big one; depends on 0.1 spike):**
  - **Helper (`YAAWRenderHost`):** host PTY + emulator + browser. **Port verbatim
    and relocate** the proven terminal stack: `TerminalBackpressureGate` (1 MB/256
    KB), `AgentTerminalProcess` (forkpty, read loop), `AgentTerminalOutputPump`
    (32 KB chunks, delivery watchdog), `AgentTerminalCaptureWriter` (8 MB circular
    — but surface truncation as an event, not silent), rendering-config builder.
    **One helper process per surface** (this *is* the per-panel crash-isolation
    mechanism; matches current behavior, zero regression). Publish frames via the
    compositing mechanism chosen in §0.1 (`CAContext` `contextId` or shared IOSurface
    ring); push typed events over XPC.
  - **XPC transport:** `NSXPCConnection`, one per surface; typed Codable envelopes;
    handles passed natively (IOSurface / `contextId` are `NSSecureCoding`);
    **binary-safe** (delete base64); versioned with negotiation (replaces hardcoded
    protocol v2). Keep the hot byte path (PTY output) off XPC — only frames + small
    events cross.
  - **Main side (`RenderHostClient` actor + `TerminalSurfaceHostView`):** manage
    XPC lifecycle, expose helper events as `AsyncStream`, host the helper's layer /
    composite its frame inside the pane, forward proxied input. Reproduce the
    **hot-reload vs relaunch** distinction (rendering change → keep process;
    command/env/cwd change → relaunch) and viewport replay on relaunch. **Treat
    helper death (crash or XPC drop) as recoverable**: show a brief "reconnecting"
    pane state, relaunch the helper, replay the cached viewport, resume the bound CLI
    session — the main app never crashes and sibling panels are unaffected.
  - **Delete entirely:** `IsolatedToolViewportReporter` (0.15 s timer), visibility
    leases, orphan watchdogs, z-order repair, NDJSON framing, floating windows,
    per-helper keyboard interception/focus hacks.
- **Port-from:** `src/Terminal/*` (KEEP), `src/ToolHost/main.swift` (rework),
  `src/ToolHostSupport/TerminalHostRenderingConfiguration.swift`,
  `src/App/IsolatedToolRuntime.swift` → `RenderHostClient`, `IsolatedToolProtocol.swift`
  → `YAAWRenderProtocol`.
- **Tests:** port `TerminalDriverTests`, `TerminalBackpressureGateTests`,
  `TerminalPasteTests` (no visible paths), `TerminalHostRenderingConfigurationTests`;
  rewrite `IsolatedToolProtocolTests` → XPC envelope round-trip + version-negotiation
  tests; add compositing-handshake unit tests (frame/`contextId` generation, ring
  buffering).
- **Acceptance + perf gate:** terminal renders in-pane with native clipping/layering
  (no overlay); resize lag ≈ **0** (synchronous with layout); input path has **no
  base64 overhead**; idle CPU ≈ **0** (no viewport timers — assert no polling);
  **per-panel crash isolation verified** — `kill -9` one terminal/agent helper and
  the app + all sibling panels survive, the affected pane recovers (relaunch +
  viewport replay + CLI session resume); no-focus-steal preserved; browser preview
  (HTML/MD/PDF/images + URL) works isolated.

### Chunk E — Stores + AppEnvironment

- **Scope:** Decompose `AppModel` into `@MainActor @Observable` stores —
  **WorkspaceStore** (projects, threads, selection, nav history, session-link
  prompts), **LayoutStore** (widths, collapse, swap), **ActivityStore** (status,
  unread, previews, badges), **SettingsStore** (validated config + hot reload +
  `resolvedTheme` against live `systemAppearanceIsDark`), **RightPanelStore**
  (per-thread modes/tabs + the now-**persisted** per-thread UI state: expanded
  folders, selected file, nvim path). Wire via `AppEnvironment` constructor
  injection. Consume actor `AsyncStream`s in `Task`s; **Task cancellation replaces
  all generation counters and in-flight booleans.**
- **Port-from:** `src/Core/AppModel.swift` (logic, re-homed by domain),
  `src/App/SystemAppearanceObserver.swift` (keep), `src/App/AppBuildInfo.swift` (keep).
- **Tests:** **`AppModelTests.swift` is the behavior parity spec** — re-point its
  ~3,403 lines at the new store APIs (activity → unread → badge/notification,
  focus suppression, idempotent persistence, selection, archive/pin, external-open
  target). Each store gets isolated tests against faked actors.
- **Acceptance:** activity/title updates instant (event-pushed); no timers in idle;
  per-thread UI state survives relaunch; `activeThreadsForSelectedProject` reads
  ≤ 0.1 ms @10k (preserve via O(1) keyed lookups).

### Chunk F — Feature views + appearance (depends on E interfaces; can shell early)

- **Scope:** Thin SwiftUI feature views reading one store each: `SidebarView`,
  `WorkspaceView` (split layout + swap + bottom terminal), `RightPanelView`
  (files/browser/nvim/git tabs + cycling), `SettingsView` + all panes
  (General/Agents/Appearance/Keyboard/Config File), `TerminalSurfaceHostView`
  (from D). **Reproduce current appearance exactly** (see Appearance parity):
  native titlebar toolbar, liquid-glass sidebar/settings/sheets materials + theme
  tint + reduce-transparency fallback, System theme + live following, JetBrains
  Mono + ligatures, build-commit display. Add **AX identifiers to every
  interactive control.**
- **Port-from:** `src/App/RootView.swift`, `WorkspaceSplitView.swift`,
  `WorkspaceSupportViews.swift`, `ChromeMetrics.swift`, `FileBrowserPanelView.swift`,
  `ThreadChoiceSheet.swift`, `src/App/Settings/*`, `src/App/YAAWApp.swift`
  (titlebar, single-instance sweep in `init`, font registration, appearance match).
- **Tests:** port `DraculaThemeTests`, `IconSystemTests`, `MarkdownPreviewTests`,
  `RightPanelModeTests`, `KeyboardShortcutEventMatchingTests`, `ExternalOpenTests`,
  `BundledFontCatalogTests`.
- **Acceptance:** screenshot parity vs `docs/examples/screenshots/current/*`;
  single-instance sweep works from any install path (`YAAWApp.init`, not delegate);
  hot-reload of theme/font applies to live terminals without restart.

### Chunk G — E2E + acceptance harness + perf gates (scaffold early; full run after integration)

- **Scope:** Keep the ScreenCaptureKit composite screenshots, PID-targeted CGEvents,
  no-focus-steal assertions, command doubles, deterministic SQLite/YAML fixtures.
  **Upgrade:** replace coordinate-based clicks with **accessibility-identifier
  targeting** everywhere (the AX tree is now stable); add a **debug command
  channel** (the XPC world makes deterministic state setup trivial) for acceptance
  setup; scope helper assertions to the suite's own pids/helpers; add a
  **crash-isolation probe** (`kill -9` a render helper by pid; assert the app stays
  up, frontmost is unchanged, sibling panels keep rendering, and the killed pane
  recovers); add **screenshot-parity** comparison vs current baselines; wire **perf
  benchmark gates** (run `RUN_BENCHMARKS=1 swift test -c release` and assert the
  targets in Chunks A/B/D/E).
- **Port-from:** `scripts/test-e2e.sh`, `src/E2E/YAAWE2E.swift`,
  `src/E2E/E2EDriverCommands.swift` (`screenshot`/`send-key`/`send-click`/`frontmost`).
- **Acceptance:** the full **no-mock user journey** (create project → thread →
  agent CLI → resume → panel ops → search → archive → relaunch → persist) passes;
  all per-feature probes pass (keyboard input, workspace shortcuts, terminal
  visibility, settings editor, crash-isolation, visual states incl.
  `missing-directory`/`missing-tool`); no-focus-steal between every probe; no
  privacy prompts.

---

## Integration & cutover (sequential, last)

1. Compose the real app via `AppEnvironment` wiring all stores + actors + helper
   client. Resolve integration gaps.
2. Run the **full gate**: `scripts/check.sh` (build+test) + `scripts/lint.sh`
   (tightened) + `scripts/test-e2e.sh` (headless) + benchmark perf gates +
   screenshot parity. Every Feature-parity and Appearance-parity item green.
3. **Clean cutover:** the new `src/` layout fully replaces the old; delete the
   overlay/viewport/NDJSON machinery and the old `AppModel`/`RootView`/`ToolHost`.
   Update `README.md`, `CLAUDE.md`, `docs/` (architecture, ADR-004, refreshed
   perf baseline doc), `AGENTS.md`. Merge the branch in one commit series
   respecting **one-concern-per-commit** and **no Claude attribution trailers**.

### Dependency / parallelization graph

```
Chunk 0 (spike + scaffolding + contracts + domain port)   [BLOCKING]
        │
        ├── A PersistenceActor      ─┐
        ├── B FileIndexActor         │  (independent; run concurrently)
        ├── C SessionBindingActor    │
        ├── D RenderHost + client    │
        └── E Stores + AppEnvironment┘
                    │
                    ├── F Feature views + appearance   (needs E interfaces; shell early vs stubs)
                    └── G E2E/acceptance harness        (scaffold vs contracts; full run needs F + integration)
                                │
                          Integration & cutover         [SEQUENTIAL, LAST]
```

---

## Verification (how to test end-to-end)

- **Build/test/lint:** `scripts/check.sh` then `scripts/lint.sh` (must pass at the
  tightened thresholds with zero new suppressions).
- **Behavior parity:** the ported `AppModelTests`/`PersistenceTests`/
  `FileBrowserTests`/`AgentCLIAdapterTests` are the spec — all green against new APIs.
- **Acceptance / E2E:** `scripts/test-e2e.sh` (headless default) — full no-mock
  journey + all probes (incl. crash-isolation) + screenshot parity + no-focus-steal.
  `script/build_and_run.sh` to exercise the real signed `.app` with cross-process
  compositing (bare `swift run` is insufficient for libghostty + helper).
- **Performance:** `RUN_BENCHMARKS=1 swift test -c release --filter YAAWKitBenchmarks`
  — assert: single-edit save ≤2 ms, snapshot save ≤30 ms @10k, load ≤10 ms @10k,
  activeThreads reads ≤0.1 ms @10k, fuzzy 50k/3-char ≤400 ms, tree 50k ≤61 ms,
  cold index 50k ≤1.5 s. Record results in a new `docs/perf/baseline-rewrite-<date>.md`.
- **Manual real-app smoke:** `script/build_and_run.sh` then verify resize has no
  terminal lag/flicker, terminals don't peek over sheets, Mission Control/Spaces/
  screenshots behave natively, idle CPU ≈ 0 with several panes open, and a forced
  helper kill (`kill -9 <helper-pid>`) loses only that one pane — the app and all
  sibling panels survive and the killed pane recovers (relaunch + resume).

## Definition of Done

- [ ] Compositing-mechanism spike resolved (Candidate 1/2 chosen, or fallback with
      owner sign-off); ADR-004 recorded.
- [ ] Every Feature-parity inventory item passes an acceptance/E2E or ported test.
- [ ] Appearance parity: screenshot diffs vs `docs/examples/screenshots/current/*` pass.
- [ ] All performance gates met or beaten; new baseline doc committed.
- [ ] Swift 6 strict concurrency `complete`, zero `@unchecked Sendable`, zero new
      `swiftlint:disable`; tightened lint green.
- [ ] Overlay/viewport/NDJSON machinery deleted; Ghostty types confined to
      `YAAWRenderHost`; **per-panel crash isolation verified** — killing one panel/
      terminal helper leaves the app and sibling panels running and the killed pane
      recovers (relaunch + viewport replay + CLI session resume).
- [ ] No telemetry/network path added; no metadata in user project dirs; no-focus-steal holds.
- [ ] Docs (README, CLAUDE.md, architecture, perf, AGENTS) updated; branch merged
      via clean cutover, one concern per commit, no Claude attribution trailers.

## Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Chosen cross-process compositing path not viable on libghostty-spm 1.2.4 | **Medium — primary risk** | §0.1 evaluates **two** candidates (`CAContext`/`CALayerHost` remote-layer hosting, which needs no change to the wrapper's render target, **and** shared IOSurface); last-resort fallback = event-driven overlay window (still crash-isolated). Not a dead-end — crash isolation holds regardless |
| IME / marked-text correctness under input proxying | Medium | Spike minimum bar = ASCII/modifiers/paste/Enter; full IME tracked; record any exception explicitly rather than silently regress |
| Compositing tearing / scale-drift on resize | Medium | Double/triple-buffer (IOSurface ring) or hosted-layer sync + frame/`contextId` handshake; replicate coordinator `onPostRender` `contentsScale` correction |
| Render helper crashes leak (zombie processes, FD/IOSurface handle leaks) | Medium | `RenderHostClient` owns helper lifecycle; XPC invalidation handler reaps + relaunches; per-surface teardown frees handles; covered by the crash-isolation E2E probe |
| Behavior drift during decomposition | Medium | Ported behavior tests + full E2E are the continuous parity net; `AppModelTests` is the spec |
| Per-CLI session-catalog format drift | Low-Medium | Declarative manifests + recorded-fixture conformance tests + loud surfaced failure |
| Clean cutover concentrates risk (no strangler) | Medium | Full gate (tests + E2E + screenshot parity + perf) must be green before merge; worktree keeps `main` releasable meanwhile |
