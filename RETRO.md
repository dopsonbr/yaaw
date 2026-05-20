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
