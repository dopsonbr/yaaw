# Implementation Retros

This file captures one retro per implementation plan in `docs/plans/implementation-order.md`.

## Plan 01: App State And Navigation Spine

- Date: 2026-05-20
- Scope shipped: explicit project/thread selection, navigation history, archive/unarchive actions, `AgentCLIKind`, per-thread right-panel modes, command routing, Codex Run action bootstrap, and generated bundle output ignored.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 14 tests; `./script/build_and_run.sh --verify` passed.
- External review: `codex review --uncommitted` found and then cleared issues for optional CLI state, right-panel mode fallback, cross-project thread lists, generated `dist/`, and same-project reselection.
- Screenshot/UX evidence: Computer Use inspected the running `AgentIDE` window and confirmed the Dracula shell rendered with visible project, thread, right-panel mode controls, and collapsed global terminal. Shell `screencapture` was blocked by local display capture permissions (`could not create image from display`), so no filesystem screenshot artifact was created for this plan.
- UX findings: Initial layout is readable, but still scaffold-like and fixed-width; deeper polish belongs to Plans 04, 10, and 11.
- Lesson learned: External review needs a triage policy so critical current-plan issues are fixed immediately while low-priority or later-plan issues are tracked instead of creating a review loop.
- Follow-up: Plan 02 should persist exactly the Plan 01 state through SQLite and JSON config without adding later-plan schema.

## Plan 02: SQLite Persistence

- Date: 2026-05-20
- Scope shipped: SQLite store at an app-owned Application Support path, injectable test database paths, migration v1 for Plan 01 state, transactional snapshot saves, JSON configuration defaults with Dracula and ignore rules, and SQLite-backed app startup.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 21 tests; `./script/build_and_run.sh --verify` passed.
- External review: `codex review --uncommitted` found current-plan issues for atomic migration, global-terminal expansion persistence, and invalid UUID crash handling; those were fixed. A later-plan CLI metadata persistence finding was recorded as D-001 in `docs/plans/DEFERRED_ISSUES.md`.
- Screenshot/UX evidence: `docs/examples/screenshots/plan-02/sqlite-persistence.png`; Computer Use confirmed the running `AgentIDE` window renders the SQLite-backed Dracula scaffold with project/thread selection, Files mode, and collapsed global terminal.
- UX findings: No new visual regression from moving startup to SQLite. The UI still needs the real layout shell, resize/collapse behavior, and polished controls in later plans.
- Lesson learned: A model field existing in Plan 01 does not mean every field belongs in SQLite v1; schema scope should follow the producer plan, with explicit deferrals for reviewer-visible future gaps.
- Follow-up: Plan 03 must add migration v2 for `agent_cli` and prove `.claude` thread selection survives relaunch.

## Plan 03: Project And Thread Workflows

- Date: 2026-05-20
- Scope shipped: create-project API and sheet, explicit Codex/Claude thread creation flow, archive-selected workflow, immutable per-thread CLI choice, SQLite migration v2 for `agent_cli`, and startup handling that surfaces unsafe migration failures instead of silently falling back to in-memory state.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 29 tests; `./script/build_and_run.sh --verify` passed.
- External review: Two `codex review --uncommitted` passes found current-plan migration risks. The first rejected defaulting legacy v1 threads to Codex; the second rejected hiding that failure behind the app's in-memory fallback. Both were fixed before commit.
- Screenshot/UX evidence: `docs/examples/screenshots/plan-03/project-thread-workflows.png`; Computer Use verified the running app opens the New Thread sheet and creates a selected Claude thread.
- UX findings: The workflow is usable and visible, but project creation still uses a raw path field and archive is a plain sidebar text action. Those are polish items for the native shell and final UX passes.
- Lesson learned: Explicit user choice is a data invariant; migration and startup behavior must protect it even when that means stopping the app with a clear error.
- Follow-up: Plan 04 should replace the fixed scaffold with the native Dracula layout shell and start moving these controls into their long-term locations.

## Plan 04: Layout Shell

