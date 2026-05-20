# libghostty Standard

- Use `libghostty` for every embedded terminal surface.
- Apply consistent lifecycle handling across agent CLI session, global, `nvim`, and `lazygit` terminals.
- Preserve runtime terminal state while the app is running; do not require live PTY process restart persistence.
- Persist the agent CLI session metadata needed to resume a thread's bound `codex` or `claude` session.
