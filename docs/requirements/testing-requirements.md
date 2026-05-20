# Testing Requirements

This document defines testing requirements for the first version of the native macOS Agent IDE.

The testing strategy is behavior-first. Tests should validate what a user can do and what the app visibly produces. Tests should avoid asserting private functions, implementation details, or framework-specific internals.

Requirements use:

- **MUST:** required for the first shippable version.
- **SHOULD:** expected unless cost or platform constraints make it impractical.
- **MAY:** allowed but not required.

## Testing Principles

- Tests MUST focus on user-visible behavior, inputs, and outputs.
- Tests MUST NOT depend on private functions or internal implementation details.
- Tests MUST avoid over-mocking the app.
- End-to-end tests MUST be the primary confidence layer.
- Unit tests MAY exist, but they MUST validate high-value public behavior or deterministic input/output logic.
- Screenshot capture MUST be available for E2E failures and key visual states.

## E2E Scope

E2E tests MUST cover the primary user workflows:

- Launch the app.
- Create a project from a local directory.
- Create a `codex` thread under a project.
- Create a `claude` thread under a project.
- Verify new thread creation asks which agent CLI to invoke.
- Verify the visible thread name matches the selected CLI session's reported name, title, or id.
- Switch between project threads.
- Use the agent CLI session terminal.
- Close and reopen a thread and verify the stored agent CLI session identity is resumed.
- Toggle the global terminal with `Cmd+J`.
- Resize major panels.
- Collapse and expand the sidebar.
- Collapse and expand the right tool panel.
- Use the right panel in Files mode.
- Search files with fuzzy matching.
- Open a file in `nvim` mode.
- Open Git mode and launch `lazygit`.
- Cycle right-panel modes with `Cmd+Shift+[` and `Cmd+Shift+]`.
- Navigate globally with `Cmd+[` and `Cmd+]`.
- Archive a thread.
- Relaunch the app and verify persisted project/thread/layout metadata.

## Full User Journey Test

The suite MUST include one high-level no-mock E2E test that navigates through the app like a real user.

This test MUST:

1. Launch a real app build.
2. Create or use a real temporary project directory.
3. Initialize real files in that directory.
4. Initialize a real Git repository when Git behavior is tested.
5. Create a project in the app.
6. Create a thread and choose `codex` when prompted.
7. Verify the thread name matches the Codex session's reported name, title, or id.
8. Use the agent CLI session terminal.
9. Close and reopen the thread.
10. Verify reopening resumes the stored Codex session identity.
11. Open the right panel in Files mode.
12. Search for a file.
13. Open that file in `nvim`.
14. Switch to Git mode.
15. Launch `lazygit`.
16. Toggle the global terminal.
17. Resize or collapse panels.
18. Archive the thread.
19. Quit and relaunch the app.
20. Verify durable app state is restored where required.

The full user journey test MUST NOT mock app storage, terminal surfaces, file browser behavior, or right-panel mode switching.

The full user journey test MAY skip `lazygit` assertions when `lazygit` is not installed, but it MUST verify that the app surfaces the raw missing-tool error.

The full user journey test MAY use test-safe `codex` and `claude` command doubles or controlled CLI fixtures so session names and resume identities can be asserted deterministically.

## Inputs And Outputs

Tests MUST be written around explicit inputs and observable outputs.

Examples of valid inputs:

- User clicks.
- Keyboard shortcuts.
- Text typed into fields.
- Agent CLI choice, either `codex` or `claude`.
- Controlled agent CLI session names and session identities.
- Directory selections.
- Files created in a temporary project.
- Git repository state.
- Terminal commands entered by the test.

Examples of valid outputs:

- Visible project names.
- Visible thread names.
- Visible selected agent CLI labels.
- Visible agent CLI session names.
- Persisted agent CLI session identities.
- Visible active right-panel mode.
- Visible terminal output.
- Visible file search results.
- Visible `nvim` state.
- Visible `lazygit` or raw missing-tool error output.
- Persisted project/thread records after relaunch.
- Screenshots captured by the test harness.

Tests SHOULD assert stable user-visible labels, state, and outputs rather than view hierarchy names or private object identifiers.

## Screenshot Requirements

The E2E test harness MUST be able to capture screenshots.

Screenshots MUST be captured:

- On every E2E failure.
- After the app launches.
- After project creation.
- In Files mode.
- In `nvim` mode.
- In Git mode.
- With the global terminal expanded.
- After panel resize or collapse behavior.

