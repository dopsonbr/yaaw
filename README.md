# YAAW - Yet Another Agent Wrapper

YAAW is an opinionated native macOS desktop app for people who already have a preferred local agent CLI or agent CLI harness. It is inspired by Codex Desktop, but it keeps the user's chosen agents in charge: users bring their own installed `codex`, `claude`, `copilot`, `opencode`, or compatible command-line harnesses and run them with their full terminal power inside `libghostty` surfaces.

YAAW is not an agent harness itself. It does not orchestrate agents, rewrite prompts, proxy tool calls, replace authentication, or hide the underlying CLI. It augments the user's preferred CLI workflow with project/thread organization, session binding and resume, local terminal surfaces, right-panel tools, and a few macOS-native product opinions.

YAAW has no telemetry. App state, settings, indexes, activity previews, and diagnostics stay local on the user's device. Anything that leaves the device is between the user and the agent CLI or CLI harness they chose to run.

The first implementation stays small: it gives users a project list, one active thread at a time, one managed agent CLI session terminal per thread, and a collapsible right tool panel for files, `nvim`/`vim`/`vi`, and `lazygit`/`git diff`. Current code paths cover `codex`, `claude`, `opencode`, and `copilot`.

## Install

Install the latest GitHub release on an Apple Silicon Mac:

```sh
curl -fsSL https://raw.githubusercontent.com/dopsonbr/yaaw/main/scripts/install-release.sh | sh
```

The release installer downloads the latest `YAAW-*-macos-arm64.zip` asset, installs `YAAW.app` under `/Applications`, and installs a `yaaw` launcher under `/usr/local/bin`. To build and install from a local checkout instead, use `scripts/install.sh`.

## Goals

- Keep the app native, fast, and minimal.
- Make projects and threads easy to switch from a single sidebar.
- Scope every project to a local directory.
- Assume users bring their own agent CLIs, command-line harnesses, authentication, and model configuration.
- Keep app metadata and diagnostics local with no telemetry.
- Provide one full-power CLI agent session terminal per thread.
- Treat `codex`, `claude`, `opencode`, and `copilot` as supported CLI families.
- Provide a selected-thread bottom terminal that starts collapsed and can be toggled with `Cmd+J`.
- Use `libghostty` for embedded terminal rendering and terminal behavior.
- Use Dracula by default and keep built-in theme switching consistent across every app surface.
- Show files for the selected project in a collapsible right tool panel.
- Open selected files in `nvim` inside the right panel, falling back to `vim` and then `vi`.
- Open `lazygit` in a terminal inside the right panel, falling back to `git diff` when `lazygit` is unavailable.
- Switch the right panel between file tree, `nvim`, and `lazygit` by cycling tabs or clicking mode icons.
- Support fuzzy matching in the file browser.
- Provide a title-bar settings gear for the app-owned YAML settings file.
- Make every major panel resizeable.
- Allow old or completed threads to be archived.

## Visual Theme

The app uses Dracula as the default theme and supports built-in light, dark, and high-contrast themes. All primary surfaces, including sidebars, terminals, file browser, `nvim` editor panel, `lazygit` panel, modal sheets, dividers, and selection states, should use the selected theme palette.

| Role | Color |
| --- | --- |
| Background | `#282a36` |
| Current line / selection | `#44475a` |
| Foreground | `#f8f8f2` |
| Comment / muted text | `#6272a4` |
| Cyan | `#8be9fd` |
| Green | `#50fa7b` |
| Orange | `#ffb86c` |
| Pink | `#ff79c6` |
| Purple | `#bd93f9` |
| Red | `#ff5555` |
| Yellow | `#f1fa8c` |

