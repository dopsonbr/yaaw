# Implementation Order

This index defines the recommended build order after the SwiftPM Hello World scaffold. The sequence builds durable state, persistence, and workflows before terminal embedding so later integrations land behind stable app boundaries.

## Scaffold Prelude

The initial commit established a SwiftPM scaffold with placeholder models for projects, threads, right-panel mode, and a Hello World layout. Some Plan 01 behavior already exists in code: `RightPanelMode.next`/`previous`, `AppModel.cycleRightPanelMode*`, `AppModel.toggleGlobalTerminal`, and a `Cmd+J` command. Plan 01 finishes the missing pieces (full selection state, archive APIs, global navigation history, and `Cmd+[` / `Cmd+]` / `Cmd+Shift+[` / `Cmd+Shift+]` routing) and updates the existing scaffold accordingly.

## Ordered Plans

1. [App State And Navigation Spine](01-app-state-navigation-spine.md)
2. [SQLite Persistence](02-sqlite-persistence.md)
3. [Project And Thread Workflows](03-project-thread-workflows.md)
4. [Layout Shell](04-layout-shell.md)
5. [Terminal Abstraction](05-terminal-abstraction.md)
6. [libghostty Integration](06-libghostty-integration.md)
7. [Agent CLI Session Binding](07-agent-cli-session-binding.md)
8. [File Browser And Fuzzy Search](08-file-browser-fuzzy-search.md)
9. [Right Panel Tool Flows](09-right-panel-tool-flows.md)
10. [Behavior E2E Suite](10-behavior-e2e-suite.md)
11. [Polish And Hardening](11-polish-hardening.md)

## Sequencing Rule

Implement plans in order unless a later plan is explicitly split into a research-only spike. Each plan MUST leave `scripts/build.sh` and `scripts/test.sh` passing before the next plan starts.

## Review Triage Rule

External review findings MUST be handled as follows to avoid review loops:

- Fix critical issues before committing the current plan. Critical includes data loss, crashes, broken build/test gates, security/privacy risk, or a user-visible regression in behavior owned by the current plan.
- Fix correctness bugs that belong to the current plan unless they are explicitly low priority and do not block the current plan's acceptance criteria.
- If a finding is valid but low priority or belongs to a later numbered plan, record it in [Deferred Issues](DEFERRED_ISSUES.md) instead of repeatedly re-reviewing the same incomplete future behavior.
- The deferred entry MUST name the owning plan, the current evidence, and the acceptance test or smoke check that will close it.
- Do not advance past a plan with untriaged review findings.

## Persistence Strategy

Plan 02 establishes the SQLite store and migrates only what Plan 01 produces (projects, threads, archive state, last selection, right-panel mode per thread) plus the YAML settings boundary. Later plans extend the schema through additive migrations as they produce new durable state:

- Plan 03 adds `agent_cli` per thread.
- Plan 04 adds panel sizes and collapsed states.
- Plan 07 adds CLI session identity and canonical session name per thread.
- Plan 08 adds file-index metadata.

This avoids persisting columns that have no producer yet.

## Testing Strategy

Plans 02–09 ship unit and integration tests inside `scripts/test.sh`. Plan 10 introduces the script-backed E2E harness (`scripts/test-e2e.sh`) and retroactively adds behavior coverage for the workflows shipped in earlier plans. Acceptance criteria in earlier plans that name user-visible behavior (panel collapse, mode cycling, opening a file in `nvim`, launching `lazygit`, CLI session resume) are validated by unit and integration tests plus a documented manual smoke procedure until Plan 10 lands the harness.

Plans that include manual smoke acceptance criteria (Plan 06, Plan 07) document the smoke procedure in the plan body so manual verification stays consistent until the E2E suite covers them.

## Open Decisions

Three product/architecture questions remain open and do not block any plan from starting. Each has a recommended default the plans assume until the decision is finalized:

- [001 — Archived Thread Scrollback Retention](../decisions/001-archived-thread-scrollback.md)
- [002 — Project Metadata Location](../decisions/002-project-metadata-location.md)
- [003 — Global Project Thread Behavior](../decisions/003-global-project-thread-behavior.md)

## Requirement References

- [Technical Requirements](../requirements/technical-requirements.md)
- [Non-Functional Requirements](../requirements/non-functional-requirements.md)
- [Testing Requirements](../requirements/testing-requirements.md)
- [Swift Standard](../standards/lang/swift.md)
- [SwiftUI Standard](../standards/framework/swiftui.md)
- [AppKit Standard](../standards/framework/appkit.md)
- [libghostty Standard](../standards/dependency/libghostty.md)
- [E2E Standard](../standards/testing/e2e.md)
