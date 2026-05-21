# Technical Requirements

This document defines implementation requirements for the first version of YAAW - Yet Another Agent Wrapper.

Requirements use:

- **MUST:** required for the first shippable version.
- **SHOULD:** expected unless cost or platform constraints make it impractical.
- **MAY:** allowed but not required.

## Platform

- The app MUST target Apple Silicon Macs.
- The app MUST target the latest macOS release only.
- The app MUST be distributed as a native macOS app.
- The app MUST NOT require Intel Mac support for the first version.
- The app SHOULD use platform-native windowing, keyboard handling, focus behavior, menus, and accessibility hooks.

## Application Stack

- The app SHOULD be implemented with Swift as the primary application language.
- The app SHOULD use SwiftUI for high-level app structure, sidebar lists, modal sheets, simple controls, and static layout.
- The app SHOULD use AppKit where SwiftUI is not sufficient for terminal embedding, split-view behavior, focus routing, or lower-level macOS window control.
- The app MUST use SQLite for app-owned structured state such as projects, threads, indexes, archives, and layout state.
- The app MUST use a YAML file for user-editable or portable configuration.
- The app MUST keep project metadata in app-owned storage rather than writing metadata into project directories.
- The app MUST keep live terminal process state in memory while running and MUST NOT require restoring live PTY processes after restart.
- The app MUST persist the agent CLI session metadata needed to resume each thread's bound CLI agent session after the app or thread is reopened.
- The app MUST remain a desktop wrapper around local CLIs and MUST NOT become an agent harness, prompt orchestrator, or tool-call proxy.

## Storage

### SQLite

The SQLite database MUST store:

- Projects.
- Threads.
- Thread-to-project relationships.
- Thread working directories.
- Thread agent CLI selection.
- Thread agent CLI session identity.
- Thread canonical CLI session name.
- Archive state.
- Last selected project.
- Last selected thread.
- Right-panel mode per thread.
- Panel collapsed states.
- Panel sizes.
- File index metadata.

The database SHOULD store enough metadata to restore the app layout and navigation context after restart.

### YAML Configuration

YAML configuration MUST be used for settings that should remain easy to inspect or edit outside the app.

YAML configuration MUST live in app-owned storage by default at `~/Library/Application Support/YAAW/settings.yaml`.

YAML configuration MUST include comments that show defaults and identify settings that are represented but not changeable yet.

YAML configuration SHOULD include:

- Theme selection, initially fixed to Dracula.
- File indexing ignore rules.
- Keyboard shortcuts.
- Default agent CLI.
- Editor, Git, diff, and agent command overrides.
- User-level app preferences.

The app MUST expose a settings action in the window title bar that opens the YAML settings file and reloads settings after manual edits.

## Projects

- A project MUST represent a named local directory.
- The built-in `global` project MUST be scoped to the user's home directory.
- Each project MUST have a stable id, display name, root directory, created timestamp, and last opened timestamp.
- A project MAY have multiple threads.
- A project MAY have threads that point at different worktrees.

## Threads

- A thread MUST belong to one project.
- A thread MUST be bound to exactly one managed agent CLI session.
- A thread MUST store `agent_cli` as the selected CLI family.
- The product direction MUST include `codex`, `claude`, `copilot`, and `opencode` as CLI families.
- The currently implemented adapter set MAY be smaller than the full product direction while adapters are added incrementally.
- A thread MUST store the CLI session identity needed to resume the exact bound agent CLI session.
- A thread MUST have a stable id, display name, project id, working directory, `agent_cli`, CLI session identity, created timestamp, last opened timestamp, and archive state.
- A thread display name MUST be derived from the bound CLI session's reported name, title, or id.
- A thread working directory MAY be the project root or a separate worktree directory.
- A thread MUST NOT switch from one CLI family to another after it is created.
- New thread creation MUST ask the user which available CLI family to start.
- New thread creation MUST launch the selected agent CLI in the thread working directory.
- Reopening a thread MUST invoke the matching CLI resume behavior for the stored session identity.
- Each thread MUST own one agent CLI session terminal while the app is running.
- Live thread terminal sessions MUST NOT be required to persist after app restart.
- Thread terminal/session state MUST be preserved while the app process is running.
- Archived threads MUST move out of the primary active thread list.
- Archived threads MUST retain the agent CLI selection and CLI session identity required for later resume.

## Terminal Requirements

- Every embedded terminal surface MUST use `libghostty`.
- The app MUST provide one agent CLI session terminal per active thread.
- The app MUST provide one selected-thread bottom terminal.
- The app MUST provide a right-panel terminal for `nvim`, falling back to `vim` and then `vi`.
- The app MUST provide a right-panel terminal for `lazygit`, falling back to `git diff`.
- Agent CLI session terminals MUST launch in the selected thread's working directory.
- Agent CLI session terminals MUST invoke the selected local CLI according to the selected thread's stored `agent_cli`.
- Agent CLI session terminals MUST resume the selected thread's stored CLI session identity when reopening an existing thread.
- The bottom terminal MUST launch in the selected thread's working directory.
- The `nvim` terminal MUST launch in the selected thread's working directory.
- The `lazygit` terminal MUST launch in the selected thread's working directory.
- Terminal sessions MUST preserve runtime state while the app is open.
- Live PTY processes MUST NOT be restored after app restart for the first version.
- SQLite MUST persist terminal metadata, agent CLI resume metadata, and layout state, not live PTY process state.

## App Layout