- Date: 2026-05-20
- Scope shipped: layout state model, SQLite migration v3 for persisted panel geometry, collapsible/resizable sidebar and right panel, persisted global terminal height/expanded state, visible archive disclosure, and layout menu commands.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 33 tests; `./script/build_and_run.sh --verify` passed.
- External review: `codex review --uncommitted` found no blocking correctness, persistence, or UI-state regression. The reviewer's SwiftPM command hit its own sandbox cache issue, but local gates passed in the normal user-cache environment.
- Screenshot/UX evidence: `docs/examples/screenshots/plan-04/layout-shell.png`; Computer Use verified the archive disclosure, resize handles, collapse/expand controls, Files/nvim/Git mode controls, and collapsed global terminal in the running app.
- UX findings: The shell is now usable for the next terminal lifecycle work. It remains visually dense and scaffold-like in places, so final toolbar, spacing, and tool affordance polish should stay in Plans 10 and 11.
- Lesson learned: Progress screenshots must be captured or cropped to the app window before committing; full-desktop captures are a privacy risk and should be treated as critical artifact hygiene.
- Follow-up: Plan 05 should add terminal lifecycle protocols while keeping terminal contents placeholder-backed until libghostty integration.

## Plan 05: Terminal Abstraction

- Date: 2026-05-20
- Scope shipped: runtime-only terminal roles, launch requests, session records, lifecycle events, placeholder session manager, and app-model request resolution for project, global, `nvim`, and `lazygit` terminals.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 37 tests; `./script/build_and_run.sh --verify` passed.
- External review: The first `codex review --uncommitted` pass found current-plan lifecycle bugs where view-only `onAppear` could miss thread changes. Those were fixed with thread-scoped terminal placeholder identities. The follow-up review found no discrete correctness issues.
- Screenshot/UX evidence: `docs/examples/screenshots/plan-05/terminal-abstraction.png`; Computer Use verified the running app switches the right panel into `nvim` and Git terminal placeholder modes without layout regression.
- UX findings: Placeholder-backed terminal cards make the future terminal slots clear, but the app still needs real embedded terminal focus, input, and scroll behavior in Plan 06 before it feels like a daily-use IDE.
- Lesson learned: Runtime abstractions still need UI lifecycle ownership; the app must react to selected-thread changes, not only initial surface appearance.
- Follow-up: Plan 06 should put libghostty behind this boundary without changing the public app-state API.

## Plan 06: libghostty Integration

- Date: 2026-05-20
- Scope shipped: Ghostty-backed SwiftUI/AppKit terminal bridge through `libghostty-spm`, retained per-role terminal views for project/global/`nvim`/`lazygit`, initial right-panel tool command delivery, Dracula terminal colors, clickable global terminal expansion, wider right panel defaults, optional upstream bootstrap script, and libghostty consumption documentation.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 37 tests; `./script/build_and_run.sh --verify` passed; `bash -n scripts/bootstrap-libghostty.sh` passed.
- External review: `codex review --uncommitted` found retained-surface, Bash portability, and attach-delay command-delivery issues; all were fixed before commit. Later upstream distribution hardening is tracked as D-002 in `docs/plans/DEFERRED_ISSUES.md`.
- Screenshot/UX evidence: `docs/examples/screenshots/plan-06/libghostty-terminal-surface.png`; Computer Use verified the running app shows project, right-panel, and global Ghostty surfaces, that the global terminal expands from a real button, and that the Git terminal remains alive when switching Files -> Git.
- UX findings: The global terminal control initially looked clickable but was inert, so it now uses an accessible button. The original right panel width clipped terminal content, so Plan 06 widened its default and minimum sizes. The sample project is not always a Git repo, so `lazygit` may prompt to initialize one; that is expected fixture behavior, not a terminal bug.
- Lesson learned: Loading symbols directly from `/Applications/Ghostty.app` is not a safe embedding strategy even when exports exist; use a narrow package/framework boundary, and retain the AppKit terminal view itself rather than only weak surface state.
- Follow-up: Plan 07 should bind Codex/Claude agent sessions through the terminal adapter without persisting live PTY state. Plan 11 should revisit the libghostty distribution path if upstream publishes a stable full-surface package or distribution requires a first-party vendored artifact.

## Plan 07: Agent CLI Session Binding

