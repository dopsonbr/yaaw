# Plan 11: Polish And Hardening

## Summary

Harden the MVP after the main workflow exists. This plan covers missing directories, missing external tools, accessibility, diagnostics, startup performance, and nonblocking indexing.

## Requirements

- Technical Requirements: External Tools, Theme, Acceptance Criteria.
- Non-Functional Requirements: Performance, Responsiveness, Reliability, Security And Privacy, Accessibility, Observability, Packaging.
- Testing Requirements: E2E Scope, Screenshot Requirements.

## Implementation

- Add clear app-level states for missing project directories.
- Preserve raw terminal errors for missing or failing `nvim` and `lazygit`.
- Add accessibility labels for sidebar items, right-panel mode controls, terminal regions, and resize/collapse controls.
- Add local diagnostic logs for app lifecycle, project/thread changes, terminal launch failures, indexing failures, and SQLite errors.
- Avoid logging sensitive terminal content.
- Ensure file indexing does not block launch, terminal input, panel resizing, or navigation.
- Review Dracula contrast and visual consistency across all app surfaces.

## Tests

- Unit tests for missing-directory state transitions.
- Unit tests for diagnostic event payloads that avoid terminal content.
- E2E tests for missing directory, missing tool output, and persisted recovery state.
- Screenshot checks for major visual states.

## Acceptance Criteria

- Missing project directories show a clear app-level state without crashing.
- Missing `nvim` and `lazygit` errors remain visible as raw terminal output.
- Primary interactive controls expose meaningful accessibility labels.
- Local logs cover lifecycle, state changes, terminal failures, indexing failures, and SQLite errors without capturing sensitive terminal content.
- App launch remains responsive before file indexing completes.
- Terminal input and panel resizing remain responsive during indexing.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes.
- `scripts/test-e2e.sh` passes or documents any environment-only blocker.
