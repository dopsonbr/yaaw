# Deferred Issues

This file tracks review findings that are real but intentionally belong to a later numbered implementation plan.

## Triage Rules

- Fix critical issues before committing the current plan. Critical means data loss, crashes, broken build/test gates, security/privacy risk, or a user-visible regression in behavior owned by the current plan.
- Fix same-plan correctness bugs before committing the current plan unless they are explicitly low priority and do not block the current plan's acceptance criteria.
- Defer low-priority findings when they are polish, refactor-only, or explicitly owned by a later plan in `implementation-order.md`.
- Do not re-run external review indefinitely for the same low-priority or later-plan finding. Record it here with the owning plan, evidence, and intended acceptance gate.
- Every deferred issue MUST name the plan that will resolve it and the test or smoke check that will close it.
- A deferred issue is not closed until the owning plan implements it and the normal build/test/review/retro gate passes.

## Open Items

### D-001: Persist Non-Default Thread CLI Metadata

- Source: Plan 02 Codex review on 2026-05-20.
- Finding: `AgentThread.agentCLI`, `sessionIdentity`, and `canonicalSessionName` are public model fields, but SQLite migration v1 intentionally stores only Plan 02's basic thread columns. A synthetic non-default `.claude` thread reloads as `.codex` with nil session metadata.
- Triage: Deferred because Plan 02 explicitly must not introduce columns without producers. Plan 03 owns `agent_cli`; Plan 07 owns CLI session identity and canonical session name.
- Owning plans: Plan 03 for `agent_cli`; Plan 07 for `sessionIdentity` and `canonicalSessionName`.
- Closure test: A real temporary SQLite reload test verifies a `.claude` thread survives relaunch in Plan 03, and a deterministic CLI session identity/name survives relaunch in Plan 07.
