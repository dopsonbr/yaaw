# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

YAAW (Yet Another Agent Wrapper) is a native macOS app that wraps the user's own
installed agent CLIs (`codex`, `claude`, `opencode`, `copilot`) in embedded
`libghostty` terminals, adding project/thread organization, session resume, a
right tool panel (Files, Browser, `nvim`, `lazygit`), and a bottom terminal.
It is **not** an agent harness: it launches and resumes the user's CLIs, it does
not orchestrate, proxy, or reimplement them. There is no telemetry; all state is
local. Preserve this boundary unless requirements under `docs/requirements/`
change.

Scope is **Apple Silicon + latest macOS only**. `Package.swift` pins
`.macOS(.v26)`; older systems fail to build by design.

## Commands

```sh
scripts/build.sh        # swift build (auto-resets stale SwiftPM workspace state)
scripts/test.sh         # swift test
scripts/check.sh        # build + test
scripts/lint.sh         # swift-format lint (--strict) + swiftlint, both must pass
scripts/format.sh       # swift-format --in-place (run before committing)
scripts/run.sh          # swift run YAAW (bare binary; no app bundle)
scripts/test-e2e.sh     # full E2E suite (see below)
```

Run a single test: `swift test --filter YAAWKitTests.FileBrowserTests` (or
`.../testSpecificMethod`). Tests use **XCTest** (`final class … : XCTestCase`).

### Running the real app

`scripts/run.sh` (`swift run`) launches a bare binary, which is insufficient for
the `libghostty` terminals and the bundled framework. To exercise the actual
product, build a signed `.app` bundle into `dist/`:

```sh
script/build_and_run.sh                 # build dist/YAAW.app and `open -n` it
script/build_and_run.sh --variant=e2e   # build dist/YAAW-E2E.app (bundle id .E2E)
YAAW_BUILD_CONFIGURATION=release script/build_and_run.sh
```

This script stamps the bundle with the current git short SHA (`YAAWBuildCommit`
in Info.plist, surfaced in About/Settings), packages `YAAWRenderHost` as an XPC
service bundle (`Contents/XPCServices/dev.dopsonbr.YAAW.RenderHost.xpc`), and
ad-hoc codesigns. libghostty is **statically linked** (`libghostty.a` from
`GhosttyKit.xcframework`), so the helper is self-contained and no Ghostty
framework is bundled. It SIGTERMs any already-running instance from *any* install
path first — see "Single-instance" below.

## Architecture

> **This branch (`rewrite/option-b`) is the first-principles rewrite.** It is
> complete and verified headlessly (builds debug+release, 327 tests, tightened
> lint, the app launches); the live-GUI compositing/appearance/E2E run is the
> remaining owner finish-line. See `docs/plans/rewrite/STATUS.md` for the full
> picture and `docs/plans/rewrite/DECISIONS-LOG.md` / `DEFERRED-ISSUES.md`.

SwiftUI owns layout; AppKit is used for terminal embedding, focus, split views,
and window control. Five SwiftPM targets (see `Package.swift`):

- **`YAAWRenderProtocol`** (`src/RenderProtocol/`) — the pure-Swift XPC seam:
  typed Codable message envelopes (`RenderMessage`/`RenderEvent`), the `@objc`
  XPC service/client protocols, version negotiation, and the
  `IsolatedTerminalLaunch`/`Rendering`/`Transition` value types. **No Ghostty.**
- **`YAAWKit`** (`src/Kit/`) — the library holding nearly all logic: domain
  model (`Projects`/`Threads`/`Layout`/`RightPanel`/`Theme`/`Icons`/`Fonts`/
  `MarkdownPreview`/`Diagnostics`/`Core`), actor services (`Persistence`
  SQLiteYAAWStore, `FileBrowser` FileIndexActor, `AgentCLI` SessionBindingActor),
  the proven `Terminal` stack, and the five `@MainActor @Observable` stores +
  `AppEnvironment` (`Stores/`). Links `sqlite3`. **No Ghostty.**
- **`YAAW`** (`src/App/`) — thin SwiftUI feature views (one store each),
  `RenderHostClient` (the XPC client + `RenderSurfaceManaging` impl),
  `TerminalSurfaceHostView` (CALayerHost compositing), `YAAWApp`, `Settings/`.
- **`YAAWRenderHost`** (`src/RenderHost/`) — the headless per-surface render
  helper (the only Ghostty-linking target; see below).
- **`YAAWE2E`** (`src/E2E/`) — the headless E2E driver/runner. (`YAAWKitPerf`,
  `src/Perf/`, is the release perf-gate executable.)

### Central model