- Date: 2026-05-20
- Scope shipped: `AgentCLIAdapter` boundary for Codex and Claude, deterministic launch/resume commands, app-owned `/usr/bin/script` transcript capture for interactive first launches, SQLite migration v4 for `session_identity` and `canonical_session_name`, thread display-name updates from parsed CLI metadata, active terminal command stability after metadata capture, terminal-title fallback handling, and appended-byte capture polling.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 51 tests; `./script/build_and_run.sh --verify` passed.
- External review: Multiple `codex review --uncommitted` passes found current-plan issues for first-launch identity capture, active terminal rebuilds, transient title overwrites, pre-metadata title preservation, whole-log polling, Claude resume syntax, and capture-offset reset. Those were fixed and covered by tests before commit; review was not repeated after the final green gate to avoid a review loop.
- Screenshot/UX evidence: `docs/examples/screenshots/plan-07/agent-cli-session-binding.png`; Computer Use verified the running app shows a real Claude Code project terminal prompt, right-panel Git terminal, and global terminal together.
- UX findings: Real CLI trust prompts are raw terminal UX and may block until the user chooses, which is acceptable for the terminal-backed session model. The local persisted smoke state had duplicate manually-created Claude thread names, but that is fixture state rather than a code regression.
- Lesson learned: CLI session metadata needs a TTY-preserving capture path; metadata persistence must not mutate the command backing an already-running terminal. Current CLI resume syntax should be verified from installed tool help, not inferred.
- Follow-up: Plan 08 should add file indexing and fuzzy search without blocking terminal responsiveness. Plan 10 should use deterministic CLI fixture binaries for screenshot-producing behavior tests.

## Plan 08: File Browser And Fuzzy Search

- Date: 2026-05-20
- Scope shipped: read-only background file indexing, hidden-file visibility, JSON-config ignore rules, deterministic fuzzy ranking, selected-thread Files state, refresh/search UI, SQLite migration v5 for per-thread file-index metadata, and metadata reload/persistence.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 59 tests; `./script/build_and_run.sh --verify` passed.
- External review: `codex review --uncommitted` found same-plan issues for stale overlapping refresh results and directory-only ignore semantics. Both were fixed with request IDs and directory-only ignore matching, then covered by tests.
- Screenshot/UX evidence: `docs/examples/screenshots/plan-08/file-browser-fuzzy-search.png`; Computer Use verified the repo project Files panel indexed 151 items, skipped 3 ignored directories, showed hidden folders, and returned `RETRO.md` first for the `retro` query.
- UX findings: The first home-directory index exposed that broad roots can take long enough to make a later repo selection feel stuck when indexing is serial. The indexer now runs requests concurrently and ignores stale same-thread results. The right panel is usable, but long paths still depend on truncation and will benefit from Plan 11 polish.
- Lesson learned: Nonblocking indexing is not only a background-thread concern; request ordering matters once users can switch projects or refresh while older scans are still running.
- Follow-up: Plan 09 should wire file selection into `nvim <relative-path>` using the selected entry without persisting live terminal state. Plan 11 should consider extra safe defaults or progress detail for very broad home-directory roots.

## Plan 09: Right Panel Tool Flows

- Date: 2026-05-20
- Scope shipped: file rows now launch `nvim <relative-path>` in the selected thread's right panel, per-thread selected file paths stay runtime-only, `nvim` and `lazygit` resolve through the injected executable resolver with raw-command fallback for missing tools, same-role request changes replace active terminal sessions, and repeated same-file opens force a fresh `nvim` launch.
- Verification: `./scripts/build.sh` passed; `./scripts/test.sh` passed with 64 tests; `./script/build_and_run.sh --verify` passed.
- External review: `codex review --uncommitted` found current-plan issues for same-file `nvim` relaunches and replacement lifecycle events reporting an active record as terminated. Both were fixed with a runtime relaunch token and terminated-state lifecycle records, then covered by regression tests.
- Screenshot/UX evidence: `docs/examples/screenshots/plan-09/right-panel-tool-flows.png`; Computer Use verified `RETRO.md` opened in the embedded right-panel `nvim` terminal and Git mode launched `lazygit` against the repo.
- UX findings: The right-panel tool flow is functional and fast enough for daily use. `lazygit` remains dense in a narrow right panel, so final polish should revisit default widths, truncation, and tool affordances.
- Lesson learned: Terminal role identity is not enough for tool flows; a command-equivalent user action can still need a fresh surface launch after the prior terminal program exits.
- Follow-up: Plan 10 should automate Files -> `nvim`, Git -> `lazygit`, global terminal, missing-tool handling, and screenshot capture through deterministic fixtures.