Screenshots SHOULD be written to a deterministic test artifact directory.

Screenshot filenames SHOULD include:

- Test name.
- Step name.
- Timestamp or stable step number.

Screenshot tests MUST NOT replace behavioral assertions. They are supporting evidence for debugging and review.

## Normal E2E Tests

The suite SHOULD include smaller E2E tests in addition to the full user journey.

Recommended tests:

| Test | Required behavior |
| --- | --- |
| Project creation | A selected directory becomes a named project in the sidebar. |
| Codex thread creation | A new Codex thread appears under the selected project and gets an agent CLI session terminal. |
| Claude thread creation | A new Claude thread appears under the selected project and gets an agent CLI session terminal. |
| CLI choice prompt | Creating a thread asks whether to invoke `codex` or `claude`. |
| Thread naming | The visible thread name matches the bound CLI session name, title, or id. |
| Thread resume | Closing and reopening a thread resumes the stored CLI session identity. |
| Thread switching | Switching threads changes the active agent CLI session terminal and right-panel context. |
| Right-panel modes | Files, `nvim`, and Git modes can be selected by icon/tab. |
| Right-panel shortcuts | `Cmd+Shift+[` and `Cmd+Shift+]` cycle right-panel modes. |
| Global navigation | `Cmd+[` and `Cmd+]` move through app navigation history. |
| Global terminal | `Cmd+J` expands and collapses the global terminal. |
| File search | Hidden files are visible and fuzzy search returns expected matches. |
| nvim open | Opening a file launches `nvim` in the right panel. |
| lazygit open | Git mode launches `lazygit` or shows the raw missing-tool error. |
| Persistence | Project/thread/agent CLI session/layout metadata survive app relaunch. |

## Mocking Policy

E2E tests MUST use a real app process.

E2E tests MUST use real local directories and files.

E2E tests SHOULD use real SQLite storage in an isolated test location.

E2E tests SHOULD use real embedded terminal surfaces when practical.

Mocks MAY be used only for:

- OS dialogs that cannot be controlled reliably in automation.
- Time or clock values.
- Isolated error injection that cannot be produced safely through real inputs.

Mocks MUST NOT replace the full user journey test.

## Unit Test Policy

Unit tests are allowed when they are high value and input/output based.

Good unit test targets:

- Fuzzy file matching.
- Ignore-rule evaluation.
- Path normalization.
- JSON config parsing and validation.
- SQLite migration behavior against a real temporary database.
- Public project/thread storage APIs.
- Agent CLI session metadata persistence.
- Agent CLI resume command construction at a public boundary.
- Keyboard shortcut command routing at the public action level.

Poor unit test targets:

- Private helper functions.
- SwiftUI view internals.
- AppKit object wiring.
- Terminal wrapper internals.
- Exact implementation classes.
- Re-testing framework behavior.

Unit tests MUST use public APIs or stable module boundaries.

Unit tests MUST assert outputs for given inputs.

Unit tests SHOULD use real temporary files and databases where that improves confidence without making the test brittle.

## Test Data

Tests SHOULD create temporary project directories with deterministic content.

Recommended fixture structure:

```text
sample-project/
  README.md
  .env.example
  package.json
  src/
    auth.ts
    index.ts
  docs/
    guide.md
```

Git-mode tests SHOULD initialize a real Git repository and create at least one modified file so `lazygit` has visible state.

Tests MUST clean up temporary files after completion unless artifacts are intentionally retained for failure investigation.

## Artifacts

E2E runs MUST produce artifacts for failed tests.

Artifacts SHOULD include:

- Screenshots.
- App logs.
- Test runner logs.
- SQLite database copy when safe.
- JSON config copy when safe.

Artifacts MUST NOT include sensitive terminal output unless explicitly enabled for a local debugging run.

## Acceptance Criteria

- The app has an E2E harness that can launch the native macOS app.
- The E2E harness can interact with the app through clicks, typing, and keyboard shortcuts.
- The E2E harness can capture screenshots.
- The suite includes one full no-mock user journey test.
- The suite includes focused E2E tests for project/thread creation, agent CLI selection, session naming, session resume, panel behavior, file search, `nvim`, `lazygit`, shortcuts, and persistence.
- Persistence tests verify agent kind and CLI session identity survive relaunch.
- Tests verify visible inputs and outputs instead of private implementation details.
- Unit tests are limited to high-value public behavior or deterministic input/output logic.
- Test artifacts are saved for failure review.
