# User Guide

This guide describes the intended first-version workflow for the native macOS Agent IDE.

## What The App Is For

Use the app to organize agent work by project and thread. Each project is tied to a local directory. Each thread gets its own terminal, so work can be resumed without mixing command history or process state across unrelated sessions.

The app uses the Dracula theme across all panels, terminals, file browsing, and editing surfaces.

## Main Screen

The main screen has three areas:

- **Projects sidebar:** project and thread navigation.
- **Project terminal:** the active terminal for the selected thread.
- **Right tool panel:** project files, opened files in `nvim`, and Git workflows in `lazygit`.

The sidebar and right tool panel can both be collapsed to keep the terminal-focused view clean. Every major panel can also be resized.

## Create A Project

1. Choose the new project action.
2. Select a local directory.
3. Enter a project name when prompted.
4. The app creates the project and opens a project terminal in that directory.
5. The project appears in the sidebar.

Each project is scoped to one directory. The built-in `global` project is scoped to the user's home directory.

## Start A Thread

1. Select a project in the sidebar.
2. Create a new thread.
3. The app creates one project terminal for that thread.
4. Use the terminal to start or resume the agent workflow for that thread.

Each thread has its own project terminal. Switching threads switches the active terminal.

## Switch Threads

Use the left sidebar to select a different thread.

When a thread is selected:

- The main terminal switches to that thread's project terminal.
- The right tool panel shows files and tools for that thread's project.
- The top project/thread area reflects the active context.

## Use The Project Terminal

The project terminal is the main working surface. It starts in the selected project's directory and should behave like a native terminal because it is backed by `libghostty`.

The MVP expectation is simple:

- One terminal per thread.
- Terminal state remains associated with the thread.
- Project commands run from the project directory.
- Terminal surfaces use the Dracula theme.

## Use The Global Terminal

The global terminal is collapsed by default.

Press `Cmd+J` to toggle it.

Use the global terminal for commands that are not specific to the active project thread, such as quick shell checks, global setup, or home-directory tasks.

## Browse Project Files

The right tool panel can show the selected project's file tree.

Use it to:

- Inspect the project directory.
- Find files by name.
- Use fuzzy matching to narrow large file lists.

The file browser can be collapsed when it is not needed.

## Switch Right Panel Modes

The right panel has three modes:

- **Files:** browse the project file tree and search with fuzzy matching.
- **nvim:** open and edit a selected file inside the right panel.
- **Git:** open `lazygit` inside the right panel.

Switch modes by clicking the right-panel mode icons or by cycling the panel tabs. The active mode stays scoped to the selected project/thread.

## Open A File In nvim

1. Select a project thread.
2. Open the right tool panel.
3. Search or browse to a file.
4. Open the file.
5. The right panel switches to `nvim` and opens the selected file.

The `nvim` session runs inside the selected project's directory and stays in the right panel. It should not open a separate app window for the MVP.

## Open lazygit

1. Select a project thread.
2. Open the right tool panel.
3. Click the Git mode icon or cycle tabs until Git is active.
4. The right panel opens a terminal and starts `lazygit` in the selected project's directory.

Use `lazygit` for focused Git tasks without leaving the app shell. The MVP should not open a separate terminal window for this flow.

## Resize Panels

Drag panel dividers to resize the workspace.

The MVP panels that must resize are:

- Projects sidebar width.
- Main project terminal width.
- Right tool panel width.
- Global terminal height when expanded.

Use resize behavior to make the active work surface larger without closing the other panels.

## Archive Threads

Archive a thread when it is no longer part of the active project list.

Archived threads should move out of the main sidebar view but remain available from the archive area.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `Cmd+J` | Toggle the global terminal. |
| `Cmd+[` | Navigate back. |
| `Cmd+]` | Navigate forward. |
| `Cmd+Shift+[` | Cycle right-panel tabs backward. |
| `Cmd+Shift+]` | Cycle right-panel tabs forward. |

Additional shortcuts should be added only when the behavior is stable and clearly useful.

## Recommended First Workflow

1. Create a project from a local repo directory.
2. Name the project.
3. Start a thread for the task you want the agent to work on.
4. Use the project terminal for that thread.
5. Use the file browser to inspect project files.
6. Open a file in `nvim` inside the right panel when you need to inspect or edit it.
7. Switch the right panel to Git when you need `lazygit`.
8. Resize or collapse panels when you want more terminal or editor space.
9. Archive the thread when the work is complete.

## MVP Boundaries

The first version should stay focused. Expect terminal-first workflows, simple project/thread management, lightweight file browsing, `nvim` for file editing, and `lazygit` for Git workflows.

Use a full editor or external tools for advanced editing, source control management, debugging, or deep project analysis until those features are intentionally added.
