# Design

This document describes the first implementation shape for YAAW - Yet Another Agent Wrapper.

The design favors a small, terminal-first desktop wrapper over a full IDE or agent harness. YAAW assumes users bring their own preferred agent CLIs or agent CLI harnesses. The app should make project/thread context, bound local CLI agent session state, file discovery, local preview browsing, lightweight `nvim` editing, and `lazygit` Git workflows feel native and reliable while leaving agent behavior inside the user's chosen CLI.

## Product Principles

- Native macOS shell.
- Dracula by default, with built-in theme switching.
- Terminal-first workflow.
- One agent CLI session terminal per thread.
- Bring-your-own agent CLI, command-line harness, authentication, and model setup.
- No telemetry; app-owned state and diagnostics stay local on the user's device.
- Full-power local CLI agents, starting with `codex` and `claude` and expanding to `copilot` and `opencode`.
- No prompt orchestration, tool-call mediation, or agent harness behavior.
- Isolated WebKit helper process for right-panel browser previews and typed URL browsing.
- `nvim` for file editing in the right panel.
- `lazygit` for Git workflows in the right panel.
- Resizeable and collapsible panels.
- Project state scoped to local directories.
- Minimal feature set until the core workflow is solid.

## Theme

Use shared theme roles as the app's visual contract. Dracula is the default palette, and built-in light, dark, and high-contrast themes map to the same roles so all app and terminal surfaces change together.

| Token | Hex | Use |
| --- | --- | --- |
| `background` | `#282a36` | Window background, terminal background, inactive panel background. |
| `currentLine` | `#44475a` | Active row, selected file, resize handle hover, active thread. |
| `foreground` | `#f8f8f2` | Primary text. |
| `comment` | `#6272a4` | Muted labels, secondary metadata, inactive icons. |
| `cyan` | `#8be9fd` | Informational accent, file browser focus. |
| `green` | `#50fa7b` | Success states. |
| `orange` | `#ffb86c` | Warnings or modified state. |
| `pink` | `#ff79c6` | Primary action accent. |
| `purple` | `#bd93f9` | Active project/thread accent. |
| `red` | `#ff5555` | Error states. |
| `yellow` | `#f1fa8c` | Attention state. |

