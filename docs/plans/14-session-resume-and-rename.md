# Plan 14: Session Resume And Rename Support

## Summary

Make YAAW's thread names and resume behavior follow the bound CLI session instead of app-local guesses. Threads with stored CLI identities resume through the adapter. Threads loaded from older state without an identity first try an exact CLI-owned name match, then require an explicit link or start-new choice only when no unique match exists. Rename requests are queued through the adapter and become visible only after confirmed CLI metadata reports the new name.

## Requirements

- Technical Requirements: Threads, Terminal Requirements, App Layout, Acceptance Criteria.
- User Guide: thread start, switch, rename, archive, and recovery workflows.
- Related plan: [Plan 07: Agent CLI Session Binding](07-agent-cli-session-binding.md).

## Implementation

- Extend the `AgentCLIAdapter` boundary with resume command construction, optional start-name support, optional interactive rename startup input, and read-only session catalog candidates.
- Keep CLI-specific behavior inside `src/AgentCLI/`. Current command shapes are:
  - `codex resume <id>`
  - `claude --resume <id>`
  - `opencode --session <id>`
  - `copilot --resume=<id>`
- Use `--name` for Claude and Copilot new-session naming. Use queued `/rename <name>` startup input for Codex and stored-identity Claude/Copilot rename. Treat OpenCode rename as unavailable until a confirmable native path exists.
- Persist `pending_session_rename` on threads as additive SQLite state. Keep `sessionIdentity` and `canonicalSessionName` as the durable resume/name fields.
- Read lightweight local CLI metadata from app-owned or CLI-owned state only. Codex lookup includes `~/.codex/session_index.jsonl` and `~/.codex/history.jsonl` because recent Codex sessions may appear in history before the session index. Do not persist full terminal scrollback and do not write app metadata into user project directories.
- For loaded threads without `sessionIdentity`, auto-link a unique exact local catalog match using pending rename, canonical name, or visible display name. Show the main-terminal recovery state with explicit `Link Session...` and `Start New Session` choices only when that exact match is missing or ambiguous.
- Add `Rename Thread...` to active and archived thread menus. The sheet sends rename intent and leaves the existing visible name until the CLI reports matching metadata.

## Tests

- Unit-test adapter command shapes, naming capabilities, startup rename input, and session catalog readers.
- Unit-test AppModel behavior for stored-identity resume, loaded-unbound exact-match auto-linking, ambiguous/no-match link gating, link selection, start-new recovery, queued rename, and confirmed metadata sync.
- Unit-test the SQLite migration and reload behavior for `pending_session_rename`.
- Extend E2E coverage for create/capture/reload/resume, queued rename confirmation, and explicit link/start-new recovery.

## Acceptance Criteria

- Selecting a thread with a stored identity after restart launches the adapter resume command for that identity.
- Selecting a loaded older thread without an identity auto-links and resumes a unique exact CLI-owned name match.
- Selecting a loaded older thread without an identity does not silently start a fresh session when no unique exact match exists.
- Link recovery persists the selected CLI session id/name and resumes it.
- Start-new recovery is explicit and starts a fresh CLI session.
- Context-menu rename and manual `/rename` metadata update the sidebar only after confirmed CLI metadata reports the new name.
- OpenCode participates in resume and linking but does not expose rename until support can be confirmed.
