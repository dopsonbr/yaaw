# libghostty Standard

- Use `libghostty` for every embedded terminal surface.
- Apply consistent lifecycle handling across agent CLI session, global, `nvim`, and `lazygit` terminals.
- Preserve runtime terminal state while the app is running; do not require live PTY process restart persistence.
- Persist the agent CLI session metadata needed to resume a thread's bound `codex` or `claude` session.

## Distribution

- Current implementation uses `Package.swift` dependency `https://github.com/Lakr233/libghostty-spm.git` from `1.1.4` and imports only `GhosttyTerminal` inside `src/App/GhosttyTerminalSurfaceView.swift`.
- Official Ghostty docs and repository currently describe `libghostty` as the embeddable API, with the public split starting at `libghostty-vt`; they do not publish a stable official SwiftUI/AppKit package for the full terminal surface as of the Plan 11 review on 2026-05-20.
- Keep the wrapper boundary narrow. If Ghostty publishes an official full-surface Swift package later, change `Package.swift` and `src/App/GhosttyTerminalSurfaceView.swift`; do not move Ghostty types into `AgentIDEKit`.
- `script/build_and_run.sh --verify` signs the staged SwiftPM `.app` ad hoc, verifies the bundle signature, and rejects links to `/Applications/Ghostty.app`.
- The current SwiftPM build does not require `/Applications/Ghostty.app`; Ghostty terminal code is provided by the Swift package artifact and system frameworks shown by `otool -L dist/AgentIDE.app/Contents/MacOS/AgentIDE`.
