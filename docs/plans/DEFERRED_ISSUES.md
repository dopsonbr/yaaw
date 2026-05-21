# Deferred Issues

This file tracks review findings that are real but intentionally belong to a later numbered implementation plan.

## Triage Rules

- Fix critical issues before committing the current plan. Critical means data loss, crashes, broken build/test gates, security/privacy risk, or a user-visible regression in behavior owned by the current plan.
- Fix same-plan correctness bugs before committing the current plan unless they are explicitly low priority and do not block the current plan's acceptance criteria.
- Defer low-priority findings when they are polish, refactor-only, or explicitly owned by a later plan in `implementation-order.md`.
- Treat external review as a gate, not a loop: after critical and same-plan correctness issues are resolved, record remaining low-priority or later-plan findings here and continue to the next numbered plan.
- Do not re-run external review indefinitely for the same low-priority or later-plan finding. Record it here with the owning plan, evidence, and intended acceptance gate.
- Every deferred issue MUST name the plan that will resolve it and the test or smoke check that will close it.
- A deferred issue is not closed until the owning plan implements it and the normal build/test/review/retro gate passes.

## Open Items

## Rejected Review Findings

### R-001: Legacy AgentIDE Application Support Migration

- Source: Multi-CLI/image-paste Codex review on 2026-05-20.
- Finding: Reviewer requested a one-time migration from `~/Library/Application Support/AgentIDE/AgentIDE.sqlite` into `~/Library/Application Support/YAAW/YAAW.sqlite`.
- Decision: Rejected for this change because product direction explicitly does not preserve compatibility with the old `AgentIDE` prefix. YAAW uses app-owned `YAAW` paths and `YAAW_*` environment variables only.
- Reconsideration gate: Reopen only if product requirements explicitly ask for legacy AgentIDE data migration.

## Resolved Items

### D-002: Replace Interim libghostty Swift Package If Upstream Publishes A Stable Full-Surface Package

- Source: Plan 06 upstream research on 2026-05-20.
- Finding: Official Ghostty sources expose the full macOS embedding API in `include/ghostty.h`, but current official public docs still emphasize `libghostty-vt` as the available split and do not publish a stable official full-surface SwiftUI/AppKit package.
- Resolution: Plan 11 keeps `Lakr233/libghostty-spm` 1.1.4 behind the narrow `src/App/GhosttyTerminalSurfaceView.swift` bridge, documents the current distribution path in `docs/standards/dependency/libghostty.md`, and hardens `script/build_and_run.sh --verify` to ad-hoc sign and verify the staged `.app`.
- Closure test: `./script/build_and_run.sh --verify` verifies the app bundle signature and rejects `/Applications/Ghostty.app` binary links; `otool -L dist/YAAW.app/Contents/MacOS/YAAW` showed no dependency on `/Applications/Ghostty.app`.

### D-001: Persist Non-Default Thread CLI Metadata

- Source: Plan 02 Codex review on 2026-05-20.
- Finding: `AgentThread.agentCLI`, `sessionIdentity`, and `canonicalSessionName` are public model fields, but SQLite migration v1 intentionally stores only Plan 02's basic thread columns. A synthetic non-default `.claude` thread reloaded as `.codex` with nil session metadata.
- Resolution: Plan 03 added SQLite migration v2 for explicit `agent_cli`. Plan 07 added SQLite migration v4 for `session_identity` and `canonical_session_name`, deterministic CLI session capture, and resume command generation.
- Closure test: `testAgentCLIMetadataPersistsThroughSQLiteReload`, `testLaunchCaptureAndResumeCommandUsesDeterministicCLIDouble`, and the normal Plan 07 build/test/verify gate passed.
