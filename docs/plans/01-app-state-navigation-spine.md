# Plan 01: App State And Navigation Spine

## Summary

Create the stable app-state layer that later persistence, UI, and terminal work will use. This plan covers public models, selection state, navigation history, archive flags, right-panel mode state, and command routing.

## Requirements

- Technical Requirements: Projects, Threads, Right Tool Panel, Global Navigation, Agent Scope.
- Non-Functional Requirements: Maintainability, Usability, Testability.
- Testing Requirements: Unit Test Policy, Inputs And Outputs.

## Implementation

- Define public, behavior-oriented models for projects, threads, selected project/thread, archived thread state, right-panel mode, and global-terminal visibility.
- Extend the existing scaffold models. `AgentThread` MUST gain `agentCLI: AgentCLIKind` (`codex` | `claude`) so Plan 03 can populate it. `AgentThread` MAY include optional `sessionIdentity` / `canonicalSessionName` fields that remain nil until Plan 07; the scaffold need not produce them yet.
- Add an app state store boundary that can be backed by in-memory state now and SQLite in the next plan.
- Replace the placeholder `selectedThread` accessor (currently "first non-archived thread") with explicit selection state on the model.
- Add command actions for `Cmd+J`, `Cmd+[`, `Cmd+]`, `Cmd+Shift+[`, and `Cmd+Shift+]` at the public action-routing level.
- Keep right-panel mode scoped to the selected thread in the model, even before persistence exists.
- Keep SwiftUI views thin: views render state and forward user intent to the app-state layer.

## Global Navigation History

Global back/forward navigation needs a concrete history model so `Cmd+[` and `Cmd+]` behave predictably:

- An entry MUST capture `(projectID, threadID?)`. A nil thread id represents project-only selection (e.g. an empty project).
- A new selection MUST push onto the history stack only when it differs from the current entry. Repeated selection of the same entry MUST NOT grow the stack.
- `Cmd+[` MUST move the cursor backward through history without dropping entries. `Cmd+]` MUST move forward.
- Making a new selection while not at the tip MUST truncate the forward portion of the history. This matches browser behavior.
- History depth MUST be bounded (recommended 50 entries). Oldest entries are evicted from the bottom when the bound is exceeded.
- Archiving a thread MUST NOT remove that thread's entries from history; selecting an archived entry via navigation routes through the existing archive resume path.
- Deleting a project (not in MVP scope) would invalidate entries; until that exists, project removal is not a concern.

## Tests

- Unit tests for selecting projects and threads.
- Unit tests for archiving and unarchiving thread state.
- Unit tests for right-panel mode cycling.
- Unit tests for global back/forward navigation history covering: push-on-change-only, forward-truncation on new selection while not at tip, bounded depth eviction, and archived-entry retention.
- Unit tests for `Cmd+J` global-terminal toggle action routing.

## Acceptance Criteria

- The app can represent at least one project, multiple threads, active selection, archived threads, right-panel mode, and global-terminal visibility in `YAAWKit`.
- `AgentThread` exposes `agentCLI` so later plans can populate `codex` / `claude` selection without further model migrations.
- Public action APIs exist for navigation, right-panel cycling, archive state, and global-terminal toggle.
- Global back/forward navigation has a defined push/forward-truncate/bounded-depth model with passing tests.
- Right-panel mode is stored per thread in memory.
- SwiftUI app commands call the public action APIs instead of mutating scattered view state.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with behavior-focused tests for the state and command routing.