Reference: [dracula/dracula-theme](https://github.com/dracula/dracula-theme).

## MVP Layout

The app has three primary regions:

1. **Left sidebar**
   - Collapsible.
   - Resizeable.
   - Shows projects and their threads.
   - Includes a global workspace scoped to the user's home directory.
   - Provides access to archived threads.

2. **Main workspace**
   - Resizeable against the sidebar, right tool panel, and selected-thread bottom terminal.
   - Shows the selected project/thread.
   - Contains the agent CLI session terminal for the selected thread.
   - Asks which available CLI family a new thread should start.
   - Creates or resumes the bound agent CLI session for each selected thread.

3. **Right tool panel**
   - Collapsible.
   - Resizeable.
   - Shows files for the selected project directory.
   - Supports fuzzy matching for quickly finding files.
   - Opens selected files in `nvim` inside the same right panel.
   - Opens `lazygit` in a terminal inside the same right panel.
   - Switches between file tree, `nvim`, and `lazygit` using tabs or icon buttons.

A bottom terminal is available for the selected thread. It is collapsed by default, resizeable when expanded, toggled with `Cmd+J`, and isolated from sidebar selection and sizing.

## Core Concepts

### Project

A project is a named workspace scoped to a local directory. Creating a project opens a terminal for that directory and prompts the user for a project name.

The special `global` project is scoped to the user's home directory.

### Thread

A thread is one agent CLI session inside a project. Each thread is bound to exactly one CLI family, and the thread name matches that CLI session's reported name, title, or id.

Users switch between threads from the left sidebar.

Closing and reopening a thread resumes the same bound agent CLI session. A thread cannot switch from one CLI family to another after it is created.

### Agent CLI Session Terminal

Each thread owns one agent CLI session terminal. The terminal starts in the thread's working directory, launches the selected user-installed local CLI or CLI harness, and is backed by `libghostty`.

Runtime terminal process state is kept while the app is open. Durable thread metadata stores the selected CLI and session identity needed to resume the same CLI session after the thread or app is reopened.

### Bottom Terminal

The bottom terminal is scoped to the selected thread and uses that thread's working directory. It starts collapsed to keep the main interface focused and can be opened with `Cmd+J`.

### Right Tool Panel

The right tool panel shows files for the selected project and provides lightweight terminal-backed tools. It should stay small: directory tree, fuzzy matching, `nvim` file open behavior, and `lazygit` are enough for the first version.

When a file is opened, the right panel changes from browse mode to editor mode and launches `nvim` for that file in the selected project's directory. If `nvim` is unavailable, YAAW falls back to `vim` and then `vi`. The panel remains part of the app layout instead of opening a separate editor window.

When the Git mode is opened, the right panel launches `lazygit` in the selected project's directory. If `lazygit` is unavailable, YAAW falls back to `git diff`. This gives users a focused Git terminal UI without building custom source control screens.

When an agent terminal has focus, `Cmd+V` can paste text through the normal terminal path or attach an image from the pasteboard. Image paste stores a normalized PNG under YAAW's Application Support directory and inserts `Attached image: <absolute-path>` without submitting the prompt. `Ctrl+V` uses the same image attach path when the terminal has focus.

User-editable settings live in `~/Library/Application Support/YAAW/settings.yaml` by default. The title-bar gear opens a lightweight settings sheet with actions to open and reload that YAML file.

Users can switch right-panel modes by cycling tabs or clicking mode icons:

- File tree.
- `nvim`.
- `lazygit`.

### Resizeable Panels

Every major panel should be resizeable through native split-view handles:

- Sidebar width.
- Main agent CLI session terminal width.
- Right tool panel width.
- Bottom terminal height when expanded.

Panel sizes should persist per app workspace unless that adds too much implementation complexity for the first cut. If persistence is deferred, resize behavior itself remains required.

## Initial Feature Set

| Area | MVP behavior |
| --- | --- |
| Projects | Create a project from a local directory, name it, and list it in the sidebar. |
| Threads | Create, select, resume, and archive CLI agent sessions under a project. |
| Terminals | One `libghostty` agent CLI session terminal per thread. One collapsed selected-thread bottom terminal. |
| Theme | Dracula across all panels, terminals, modals, and selection states. |
| Sidebar | Collapsible and resizeable project/thread navigation. |
| Right tool panel | Collapsible and resizeable file tree, `nvim`, and `lazygit` modes with fuzzy file matching. |
| Archive | Move inactive threads out of the main project list. |

## Example Pages

Generated Dracula-themed example pages are available under `docs/examples/screenshots/`:

- [Main workspace](docs/examples/screenshots/main-workspace-dracula.png)
- [Main workspace variant](docs/examples/screenshots/main-workspace-dracula-v2.png)
- [nvim right panel](docs/examples/screenshots/nvim-right-panel-dracula.png)
- [Terminal focus mode](docs/examples/screenshots/terminal-focus-dracula.png)
- [Right panel Files mode](docs/examples/screenshots/right-panel-files-mode-dracula.png)
- [Right panel nvim mode](docs/examples/screenshots/right-panel-nvim-mode-dracula.png)
- [Right panel lazygit mode](docs/examples/screenshots/right-panel-lazygit-mode-dracula.png)
- [Right panel mode switcher](docs/examples/screenshots/right-panel-mode-switcher-dracula.png)

## Suggested Implementation Direction

- Build the shell as a native macOS app.
- Use SwiftUI for high-level layout where it fits naturally.
- Use AppKit where lower-level windowing, focus, terminal embedding, or split-view behavior needs more control.
- Embed terminals through `libghostty`.
- Treat agent CLIs and CLI harnesses as user-owned executables resolved from settings or `PATH`; YAAW should launch and resume them, not reimplement them.
- Launch `nvim`, `vim`, or `vi` in the right panel for file editing rather than building a custom editor for the MVP.
- Launch `lazygit`, with `git diff` fallback, in the right panel for Git workflows rather than building a custom source control UI for the MVP.
- Persist project, thread, selected agent CLI, and CLI session identity metadata locally.
- Treat the selected agent CLI, CLI session identity, terminal process, and working directory as part of the thread model.
- Treat panel dimensions as first-class layout state.
- Keep file indexing shallow and responsive for the MVP; add deeper indexing later only if needed.

## Non-Goals For The First Version

- Agent harness behavior.
- Bundled agent runtime, hosted agent service, or replacement agent CLI.
- Multi-agent orchestration.
- Prompt or tool-call mediation.
- Full code editor features.
- Custom text editor implementation.
- Multi-pane editor layouts.
- Custom source control UI.
- Extension marketplace.
- Remote development.
- Multi-agent orchestration beyond one bound CLI agent session per thread.
- Deep semantic code indexing.

## Open Design Questions

These are tracked as decision records under [`docs/decisions/`](docs/decisions/). Each record names a recommended default the implementation plans assume until the decision is finalized.

- [001 — Archived Thread Scrollback Retention](docs/decisions/001-archived-thread-scrollback.md)
- [002 — Project Metadata Location](docs/decisions/002-project-metadata-location.md)
- [003 — Global Project Thread Behavior](docs/decisions/003-global-project-thread-behavior.md)

## Documentation

Read these documents in order:

1. [README](README.md)
2. [User Guide](docs/user-guide/README.md)
3. [Technical Requirements](docs/requirements/technical-requirements.md)
4. [Non-Functional Requirements](docs/requirements/non-functional-requirements.md)
5. [Testing Requirements](docs/requirements/testing-requirements.md)
6. [Design](docs/design/README.md)

Implementation plans should be written after the requirements documents and should reference the applicable requirement ids or sections.

## Documentation Site

The GitHub Pages site is published from `.github/workflows/docs.yml`. The workflow stages the durable Markdown documentation and overlays the site shell from `docs/site/`.

- Keep long-lived product content in `docs/`, not `docs/site/`.
- Keep `docs/site/` limited to Pages presentation files: layouts, CSS, config, and the homepage.
- Add screenshots and other documentation assets under `docs/examples/` or the relevant `docs/` subdirectory so both Markdown docs and the Pages site can reference the same files.
- Local Jekyll staging folders, `.pages/` and `_site/`, are ignored and should not be committed.