Reference for the default palette: [dracula/dracula-theme](https://github.com/dracula/dracula-theme).

## App Shell

The app shell is a native macOS window with split-view layout.

```text
+--------------------------------------------------------------------------------+
| Sidebar icons | Active project / thread                         | Tool actions |
+---------------+-----------------------------------------------+----------------+
| Projects      | Agent CLI session terminal                   | File tree      |
| Threads       |                                               | nvim / lazygit |
| Archive       |                                               |                |
|               |                                               |                |
|               +-----------------------------------------------+----------------+
|               | Global terminal, collapsed by default                          |
+---------------+---------------------------------------------------------------+
```

The shell has four resizeable regions:

- Left project/thread sidebar.
- Main agent CLI session terminal.
- Right tool panel.
- Selected-thread bottom terminal when expanded.

Each region should use native split-view handles. Collapsed regions become narrow icon rails instead of disappearing from the user's mental model.

The title bar includes a settings gear. The gear navigates to a full content-route settings view with the app-owned YAML settings path, current effective defaults, an embedded YAML editor, Save/Reload/Revert actions, optional external opening, and a top-right Back button.

## Navigation Model

### Project

A project is a named local directory. The `global` project is a built-in project scoped to the user's home directory.

Project metadata should include:

- Stable project id.
- Display name.
- Root directory.
- Created timestamp.
- Last opened timestamp.
- Pin state.
- Manual sort order.
- Archived flag, if project archiving is later added.

### Thread

A thread belongs to one project and owns one terminal-backed agent CLI session. Each thread is bound to exactly one CLI family.

Thread metadata should include:

- Stable thread id.
- Project id.
- Display name.
- Working directory.
- Agent CLI kind.
- CLI session identity for resume.
- Canonical CLI session name.
- Created timestamp.
- Last opened timestamp.
- Archived flag.
- Pin state.

The thread display name should mirror the bound CLI session's reported name, title, or id. Closing and reopening a thread should resume the same stored CLI session identity.

The left sidebar is the only required thread switcher for the MVP. It should use nested project rows: each project can expand to show active threads and an archived-thread disclosure, and each project row owns the new-thread action for that project. Pinned projects sort above unpinned projects, manual project reorder is scoped within pinned/unpinned groups, and pinned threads sort above recently opened unpinned threads.

Thread rows also carry lightweight activity state. A thread can be `working`, `needsInput`, `complete`, or `inactive`, with the latest sanitized preview and unread flag stored separately from `AgentThread` so session identity and activity UI stay decoupled. Persist only the latest activity state per thread; on launch, downgrade `working` to `inactive` because live process progress cannot survive restart.

## Terminal Design

All embedded terminal surfaces should use `libghostty`.

The MVP needs four terminal roles:

- **Agent CLI session terminal:** one terminal per thread, launched in the thread working directory and running the bound user-installed local CLI agent session.
- **Global terminal:** shared terminal, launched in the user's home directory, collapsed by default.
- **Editor terminal:** right-panel terminal used to run `nvim` for an opened file.
- **Git terminal:** right-panel terminal used to run `lazygit` for the active project.

Agent CLI session terminals should remain associated with their thread. Switching threads should restore the matching terminal surface rather than starting a new shell every time.

CLI-specific adapters should be thin launch/resume boundaries around user-owned tools. They may understand how to start or resume a supported CLI session, but they should not own prompt routing, model selection, authentication, approval policy, or tool-call execution.

Live terminal process state is runtime state. It should be kept while the app process is running, but the first version does not need to restore live PTY processes after app restart. Agent CLI resume metadata is durable state and should be stored so reopening a thread resumes the same CLI agent session.

Agent terminal surfaces should forward desktop notification, focus, close, and command-finished callbacks into app state. YAAW also exposes a helper command, `yaaw-notify`, only inside managed agent terminals by prepending an app-owned helper directory to `PATH` and setting `YAAW_THREAD_ID`, `YAAW_PROJECT_ID`, and `YAAW_EVENT_LOG`. The helper writes app-owned NDJSON and emits OSC 777 for compatibility with terminal notification conventions.

## Right Tool Panel

The right panel has four modes:

- **Browse mode:** shows project files and fuzzy search.
- **Browser mode:** uses an isolated WebKit helper process for typed URLs and local previews opened from the file browser.
- **Edit mode:** runs `nvim` for the opened file inside the same right panel.
- **Git mode:** runs `lazygit` for the active project inside the same right panel.

Users can switch modes by clicking mode icons or cycling the panel tabs. The controls should be visible in the right-panel header and remain available in all four modes.

The selected right-panel mode and tool context are scoped to the selected thread. Threads may share the same visible right-panel state when they point at the same working directory, but the implementation should not depend on shared state.

Opening a file should:

1. Resolve the selected file relative to the active project root.
2. Switch the right panel from browse mode to edit mode.
3. Start or reuse the editor terminal for the active project/thread.
4. Launch `nvim <relative-file-path>` in that terminal.

Opening a supported preview file in Browser mode should:

1. Resolve the selected file relative to the active thread working directory.
2. Confirm the resolved file stays under that working directory.
3. Switch the right panel to Browser mode.
4. Load the file URL through the isolated WebKit helper without writing metadata into the repository.
5. Keep the main app running if the renderer crashes, then show a reload/restart state for that browser tab.

Opening Git mode should:

1. Resolve the active project root.
2. Switch the right panel to Git mode.
3. Start or reuse the Git terminal for the active project/thread.
4. Launch `lazygit` in the active project root.

The MVP does not need a custom text editor, native source control UI, minimap, language server UI, browser downloads, browser extensions, developer tools, browser profile controls, or file decorations beyond basic selection and search.

## Fuzzy File Search

The first implementation should keep indexing simple:

- Walk the active project directory.
- Ignore common heavy folders such as `.git`, `node_modules`, `.build`, `dist`, and derived-data folders.
- Reuse app-owned cached file entries for threads with the same canonical working directory, Git identity, ignore-rules fingerprint, and index schema version.
- Keep cached entries in SQLite under YAAW storage, not in user repositories.
- Match by path segments and filename.
- Prefer exact filename matches, then prefix matches, then fuzzy path matches.

Deep semantic search is explicitly out of scope for the MVP.

## Panel Behavior

Panels should support both collapse and resize.

| Panel | Collapse behavior | Resize behavior |
| --- | --- | --- |
| Sidebar | Collapse to icon rail. | Horizontal width resize. |
| Main terminal | Never fully collapsed. | Resizes as adjacent panels change. |
| Right tool panel | Collapse to icon rail. | Horizontal width resize. |
| Global terminal | Collapsed by default. | Vertical height resize when expanded. |

Persist panel sizes when practical. If persistence is deferred, runtime resizing must still work.

## State Persistence

Use app-level local storage for MVP metadata. Avoid writing project metadata into user repositories unless that becomes an explicit product decision.

YAAW should not include telemetry, analytics, crash-report upload, or remote diagnostics for the first version. Local diagnostics are acceptable only when they stay on the user's device. Network behavior belongs to the user's chosen agent CLI or CLI harness, not to YAAW's project/thread organization layer.

Persist:

- Projects.
- Threads.
- Agent CLI kind per thread.
- Agent CLI session identity per thread.
- Canonical CLI session name per thread.
- Archived thread state.
- Last selected project and thread.
- Panel collapsed states.
- Panel sizes, if feasible.
- Last selected right-panel mode.
- Shared file index cache entries keyed by working directory and Git identity.

Terminal scrollback persistence is optional for the first version.

## Settings

User-editable settings live in `~/Library/Application Support/YAAW/settings.yaml` unless `YAAW_CONFIG_PATH` points to another file.

The YAML file is the source of truth for:

- Keyboard shortcuts.
- Built-in theme selection.
- Default agent CLI.
- Interface, editor, and embedded terminal font families and sizes.
- Editor fallback order.
- Git and diff tool commands.
- Agent executable command names.
- File indexing ignore rules.

The generated file should be heavily commented so users can see each default and which represented fields are not changeable yet. The app should parse settings forgivingly: unknown keys are ignored, missing keys use defaults, and malformed YAML recovers to defaults with a local diagnostic event. Normal startup should not rewrite a user-edited settings file.

## Keyboard Shortcuts

| Shortcut | Behavior |
| --- | --- |
| `Cmd+J` | Toggle the selected-thread bottom terminal. |
| `Cmd+[` | Navigate back. |
| `Cmd+]` | Navigate forward. |
| `Cmd+Shift+[` | Cycle right-panel modes backward. |
| `Cmd+Shift+]` | Cycle right-panel modes forward. |

Add more shortcuts only after the interaction model stabilizes.

## Implementation Notes

- SwiftUI is suitable for the high-level app shell, sidebar lists, modal sheets, and simple controls.
- AppKit is likely needed for split-view control, focus handling, and terminal embedding.
- `libghostty` should be the terminal rendering path for project, bottom, editor, and Git terminals.
- Thread creation should prompt for an available CLI family, then launch the selected CLI in the thread working directory.
- Thread reopening should use the stored CLI session identity to resume the bound session.
- The right editor panel should use `nvim`, with `vim` and `vi` fallbacks, rather than a custom editor.
- The right Git panel should use `lazygit`, with `git diff` fallback, rather than a custom source control UI.
- Keep all MVP state local and simple before adding sync, collaboration, or remote development.

## MVP Acceptance Criteria

- A user can create a project from a local directory and give it a name.
- A user can create and switch between threads under a project.
- Creating a thread asks which available CLI family to invoke.
- Each thread gets one agent CLI session terminal in the thread working directory.
- Each thread is named from the bound CLI session name, title, or id.
- Reopening a thread resumes the bound CLI session identity.
- The selected-thread bottom terminal starts collapsed and toggles with `Cmd+J`.
- The sidebar, right panel, and bottom terminal can be resized.
- The sidebar and right panel can be collapsed.
- The right panel shows project files and supports fuzzy matching.
- The right panel can preview supported local files and typed URLs in Browser mode.
- Opening a file launches `nvim`, `vim`, or `vi` inside the right panel.
- Opening Git mode launches `lazygit` or `git diff` inside the right panel.
- Users can switch the right panel between file tree, Browser, `nvim`, and `lazygit` by cycling tabs or clicking icons.
- The full app uses the selected built-in theme, defaulting to Dracula.
- A user can archive inactive threads.
