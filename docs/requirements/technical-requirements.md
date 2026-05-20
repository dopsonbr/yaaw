# Technical Requirements

This document defines implementation requirements for the first version of the native macOS Agent IDE.

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
- The app MUST use JSON files for user-editable or portable configuration.
- The app MUST keep project metadata in app-owned storage rather than writing metadata into project directories.
- The app MUST keep terminal process/session state in memory while running and MUST NOT require restoring terminal processes after restart.

## Storage

### SQLite

The SQLite database MUST store:

- Projects.
- Threads.
- Thread-to-project relationships.
- Thread working directories.
- Archive state.
- Last selected project.
- Last selected thread.
- Right-panel mode per thread.
- Panel collapsed states.
- Panel sizes.
- File index metadata.

The database SHOULD store enough metadata to restore the app layout and navigation context after restart.

### JSON Configuration

JSON configuration MUST be used for settings that should remain easy to inspect or edit outside the app.

JSON configuration SHOULD include:

- Theme selection, initially fixed to Dracula.
- File indexing ignore rules.
- Tool command overrides, if later supported.
- User-level app preferences.

## Projects

- A project MUST represent a named local directory.
- The built-in `global` project MUST be scoped to the user's home directory.
- Each project MUST have a stable id, display name, root directory, created timestamp, and last opened timestamp.
- A project MAY have multiple threads.
- A project MAY have threads that point at different worktrees.

## Threads

- A thread MUST belong to one project.
- A thread MUST have a stable id, display name, project id, working directory, created timestamp, last opened timestamp, and archive state.
- A thread working directory MAY be the project root or a separate worktree directory.
- Each thread MUST own one project terminal while the app is running.
- Thread terminal sessions MUST NOT be required to persist after app restart.
- Thread terminal/session state MUST be preserved while the app process is running.
- Archived threads MUST move out of the primary active thread list.

## Terminal Requirements

- Every embedded terminal surface MUST use `libghostty`.
- The app MUST provide one project terminal per active thread.
- The app MUST provide one global terminal.
- The app MUST provide a right-panel terminal for `nvim`.
- The app MUST provide a right-panel terminal for `lazygit`.
- Project terminals MUST launch in the selected thread's working directory.
- The global terminal MUST launch in the user's home directory.
- The `nvim` terminal MUST launch in the selected thread's working directory.
- The `lazygit` terminal MUST launch in the selected thread's working directory.
- Terminal sessions MUST preserve runtime state while the app is open.
- Terminal sessions MUST NOT be restored after app restart for the first version.
- SQLite MUST persist terminal metadata and layout state, not live PTY process state.

## App Layout

- The app MUST have a left project/thread sidebar.
- The app MUST have a central project terminal area.
- The app MUST have a right tool panel.
- The app MUST have a bottom global terminal.
- The left sidebar MUST be collapsible.
- The right tool panel MUST be collapsible.
- The global terminal MUST be collapsed by default.
- The global terminal MUST toggle with `Cmd+J`.
- Every major panel MUST be resizeable.
- Panel size and collapsed state SHOULD persist across app restarts.

Resizeable panels:

- Sidebar width.
- Main project terminal width.
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

- Git mode MUST run `lazygit` inside the right panel.
- Git mode MUST use the selected thread's working directory.
- Git mode MUST NOT open a separate terminal window.
- Git mode MUST use an embedded `libghostty` terminal.
- `lazygit` MUST be detected from the user's `PATH`.
- If `lazygit` is not installed or fails to launch, the app MUST show the raw terminal error output.
- The app MUST NOT refine, rewrite, or replace the `lazygit` error message for the first version.
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

## Agent Scope

- The first version MUST be terminal-only.
- The app MUST NOT manage a specific agent CLI as a first-version requirement.
- The app MAY allow users to run any agent command manually inside a project terminal.
- New threads MUST NOT auto-run a specific agent command unless a later implementation plan adds that behavior.

## External Tools

- `nvim` SHOULD be detected from the user's `PATH`.
- `lazygit` MUST be detected from the user's `PATH`.
- External tool failures MUST be visible in the embedded terminal surface.
- The first version SHOULD avoid bundling external CLI tools unless packaging later requires it.

## Acceptance Criteria

- A user can create a project from a local directory.
- A user can create multiple threads under a project.
- A thread can point at a project root or a separate worktree.
- Each running thread has one project terminal.
- The global terminal is collapsed by default and toggles with `Cmd+J`.
- The sidebar, right tool panel, and global terminal are resizeable.
- The right tool panel is scoped to the active thread.
- The right tool panel can switch between Files, `nvim`, and Git.
- `Cmd+Shift+[` and `Cmd+Shift+]` cycle right-panel modes.
- `Cmd+[` and `Cmd+]` perform global back/forward navigation.
- Hidden files appear in the file browser by default.
- Opening a file launches `nvim` inside the right panel.
- Opening Git mode launches `lazygit` inside the right panel.
- `lazygit` is resolved from `PATH`, and launch errors are shown as-is.
- Project, thread, index, archive, and layout metadata are stored in SQLite.
- User-editable configuration is stored in JSON.
