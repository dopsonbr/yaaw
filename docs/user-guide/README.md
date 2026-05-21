# User Guide

This guide describes the intended first-version workflow for YAAW - Yet Another Agent Wrapper.

## What The App Is For

Use the app to organize CLI agent work by project and thread. Each project is tied to a local directory. Each thread is tied to exactly one local CLI agent session, so work can be resumed without mixing command history, process state, or session identity across unrelated sessions.

YAAW wraps local CLIs; it does not act as an agent harness. Prompts, tool calls, authentication, model behavior, and remote service access stay inside the selected CLI.

The app uses Dracula by default and supports built-in light, dark, and high-contrast themes across panels, terminals, file browsing, and editing surfaces.

Settings are stored in an app-owned YAML file. Use the title-bar gear to inspect the current settings path, open the YAML file, or reload settings after editing it.

## Main Screen

The main screen has three areas:

- **Projects sidebar:** project and thread navigation.
- **Agent CLI session terminal:** the active local CLI agent terminal for the selected thread.
- **Right tool panel:** project files, opened files in `nvim`/`vim`/`vi`, and Git workflows in `lazygit` or `git diff`.

The sidebar nests thread history under each project. Project rows can be expanded or collapsed, pinned, reordered, and used to start a new thread directly in that project. The sidebar and right tool panel can both be collapsed to keep the terminal-focused view clean. Every major panel can also be resized.

## Create A Project

1. Choose the new project action.
2. Select a local directory.
3. Enter a project name when prompted.
4. The app creates the project and prepares it for agent CLI threads in that directory.
5. The project appears in the sidebar.

Each project is scoped to one directory. The built-in `global` project is scoped to the user's home directory.

## Start A Thread

1. Select a project in the sidebar.
2. Use that project's new-thread action.
3. Optionally enter a thread name.
4. Choose which available CLI family the thread should invoke.
5. The app launches the selected CLI in the thread working directory.
6. If the name is left blank, the thread starts with a CLI placeholder and then updates to match the CLI session's reported name, title, or id.

Each thread has its own agent CLI session terminal. Switching threads switches the active terminal and preserves the thread's selected CLI session identity.

## Switch Threads

Use the left sidebar to select a different thread. Expand a project row to see its active thread history, or expand that project's archived area to inspect archived threads.

When a thread is selected:

- The main terminal switches to that thread's agent CLI session terminal.
- If the thread is reopened after being closed, the app resumes the stored CLI session identity.
- The right tool panel shows files and tools for that thread's project.
- The top project/thread area reflects the active context.

Pinned threads appear above unpinned threads inside their project. Unpinned threads are ordered by most recently opened.

## Organize Projects

Pin important projects to keep them above unpinned projects. Use project reorder controls to move projects within the pinned or unpinned group. Project order, pin state, and expanded/collapsed state are app-owned metadata and do not write files into project directories.

## Use The Agent CLI Session Terminal

The agent CLI session terminal is the main working surface. It starts in the selected thread's working directory, runs the thread's bound local CLI agent session, and should behave like a native terminal because it is backed by `libghostty`.

The MVP expectation is simple:

- One agent CLI session terminal per thread.
- The selected CLI family remains associated with the thread.
- The CLI session name is the source of the visible thread name.
- Reopening the thread resumes the associated CLI session.
- Project commands run from the project directory.
- Terminal surfaces use the selected built-in theme.

## Use The Bottom Terminal

The bottom terminal is collapsed by default and scoped to the selected project thread.

Press `Cmd+J` to toggle it.

Use the bottom terminal for commands tied to the active project thread. Toggling or resizing it should not change the sidebar width, sidebar collapsed state, selected project, selected thread, or left-panel content.

## Browse Project Files

The right tool panel can show the selected project's file tree.

Use it to:

- Inspect the project directory.
- Find files by name.
- Use fuzzy matching to narrow large file lists.

When multiple threads use the same directory and Git branch, the file list can reuse the same app-owned cache. Switching between those threads should keep the file list available while YAAW refreshes it in the background.

The file browser can be collapsed when it is not needed.

## File And App Icons

YAAW uses native macOS symbols for app controls such as settings, navigation, panel toggles, refresh, warnings, archives, pins, and right-panel mode buttons. The file browser uses VS Code-inspired file and folder identity icons so common source files, config files, docs, and project folders are easier to scan.

The default file browser icon pack is `material-file-icons`. To use the softer Dracula-friendly alternate, set `icons.fileBrowserPack` to `catppuccin-file-icons` in the app-owned YAML settings file and reload settings. This setting changes file and folder icons only; app control icons remain native macOS symbols.

## Switch Right Panel Modes

The right panel has three modes:

- **Files:** browse the project file tree and search with fuzzy matching.
- **nvim:** open and edit a selected file inside the right panel with `nvim`, falling back to `vim` and then `vi`.
- **Git:** open `lazygit` inside the right panel, falling back to `git diff` when `lazygit` is unavailable.

Switch modes by clicking the right-panel mode icons or by cycling the panel tabs. The active mode stays scoped to the selected project/thread.

## Open A Project Or File Externally

Use the title-bar external-open control to open the selected thread working directory in an installed external destination. If no thread is selected, YAAW opens the selected project root.

Use a file row's context menu to open that file externally. Editor apps open the file directly, Finder reveals the file, and Terminal or Ghostty opens the file's containing directory.

