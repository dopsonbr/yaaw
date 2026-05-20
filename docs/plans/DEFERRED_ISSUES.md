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

### D-002: Replace Interim libghostty Swift Package If Upstream Publishes A Stable Full-Surface Package

- Source: Plan 06 upstream research on 2026-05-20.
- Finding: Official Ghostty sources expose the full macOS embedding API in `include/ghostty.h`, but the official SwiftPM example currently targets `libghostty-vt` terminal state rather than the full AppKit surface. Plan 06 therefore uses `Lakr233/libghostty-spm` 1.1.4, which ships a `GhosttyKit.xcframework` binary target and AppKit/SwiftUI surface wrappers.
- Triage: Low-priority dependency hardening. Current app surfaces are backed by `libghostty` and build/test/verify pass, but the final release should prefer an official upstream package or directly vendored full Ghostty XCFramework if available.
- Owning plan: Plan 11.
- Closure test: Plan 11 verifies the selected Ghostty artifact is signed/packaged correctly, release verification does not depend on `/Applications/Ghostty.app`, and the documented distribution path matches `Package.swift`.

## Resolved Items

### D-001: Persist Non-Default Thread CLI Metadata

- Source: Plan 02 Codex review on 2026-05-20.
- Finding: `AgentThread.agentCLI`, `sessionIdentity`, and `canonicalSessionName` are public model fields, but SQLite migration v1 intentionally stores only Plan 02's basic thread columns. A synthetic non-default `.claude` thread reloaded as `.codex` with nil session metadata.
- Resolution: Plan 03 added SQLite migration v2 for explicit `agent_cli`. Plan 07 added SQLite migration v4 for `session_identity` and `canonical_session_name`, deterministic CLI session capture, and resume command generation.
- Closure test: `testAgentCLIMetadataPersistsThroughSQLiteReload`, `testLaunchCaptureAndResumeCommandUsesDeterministicCLIDouble`, and the normal Plan 07 build/test/verify gate passed.
