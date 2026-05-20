# Plan 10: Behavior E2E Suite

## Summary

Add the script-backed E2E test harness required to validate the app through real user workflows and screenshots.

## Requirements

- Testing Requirements: E2E Scope, Full User Journey Test, Screenshot Requirements, Mocking Policy, Artifacts.
- Non-Functional Requirements: Testability, Reliability.
- Standards: E2E Standard.

## Implementation

- Add `scripts/test-e2e.sh` as the canonical E2E entrypoint.
- Build and launch a real app process from SwiftPM.
- Create real temporary project directories and deterministic fixture files.
- Use a real isolated SQLite database location for E2E runs.
- Capture screenshots on failure and at key visual states.
- Keep mocks limited to OS dialogs that cannot be controlled reliably.
- Add one full user journey test plus smaller focused E2E tests where practical.

## Tests

- Full user journey: launch, create project, create thread, choose `codex` or `claude` at the prompt, verify the thread display name updates to the CLI-reported session name, use the terminal, close and reopen the thread and verify CLI session resume, search files, open `nvim`, open Git mode, toggle global terminal, resize/collapse panels, archive thread, quit, relaunch, verify persisted state including the resumed CLI session identity.
- Focused E2E tests for project creation, `codex` thread creation, `claude` thread creation, the CLI-choice prompt, thread naming from the CLI session, thread resume after relaunch, right-panel modes, global terminal, file search, persistence, and missing `lazygit` behavior.
- Use deterministic `codex` and `claude` command doubles (fixture binaries on `PATH` from [Plan 07](07-agent-cli-session-binding.md)) so session names and resume identities can be asserted without depending on real CLI behavior.

## Acceptance Criteria

- `scripts/test-e2e.sh` exists and runs the E2E suite from the command line.
- The suite launches a real app build.
- The full user journey uses real temporary files, a real SQLite database, and the deterministic CLI command doubles from Plan 07.
- The full user journey asserts: CLI choice prompt appears, thread display name matches the CLI-reported session name, reopening a thread resumes the stored CLI session identity.
- E2E failures produce screenshots in a deterministic artifact directory.
- Screenshots are captured for launch, project creation, Files mode, `nvim` mode, Git mode, global terminal expanded, and panel resize/collapse states.
- E2E tests do not mock storage, file browser behavior, right-panel mode switching, or the full user journey.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes.
- `scripts/test-e2e.sh` passes or documents any environment-only blocker.