YAAW detects supported destinations from installed macOS apps and shows them in settings order. Supported destinations are VS Code, VS Code Insiders, Sublime Text, Zed, Finder, Terminal, Ghostty, Xcode, and WebStorm.

## Open A File In nvim

1. Select a project thread.
2. Open the right tool panel.
3. Search or browse to a file.
4. Open the file.
5. The right panel switches to `nvim` and opens the selected file.

The editor session runs inside the selected project's directory and stays in the right panel. YAAW tries `nvim` first, then `vim`, then `vi`. It should not open a separate app window for the MVP.

## Open lazygit

1. Select a project thread.
2. Open the right tool panel.
3. Click the Git mode icon or cycle tabs until Git is active.
4. The right panel opens a terminal and starts `lazygit` in the selected project's directory.

Use `lazygit` for focused Git tasks without leaving the app shell. If `lazygit` is unavailable, YAAW opens `git diff` in the same right-panel terminal. The MVP should not open a separate terminal window for this flow.

## Paste Images Into CLIs

When a CLI terminal has focus, use `Cmd+V` to paste. Text follows the normal terminal paste behavior. Images from the pasteboard are saved as app-owned PNG files under YAAW's Application Support directory, and the terminal receives `Attached image: <absolute-path>` without pressing Enter. `Ctrl+V` uses the same image attach behavior when the terminal has focus.

## Resize Panels

Drag panel dividers to resize the workspace.

The MVP panels that must resize are:

- Projects sidebar width.
- Main agent CLI session terminal width.
- Right tool panel width.
- Bottom terminal height when expanded.

Use resize behavior to make the active work surface larger without closing the other panels.

## Archive Threads

Archive a thread when it is no longer part of the active project list.

Archived threads move out of the active list for their project but remain available from that project's archived area. Archiving keeps the selected agent CLI and session identity so the thread can be resumed later.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `Cmd+J` | Toggle the selected-thread bottom terminal. |
| `Cmd+[` | Navigate back. |
| `Cmd+]` | Navigate forward. |
| `Cmd+Shift+[` | Cycle right-panel tabs backward. |
| `Cmd+Shift+]` | Cycle right-panel tabs forward. |

Additional shortcuts should be added only when the behavior is stable and clearly useful.

## Configure Settings

Open the title-bar gear to navigate to the in-app YAML settings editor. By default, settings live at:

```text
~/Library/Application Support/YAAW/settings.yaml
```

The generated YAML file includes comments showing current defaults and which fields are active now. Current active settings include theme selection, keyboard shortcuts, the default agent CLI, editor fallback order, external-open destination order, Git and diff commands, agent command names, fonts, and file indexing ignore rules.

Theme settings are represented under `theme.active`. Use the Settings Appearance picker or set one of the supported theme ids in YAML: `dracula`, `dark-2026`, `dark-plus`, `dark-modern`, `monokai`, `solarized-dark`, `light-2026`, `light-modern`, `light-plus`, `quiet-light`, `solarized-light`, `dark-high-contrast`, or `light-high-contrast`. Unknown values fall back to `dracula` and record a local diagnostic event. Custom theme palettes are placeholders for future expansion.

Icon settings are represented under `icons.fileBrowserPack`. Supported values are `material-file-icons` and `catppuccin-file-icons`; unknown values fall back to `material-file-icons` and record a local diagnostic event.

Font settings are represented under `fonts`. Use `interfaceFamily` / `interfaceSize` for app chrome and navigation text, `editorFamily` / `editorSize` for the in-app YAML/editor-style text, and `terminalFamily` / `terminalSize` for embedded Ghostty terminal surfaces. `system` and `system-monospace` select native macOS fonts; other family values should match installed font family names. Leave `terminalFamily` empty to keep Ghostty's default terminal font family.

External-open settings are represented under `tools.externalOpen`. Set `default` to the preferred destination id and use `preferred` to control menu order. Supported ids are `vscode`, `vscode-insiders`, `sublime-text`, `zed`, `finder`, `terminal`, `ghostty`, `xcode`, and `webstorm`.

Use Save to validate, write, and apply YAML changes. Reload re-reads the file from disk, Revert discards unsaved editor changes, and Back returns to the workspace. If the YAML is malformed, YAAW shows the validation error and does not overwrite the last saved file.

## Recommended First Workflow

1. Create a project from a local repo directory.
2. Name the project.
3. Start a thread for the task you want the agent to work on.
4. Choose an available CLI family for the new thread.
5. Use the agent CLI session terminal for that thread.
6. Let the thread name mirror the CLI session name once the CLI reports it.
7. Use the file browser to inspect project files.
8. Open a file in `nvim` inside the right panel when you need to inspect or edit it.
9. Use external-open when you need the project or a file in a full editor, Finder, Terminal, or Ghostty.
10. Switch the right panel to Git when you need `lazygit` or `git diff`.
11. Resize or collapse panels when you want more terminal or editor space.
12. Archive the thread when the work is complete.

## MVP Boundaries

The first version should stay focused. Expect terminal-first CLI agent workflows, simple project/thread management, lightweight file browsing, terminal-backed editor fallback through `nvim`, `vim`, or `vi`, external-open handoff to installed macOS apps, and Git workflows through `lazygit` or `git diff`. Current implementation paths cover `codex`, `claude`, `opencode`, and `copilot`.

Use a full editor or external tools for advanced editing, source control management, debugging, or deep project analysis until those features are intentionally added.
