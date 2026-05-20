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
