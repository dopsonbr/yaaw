# Plan 07: Agent CLI Session Binding

## Summary

Bind every thread to exactly one user-provided `codex` or `claude` CLI session inside the embedded terminal. This plan owns YAAW's thin launch/resume adapter boundary: launching the chosen CLI in the thread working directory, capturing the canonical session identity and display name the CLI reports, persisting that identity, and resuming the same session when the thread is reopened. It does not make YAAW an agent harness.

Plan 14 extends this boundary for Codex, Claude, OpenCode, and Copilot with CLI-confirmed rename, exact local session catalog auto-linking, and explicit recovery for older unbound threads when no unique exact match exists.

## Requirements

- Technical Requirements: Threads, Terminal Requirements, Agent CLI Scope, External Tools, Acceptance Criteria.
- Non-Functional Requirements: Reliability, Maintainability, Observability.
- Testing Requirements: Inputs And Outputs, Mocking Policy.
- Standards: [libghostty Standard](../standards/dependency/libghostty.md).
- Follow-up: [Plan 14: Session Resume And Rename Support](14-session-resume-and-rename.md).

## Implementation

- Add an agent CLI binding service under `src/Threads/` (or a dedicated `src/AgentCLI/` module) that owns YAAW-side `codex` and `claude` launch, session-id capture, and resume invocation.
- Define a small `AgentCLIAdapter` boundary with one implementation per CLI kind so adding new kinds later does not touch UI or persistence code.
- Resolve `codex` and `claude` from settings or the user's `PATH`. Treat missing user-installed binaries as a launch failure surfaced through raw terminal output.
- Launch the chosen CLI in the thread working directory through the terminal abstraction (Plan 05) backed by libghostty (Plan 06).
- Capture the CLI session's reported name, title, or id from CLI output at the adapter boundary so the capture strategy is replaceable per CLI.
- Persist the captured canonical name and session identity on the thread record through the SQLite store (additive migration on top of Plan 03's `agent_cli` column).
- Update the thread display name when the CLI reports it. Prefer the CLI-reported name, fall back to title, fall back to session id.
- Invoke the CLI resume path (e.g. `codex resume <id>` / `claude resume <id>`) when reopening a thread with a stored identity. If resume fails, surface the raw CLI error in the thread terminal and offer no silent fallback to a fresh session — the user decides whether to start over.
- Keep CLI-specific concerns isolated. UI code never references `codex` or `claude` directly; it talks to the adapter boundary. The adapter MUST NOT own prompt routing, authentication, model policy, approval behavior, or tool execution.

## Tests

- Unit tests for resume command construction per CLI kind given a stored session identity.
- Unit tests for canonical-name selection (CLI-reported name > title > id) against controlled CLI output fixtures.
- Unit tests for thread record updates when the CLI reports a name after launch, using a real temporary SQLite store.
- Integration tests using deterministic `codex` and `claude` command doubles (fixture binaries on `PATH`) that emit known session ids and names. The full launch → capture → store → resume cycle MUST be exercised end to end against a real SQLite store and the terminal abstraction.
- Tests MUST avoid asserting raw libghostty internals; assert at the adapter and store boundaries.

## Manual Smoke Procedure

Until the E2E harness (Plan 10) covers this flow, document a manual smoke check in the plan PR description:

1. Build via `scripts/build.sh`.
2. Run via `scripts/run.sh`.
3. Create a new thread, choose `codex`.
4. Verify the thread terminal launches `codex` in the working directory.
5. Verify the thread display name updates to the reported session name within a reasonable interval.
6. Quit the app, relaunch, reopen the thread.
7. Verify the resume command runs and the terminal shows the previous session.
8. Repeat steps 3–7 with `claude`.

## Acceptance Criteria

- Creating a thread launches the chosen `codex` or `claude` CLI in the thread working directory.
- The thread display name updates to match the CLI session's reported name, title, or id.
- The CLI session identity is persisted on the thread record and survives app restart.
- Reopening a thread resumes the stored CLI session identity rather than starting a new session.
- An unresumable stored identity surfaces the raw CLI error in the thread's terminal and does not crash the app.
- Missing `codex` or `claude` binaries surface as raw terminal output in the thread's terminal.
- CLI-specific behavior is isolated behind a single adapter boundary.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with CLI binding coverage backed by deterministic CLI command doubles.
- The manual smoke procedure above is documented in the plan PR.
