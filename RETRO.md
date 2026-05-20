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
