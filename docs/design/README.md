# Design

This document describes the first implementation shape for the native macOS Agent IDE.

The design favors a small, terminal-first app over a full IDE. The first version should make project/thread context, terminal state, file discovery, lightweight `nvim` editing, and `lazygit` Git workflows feel native and reliable before adding larger editor or automation features.

## Product Principles

- Native macOS shell.
- Dracula theme everywhere.
- Terminal-first workflow.
- One project terminal per thread.
- `nvim` for file editing in the right panel.
- `lazygit` for Git workflows in the right panel.
- Resizeable and collapsible panels.
- Project state scoped to local directories.
- Minimal feature set until the core workflow is solid.

## Theme

Use the Dracula OSS palette as the app's visual contract.

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

Reference: [dracula/dracula-theme](https://github.com/dracula/dracula-theme).

## App Shell

The app shell is a native macOS window with split-view layout.

```text
+--------------------------------------------------------------------------------+
| Sidebar icons | Active project / thread                         | Tool actions |
+---------------+-----------------------------------------------+----------------+
| Projects      | Project terminal                              | File tree      |
| Threads       |                                               | nvim / lazygit |
| Archive       |                                               |                |
|               |                                               |                |
|               +-----------------------------------------------+----------------+
|               | Global terminal, collapsed by default                          |
+---------------+---------------------------------------------------------------+
```

The shell has four resizeable regions:

- Left project/thread sidebar.
- Main project terminal.
- Right tool panel.
- Bottom global terminal when expanded.

Each region should use native split-view handles. Collapsed regions become narrow icon rails instead of disappearing from the user's mental model.

## Navigation Model

### Project

A project is a named local directory. The `global` project is a built-in project scoped to the user's home directory.

Project metadata should include:

- Stable project id.
- Display name.
- Root directory.
- Created timestamp.
- Last opened timestamp.
- Archived flag, if project archiving is later added.

### Thread

A thread belongs to one project and owns one project terminal.

Thread metadata should include:

- Stable thread id.
- Project id.
- Display name.
- Working directory.
- Terminal session identity.
- Created timestamp.
- Last opened timestamp.
- Archived flag.

The left sidebar is the only required thread switcher for the MVP.

## Terminal Design

All embedded terminal surfaces should use `libghostty`.

The MVP needs four terminal roles:

- **Project terminal:** one terminal per thread, launched in the project directory.
- **Global terminal:** shared terminal, launched in the user's home directory, collapsed by default.
- **Editor terminal:** right-panel terminal used to run `nvim` for an opened file.
- **Git terminal:** right-panel terminal used to run `lazygit` for the active project.

Project terminals should remain associated with their thread. Switching threads should restore the matching terminal surface rather than starting a new shell every time.

Terminal process state is runtime state. It should be kept while the app process is running, but the first version does not need to restore terminal sessions after app restart.

## Right Tool Panel

The right panel has three modes:

- **Browse mode:** shows project files and fuzzy search.
- **Edit mode:** runs `nvim` for the opened file inside the same right panel.
- **Git mode:** runs `lazygit` for the active project inside the same right panel.

Users can switch modes by clicking mode icons or cycling the panel tabs. The controls should be visible in the right-panel header and remain available in all three modes.

The selected right-panel mode and tool context are scoped to the selected thread. Threads may share the same visible right-panel state when they point at the same working directory, but the implementation should not depend on shared state.

Opening a file should:

1. Resolve the selected file relative to the active project root.
2. Switch the right panel from browse mode to edit mode.
3. Start or reuse the editor terminal for the active project/thread.
4. Launch `nvim <relative-file-path>` in that terminal.

Opening Git mode should:

1. Resolve the active project root.
2. Switch the right panel to Git mode.
3. Start or reuse the Git terminal for the active project/thread.
4. Launch `lazygit` in the active project root.

The MVP does not need a custom text editor, native source control UI, editor tabs, minimap, language server UI, or file decorations beyond basic selection and search.

## Fuzzy File Search

The first implementation should keep indexing simple:

- Walk the active project directory.
- Ignore common heavy folders such as `.git`, `node_modules`, `.build`, `dist`, and derived-data folders.
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

Persist:

- Projects.
- Threads.
- Archived thread state.
- Last selected project and thread.
- Panel collapsed states.
- Panel sizes, if feasible.
- Last selected right-panel mode.

Terminal scrollback persistence is optional for the first version.

## Keyboard Shortcuts

| Shortcut | Behavior |
| --- | --- |
| `Cmd+J` | Toggle the global terminal. |
| `Cmd+[` | Navigate back. |
| `Cmd+]` | Navigate forward. |
| `Cmd+Shift+[` | Cycle right-panel modes backward. |
| `Cmd+Shift+]` | Cycle right-panel modes forward. |

Add more shortcuts only after the interaction model stabilizes.

## Implementation Notes

- SwiftUI is suitable for the high-level app shell, sidebar lists, modal sheets, and simple controls.
- AppKit is likely needed for split-view control, focus handling, and terminal embedding.
- `libghostty` should be the terminal rendering path for project, global, editor, and Git terminals.
- The right editor panel should use `nvim` rather than a custom editor.
- The right Git panel should use `lazygit` rather than a custom source control UI.
- Keep all MVP state local and simple before adding sync, collaboration, or remote development.

## MVP Acceptance Criteria

- A user can create a project from a local directory and give it a name.
- A user can create and switch between threads under a project.
- Each thread gets one project terminal in the project directory.
- The global terminal starts collapsed and toggles with `Cmd+J`.
- The sidebar, right panel, and global terminal can be resized.
- The sidebar and right panel can be collapsed.
- The right panel shows project files and supports fuzzy matching.
- Opening a file launches `nvim` inside the right panel.
- Opening Git mode launches `lazygit` inside the right panel.
- Users can switch the right panel between file tree, `nvim`, and `lazygit` by cycling tabs or clicking icons.
- The full app uses the Dracula theme.
- A user can archive inactive threads.
