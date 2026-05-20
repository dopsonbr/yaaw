# Plan 03: Project And Thread Workflows

## Summary

Build the first real user workflows on top of persisted state: create project, create thread (with the `codex` / `claude` choice prompt), select thread, and archive thread. This plan owns the user-facing CLI choice and persists `agent_cli` per thread. The actual CLI launch, session identity capture, and resume behavior land in [Plan 07](07-agent-cli-session-binding.md).

## Requirements

- Technical Requirements: Projects, Threads, Storage, Agent CLI Scope, Acceptance Criteria.
- Non-Functional Requirements: Usability, Reliability, Data Integrity.
- Testing Requirements: E2E Scope, Inputs And Outputs.

## Implementation

- Add project creation from a local directory with user-provided display name.
- Add the built-in `global` project scoped to the user's home directory. Treat global threads as normal threads per [Decision 003](../decisions/003-global-project-thread-behavior.md).
- Add a new-thread workflow that asks the user whether to invoke `codex` or `claude` before the thread is created. The prompt MUST be a modal sheet so the workflow cannot complete without an explicit choice.
- Persist the chosen `agent_cli` on the thread record. Add a SQLite migration (version `2`) that introduces `agent_cli` as a non-null column on `threads` with a check constraint accepting only `codex` or `claude`.
- Existing threads in the database (if any from earlier test runs) MUST be migrated forward; for the MVP this means failing fast with a clear error if migration encounters a thread with no chosen CLI, since no thread can exist without one in normal flow.
- Set the thread working directory to the project root by default. Allow callers to pass a different worktree path so [Plan 07](07-agent-cli-session-binding.md) and later plans can support per-worktree threads.
- Thread display name MUST default to a placeholder (e.g. `New <codex|claude> thread`) at creation time. Plan 07 replaces the placeholder with the CLI-reported session name.
- Threads MUST NOT be allowed to switch from `codex` to `claude` or vice versa after creation. Enforce this at the public API boundary.
- Add selection behavior for projects and threads through Plan 01's selection state.
- Add archive behavior that removes archived threads from the primary active list while keeping them available through archive state. Archive MUST preserve `agent_cli` so [Plan 07](07-agent-cli-session-binding.md) can resume the bound session later.
- Persist every workflow through the SQLite store from [Plan 02](02-sqlite-persistence.md).

## Tests

- Unit tests for project creation defaults and validation.
- Unit tests for thread creation rejecting a missing `agent_cli`.
- Unit tests for the CLI-choice locked-after-create invariant.
- Unit tests for archive filtering and persisted archive state, including that archived threads keep `agent_cli`.
- Integration-style tests that reload the store and verify workflow state survives. Tests MUST run against a real temporary SQLite file.

## Acceptance Criteria

- A user can create a project from a local directory.
- The built-in `global` project exists and points at the user's home directory.
- A user can create multiple threads under one project.
- New thread creation prompts the user for `codex` or `claude` and cannot complete without an explicit choice.
- The chosen `agent_cli` is persisted on the thread record and survives relaunch.
- A thread's `agent_cli` cannot be changed after creation; the API rejects the change.
- A user can switch between threads.
- A user can archive a thread and the archived thread leaves the active list while retaining its `agent_cli`.
- Project/thread workflow state survives app relaunch through SQLite.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with project/thread workflow coverage.
