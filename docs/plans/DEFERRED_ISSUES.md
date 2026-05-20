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

No deferred issues yet.