- The app MUST have a left project/thread sidebar.
- The app MUST have a central agent CLI session terminal area.
- The app MUST have a right tool panel.
- The app MUST have a selected-thread bottom terminal.
- The left sidebar MUST be collapsible.
- The right tool panel MUST be collapsible.
- The bottom terminal MUST be collapsed by default per thread.
- The bottom terminal MUST toggle with `Cmd+J`.
- Toggling or resizing the bottom terminal MUST NOT mutate sidebar width, sidebar collapse state, project selection, thread selection, or left-panel content.
- Every major panel MUST be resizeable.
- Panel size and collapsed state SHOULD persist across app restarts.

Resizeable panels:

- Sidebar width.
- Main agent CLI session terminal width.
- Right tool panel width.
- Global terminal height when expanded.

## Right Tool Panel

The right tool panel MUST be scoped to the selected thread.

The right tool panel MUST provide three modes:

- Files.
- `nvim`.
- Git.

Users MUST be able to switch right-panel modes by clicking mode icons or tabs.

Users MUST be able to cycle right-panel modes with:

- `Cmd+Shift+[`
- `Cmd+Shift+]`

The selected right-panel mode MUST be stored per thread.

If two threads happen to share the same panel state because they point at the same working directory, that behavior is acceptable but MUST NOT be required.

## File Browser

- Files mode MUST show the selected thread's working directory.
- Hidden files MUST be shown by default.
- Files mode MUST support fuzzy matching.
- Files mode MUST ignore obviously heavy directories by default.
- Ignore rules SHOULD include `.git`, `node_modules`, `dist`, `.build`, and derived-data folders.
- File search SHOULD prefer exact filename matches, then prefix matches, then fuzzy path matches.
- Opening a file MUST switch the right panel to `nvim` mode.
- Opening a file MUST launch `nvim <relative-file-path>` in the right-panel terminal.

## nvim Mode

- `nvim` mode MUST run inside the right panel.
- `nvim` mode MUST use the selected thread's working directory.
- `nvim` mode MUST NOT open a separate app window.
- `nvim` mode MUST use an embedded `libghostty` terminal.
- The app MUST NOT implement a custom text editor for the first version.

## Git Mode

- Git mode MUST run `lazygit` inside the right panel when it is available.
- Git mode MUST use the selected thread's working directory.
- Git mode MUST NOT open a separate terminal window.
- Git mode MUST use an embedded `libghostty` terminal.
- `lazygit` MUST be detected from the user's `PATH`.
- If `lazygit` is not installed, Git mode MUST fall back to `git diff`.
- The app MUST NOT implement a custom source control UI for the first version.

## Global Navigation

The app MUST support browser-style global navigation:

- Back: `Cmd+[`
- Forward: `Cmd+]`

Global navigation SHOULD move across recent project/thread selections and major app locations.

Right-panel tab cycling MUST use `Cmd+Shift+[` and `Cmd+Shift+]` so it does not conflict with global navigation.

## Theme

- The app MUST use the Dracula theme across all app surfaces.
- The first version MUST NOT require theme switching.
- Terminals, sidebar, right panel, modal sheets, split-view handles, icons, file tree, `nvim`, and `lazygit` surfaces MUST use the Dracula visual system.
- The implementation SHOULD use shared theme tokens rather than hardcoding colors throughout the app.

## Agent CLI Scope

- The first version MUST manage thread sessions through terminal-backed local CLI agent processes.
- Each thread MUST be tied to exactly one CLI agent session.
- The app MUST ask which agent CLI to invoke when starting a new thread.
- The app MUST use the selected CLI session's reported name, title, or id as the canonical thread display name.
- Closing and reopening a thread MUST resume the associated agent CLI session.
- The app MUST NOT require users to manually run the selected CLI or resume commands for normal thread creation or reopening.
- The app MUST NOT orchestrate multiple agent CLI sessions inside one thread for the first version.
- The app MUST NOT mediate prompts, tool calls, model behavior, or agent decisions beyond launching and resuming the user's selected local CLI.

## External Tools

- `nvim` SHOULD be detected from the user's `PATH`.
- `codex`, `claude`, `copilot`, and `opencode` SHOULD be detected from the user's `PATH` when their corresponding adapter is available.
- `lazygit` MUST be detected from the user's `PATH`.
- External tool failures MUST be visible in the embedded terminal surface.
- Agent CLI launch or resume failures MUST be visible in the thread's agent CLI session terminal.
- The first version SHOULD avoid bundling external CLI tools unless packaging later requires it.

## Acceptance Criteria

- A user can create a project from a local directory.
- A user can create multiple threads under a project.
- Creating a thread asks the user which available CLI family to invoke.
- Each thread is bound to exactly one stored CLI agent session.
- A thread's visible name matches the bound CLI session's reported name, title, or id.
- Closing and reopening a thread resumes the stored CLI session identity.
- A thread can point at a project root or a separate worktree.
- Each running thread has one agent CLI session terminal.
- The selected-thread bottom terminal is collapsed by default and toggles with `Cmd+J`.
- The sidebar, right tool panel, and bottom terminal are resizeable.
- The right tool panel is scoped to the active thread.
- The right tool panel can switch between Files, `nvim`, and Git.
- `Cmd+Shift+[` and `Cmd+Shift+]` cycle right-panel modes.
- `Cmd+[` and `Cmd+]` perform global back/forward navigation.
- Hidden files appear in the file browser by default.
- Opening a file launches `nvim`, `vim`, or `vi` inside the right panel.
- Opening Git mode launches `lazygit` or `git diff` inside the right panel.
- `lazygit` is resolved from `PATH`, with `git diff` fallback when unavailable.
- Project, thread, agent CLI session, index, archive, and layout metadata are stored in SQLite.
- User-editable configuration is stored in YAML.
