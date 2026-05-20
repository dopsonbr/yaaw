# Plan 05: Terminal Abstraction

## Summary

Define the terminal lifecycle interface before binding to `libghostty`. This keeps project, global, `nvim`, and `lazygit` terminals consistent and testable.

## Requirements

- Technical Requirements: Terminal Requirements, Threads, Agent Scope, External Tools.
- Non-Functional Requirements: Maintainability, Reliability, Testability.
- Standards: libghostty Standard, AppKit Standard.

## Implementation

- Create terminal session and terminal surface protocols under `src/Terminal/`.
- Represent project, global, `nvim`, and `lazygit` terminal roles explicitly.
- Scope project terminal sessions to active threads while the app process is running.
- Keep live terminal process state in memory only.
- Add a placeholder terminal implementation for tests and UI development.
- Add lifecycle events for create, activate, terminate, and surface launch failure.

## Tests

- Unit tests verify one project terminal session per active thread.
- Unit tests verify global terminal session is app-wide.
- Unit tests verify `nvim` and `lazygit` terminal roles use selected-thread working directory metadata.
- Unit tests verify terminal state is runtime-only and not persisted as live process state.

## Acceptance Criteria

- A public terminal abstraction exists for project, global, `nvim`, and `lazygit` surfaces.
- Project terminal sessions are scoped by thread id.
- Global terminal session is shared app-wide.
- Right-panel terminal descriptors resolve against the selected thread.
- Persistence stores terminal metadata/layout only, not live process state.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with terminal abstraction coverage.
