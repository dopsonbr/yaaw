# Non-Functional Requirements

This document defines quality requirements for the first version of YAAW - Yet Another Agent Wrapper.

Requirements use:

- **MUST:** required for the first shippable version.
- **SHOULD:** expected unless cost or platform constraints make it impractical.
- **MAY:** allowed but not required.

## Performance

- The app MUST launch quickly on Apple Silicon hardware.
- The app MUST keep project/thread switching responsive while agent CLI session terminals are running.
- The app MUST keep panel resizing smooth enough to feel native.
- File indexing MUST NOT block the main UI thread.
- File search SHOULD return useful results interactively as the user types.
- The app SHOULD defer expensive indexing work until after the main window is usable.
- The app SHOULD avoid deep semantic indexing in the first version.

## Responsiveness

- Terminal input MUST remain responsive during file indexing and UI navigation.
- The app MUST avoid UI freezes when opening large repositories.
- The app MUST allow users to collapse or resize panels without waiting for file indexing to complete.
- Long-running background work SHOULD expose lightweight progress or idle state when useful.

## Reliability

- The app MUST preserve project, thread, agent CLI session, archive, and layout metadata across app restarts.
- The app MUST tolerate missing project directories and show a clear app-level state when a directory no longer exists.
- The app MUST tolerate missing external tools such as `codex`, `claude`, `copilot`, `opencode`, `nvim`, or `lazygit` when their corresponding adapter or panel is available.
- External tool errors MUST be visible without crashing the app.
- Agent CLI sessions and terminal sessions MUST remain isolated by thread while the app is running.
- The app SHOULD recover cleanly from terminal process exits.

## Data Integrity

- SQLite writes MUST be transactional for project, thread, agent CLI session, archive, index, and layout updates.
- The app MUST NOT write metadata into user project directories for the first version.
- The app MUST NOT modify repository files unless the user does so through a terminal tool such as `nvim`, shell commands, or `lazygit`.
- External-open detection and launch actions MUST NOT write app metadata into user project directories.
- File indexing MUST be read-only.
- YAML settings writes SHOULD be atomic.

## Security And Privacy

- The app MUST keep all first-version project and thread metadata local.
- The app MUST keep thread agent CLI selection and CLI session identity local.
- The app MUST keep thread activity status and notification previews local.
- The app MUST NOT collect telemetry or analytics.
- The app MUST NOT upload crash reports, diagnostics, logs, settings, indexes, activity previews, or usage events.
- The app MUST NOT send project paths, file names, terminal output, agent CLI session metadata, or repository content to a remote service outside of the user's chosen local CLI process.
- The app MUST sanitize notification previews before storing or displaying them and MUST NOT treat notification support as permission to persist full terminal scrollback.
- The app itself MUST NOT require network access for core first-version workflows outside of any network behavior performed by the user's chosen local CLI process.
- The app MUST leave agent authentication, model configuration, approval behavior, and tool execution inside the user's chosen local CLI process.
- The app MUST use the user's local shell and local tools.
- The app SHOULD avoid storing terminal scrollback unless explicitly added in a later plan.

## Accessibility

- The app SHOULD support macOS keyboard navigation for primary workflows.
- The app SHOULD expose a Settings key binding editor backed by the same YAML settings file as startup configuration.
- The app SHOULD make all visible stable actions configurable as keyboard shortcuts, with contextual or destructive actions unbound by default.
- The app SHOULD expose meaningful accessibility labels for sidebar items, right-tool-panel mode controls, right-side-area resize handles, and terminal regions.
- The app SHOULD preserve sufficient contrast using the selected built-in palette.
- The app SHOULD support system text scaling where practical without breaking the panel layout.

## Usability

- The app MUST make the active project and thread visible.
- The app MUST make each thread's selected agent CLI visible when starting or inspecting a thread.
- The app SHOULD make each active thread's latest activity state visible in the sidebar.
- The app MUST make the active right-tool-panel mode visible.
- The app MUST keep Files, `nvim`, and Git mode controls available in the right tool panel.
- The app MUST use familiar shortcuts for global back/forward navigation.
- The app MUST use `Cmd+J` for the selected-thread bottom terminal.
- The app SHOULD use native macOS defaults where they fit, including `Cmd+,` for Settings, `Cmd+N` for new project, and `Cmd+S` for saving settings edits.
- The app SHOULD remember the user's last selected project, thread, panel layout, main/right swap state, and right-tool-panel mode.
- The app SHOULD avoid modal workflows except for project creation, settings inspection, and destructive confirmations.

## Compatibility

- The app MUST support Apple Silicon only for the first version.
- The app MUST target the latest macOS release only.
- The app MUST support local directories and local worktrees.
- The app SHOULD work with common local Git repositories without requiring project-specific setup.
- The app SHOULD tolerate repositories without Git history.

## Maintainability

- The implementation MUST keep app state, terminal management, file indexing, and UI layout concerns separated.
- Theme colors SHOULD be centralized as shared theme tokens.
- SQLite schema changes SHOULD be versioned through migrations.
- YAML settings parsing SHOULD tolerate unknown or malformed values safely.
- Agent CLI terminal integrations SHOULD share common lifecycle management where possible.
- CLI-specific launch and resume behavior SHOULD be isolated behind a small terminal/session boundary rather than mixed into UI layout code.

## Testability

- The app MUST prioritize E2E tests that validate user-visible behavior.
- The app MUST support screenshot capture for E2E failures and key UI states.
- The app SHOULD include one high-level no-mock E2E journey through the full app workflow.
- The app SHOULD include focused E2E tests for project/thread storage, agent CLI selection and resume, file indexing, fuzzy matching, right-tool-panel modes, terminal launch, editor fallback, Git fallback, panel collapse, resize, paste behavior, and shortcut handling.
- Unit tests MAY be added for high-value input/output behavior, but they MUST NOT test internals or private functions.

Detailed testing expectations are defined in [Testing Requirements](testing-requirements.md).

## Observability

- The app SHOULD provide local diagnostic logs for app lifecycle, project/thread state changes, agent CLI launch or resume failures, terminal launch failures, indexing failures, and SQLite errors.
- Logs MUST remain local.
- Diagnostics MUST remain local and MUST NOT be uploaded automatically.
- Logs MUST avoid capturing sensitive terminal content unless explicitly enabled in a later implementation plan.
- External tool failures SHOULD preserve the original command and exit status where practical.

## Packaging

- The app SHOULD package as a standard macOS `.app`.
- The first version SHOULD assume supported agent CLIs, agent CLI harnesses, and preferred terminal tools are user-installed tools resolved from settings or `PATH`, while falling back to `vim`/`vi` and `git diff` where specified.
- The app SHOULD make missing tool failures visible in the relevant terminal panel.
- The app itself MUST NOT require network setup or cloud authentication for core workflows outside of any authentication required by the user's chosen local CLI process.
- The app package MUST NOT include a telemetry SDK or analytics endpoint configuration.

## Non-Goals

- Cross-platform support.
- Intel Mac support.
- Remote development.
- Cloud sync.
- Telemetry, analytics collection, or remote diagnostic upload.
- Multi-user collaboration.
- Built-in source control UI.
- Built-in text editor.
- Persistent live PTY sessions after app restart.
- Agent orchestration beyond one bound CLI agent session per thread.
- Agent harness behavior, prompt orchestration, or tool-call mediation.
- Bundled agent runtime or hosted agent service.
