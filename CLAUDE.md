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
in Info.plist, surfaced in About/Settings), copies the vendored Ghostty
framework from `Vendor/`, and ad-hoc codesigns. It SIGTERMs any already-running
instance from *any* install path first — see "Single-instance" below.

## Architecture

SwiftUI owns layout; AppKit is used for terminal embedding, focus, split views,
and window control. Four SwiftPM products (see `Package.swift`):

- **`YAAWKit`** (`src/`, minus the app/host/test/e2e dirs) — the library holding
  nearly all logic: `Core`, `Projects`, `Threads`, `AgentCLI`, `Terminal`,
  `FileBrowser`, `Persistence`, `Theme`, `Layout`, `RightPanel`, `IsolatedTools`,
  `Diagnostics`, `MarkdownPreview`, `Icons`, `Fonts`. Links `sqlite3`.
- **`YAAW`** (`src/App/`) — thin SwiftUI entrypoint and root composition
  (`YAAWApp.swift`, `RootView.swift`, `Settings/`).
- **`YAAWToolHost`** (`src/ToolHost/`, `src/ToolHostSupport/`) — the isolated
  tool helper executable (see below).
- **`YAAWE2E`** (`src/E2E/`) — the headless E2E driver/runner.

### Central model

`AppModel` (`src/Core/AppModel.swift`) is the single large `ObservableObject`
(`@unchecked Sendable`) holding all `@Published` app state: projects, threads,
selection, per-thread right-panel modes/states, layout, file-browser state,
configuration. A **project** is a named local directory; a **thread** is one
agent CLI session bound permanently to one CLI family. Closing/reopening a thread
resumes the same bound session via stored session identity (`AgentCLI/`,
`Threads/`).

### Isolated tool helper (the key non-obvious piece)

Each Browser preview and each `nvim`/`lazygit`/terminal surface runs in a
**separate `YAAWToolHost` child process**, not in-process. The parent
(`src/App/IsolatedToolRuntime.swift`) and helper communicate over stdin/stdout
using JSON `IsolatedToolEnvelope` messages (`src/IsolatedTools/`,
**protocol version 2**; parent and child are always built in lockstep). The
helper runs with `NSApp.setActivationPolicy(.accessory)` and **floats its window
over the parent window** rather than rendering into a shared view — this is why
overlapping/stale instances cause visual garble, and why the app is strict about
single-instance behavior. Keep terminal, persistence, indexing, theme, and UI
layout concerns separated.

### Persistence & config

Durable state is SQLite (`Persistence/SQLiteYAAWStore.swift`, in-memory variant
for tests). User settings are YAML (Yams) at
`~/Library/Application Support/YAAW/settings.yaml`, edited via the in-app Config
File settings pane. File-browser index uses a shared SQLite cache keyed by
directory + git identity (`FileBrowser/FileIndexCache.swift`).

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
  committing. `file_length` hard error is 3000 lines; `cyclomatic_complexity`
  error 20; `function_body_length` error 350.
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