`AppModel` is **gone**, decomposed into five `@MainActor @Observable` stores
(`src/Kit/Stores/`): **WorkspaceStore** (projects/threads/selection/nav/
session-linking), **LayoutStore**, **ActivityStore** (status/unread/notifications/
file-browser), **SettingsStore** (config/appearance/theme), **RightPanelStore**
(modes/tabs/per-thread UI state). They are wired by `AppEnvironment` +
`AppStores.make()` (constructor injection) and talk to actor services over
`async`/`AsyncStream`; **Task cancellation replaces the old generation counters**.
A **project** is a named local directory; a **thread** is one agent CLI session
bound permanently to one CLI family, resumed from stored session identity.

### Render helper (the key non-obvious piece)

Each terminal/browser surface runs in a **separate `YAAWRenderHost` process** (per
surface), not in-process — this is the **per-panel crash-isolation hard
requirement**: a libghostty crash kills one helper, not the app. The app
(`src/App/RenderHostClient.swift`) and helper communicate over **`NSXPCConnection`
with typed Codable envelopes** (`YAAWRenderProtocol`) — no NDJSON, no base64. The
helper renders into a `CAMetalLayer` wrapped in a **`CAContext`** and publishes its
`contextID`; the app composites it natively in-pane via **`CALayerHost`** (ADR-004),
so there are **no overlay windows, no viewport polling, no z-order repair**. Helper
death is recoverable (relaunch + viewport replay + CLI session resume). Ghostty
types are confined to `YAAWRenderHost`.

### Persistence & config

Durable state is SQLite behind the **`SQLiteYAAWStore` actor** (`src/Kit/Persistence/`,
`InMemoryYAAWStore` actor for tests) — UPSERT save + prepared-statement cache,
migration ladder at **v18**, WAL. User settings are YAML (Yams) at
`~/Library/Application Support/YAAW/settings.yaml` (now with a `schemaVersion` +
migration hook). File-browser index uses a shared SQLite cache keyed by directory
+ git identity, behind the **`FileIndexActor`**.

### Single-instance behavior (subtle)

`YAAWApp.duplicateInstanceSweep` SIGTERMs older instances of the same bundle id
at launch. It lives in `YAAWApp.init`, **not** the app delegate, because
LaunchServices (`open`) launches do not deliver the delegate's launching
callbacks — **put startup work in `YAAWApp.init`, not delegate callbacks.**

## E2E suite (`scripts/test-e2e.sh`)

- **Headless by default** (`--headed` for the legacy focus-driven path). The app
  and its helpers must never steal focus or raise windows; the suite asserts
  no-focus-steal between probes.
- The Swift runner verifies durable state transitions directly; launched-app
  "states" verify real rendering via screenshots.
- Screenshots use **ScreenCaptureKit composites** scoped to the app's own
  windows (occlusion-proof), and key/mouse events are posted straight to the
  target **pid** — see `src/E2E/E2EDriverCommands.swift` (`screenshot`,
  `send-key`, `send-click`, `frontmost` subcommands).
- Scope assertions to the suite's own pid/helpers; a stray live `YAAW.app` from
  another install path will contaminate window-helper assertions otherwise.

## Conventions

- **Lint is two tools** (`swift-format` + `swiftlint`) with deliberately
  reconciled configs (`.swift-format`, `.swiftlint.yml`). Force-unwrap/try/cast
  and `trailing_comma`/`opening_brace`/`line_length` are disabled in swiftlint
  because swift-format owns them. Always run `scripts/format.sh` before
  committing. **Tightened in the rewrite:** `file_length` error 800;
  `cyclomatic_complexity` error 12; `function_body_length` error 120;
  `type_body_length` error 400. `.swift-format-public` enforces public-API docs
  on `YAAWKit`/`YAAWRenderProtocol` (run via `YAAW_LINT_DOCS=1 scripts/lint.sh`).
  Swift 6 strict concurrency `complete` on every target; zero `@unchecked
  Sendable` except documented proven primitives.
- **Tests are behavior-first.** Prefer E2E over internals tests; do not assert
  private functions or framework internals (`docs/requirements/testing-requirements.md`,
  `docs/standards/testing/e2e.md`).
- **Docs layout** (`AGENTS.md`): keep root files short/navigational; durable
  product docs in `docs/`, plans in `docs/plans/`, requirements in
  `docs/requirements/` (use MUST/SHOULD/MAY), user workflows in
  `docs/user-guide/`, standards in `docs/standards/`. Never write app metadata
  into user project directories.
- Dracula is the historical baseline theme; default `theme.active` is `system`
  pairing `macos-light`/`macos-dark`. Preserve Dracula as a built-in.
