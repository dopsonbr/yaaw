# Plan 13 Agent Notifications And Thread Status

## Summary

Add a thread-scoped activity layer so CLI agents can tell YAAW when they are working, waiting for input, complete, or inactive. The feature stays terminal-backed: YAAW listens to terminal notifications and an app-owned helper command, but it does not inspect prompts, mediate tool calls, or write agent config into user repositories.

## Implementation Changes

- Add `ThreadActivityStatus` and latest `ThreadActivityState` per thread, with SQLite persistence for status, preview, unread state, notification title/body/source, and update time.
- Downgrade persisted `working` states to `inactive` on app launch because live terminal process state is runtime-only.
- Expose a `yaaw-notify` helper on `PATH` only inside managed agent terminals. It accepts `--status working|needs-input|complete|inactive`, `--title`, and `--body`, writes app-owned NDJSON through `YAAW_EVENT_LOG`, and emits OSC 777 for terminal-native notification compatibility.
- Route Ghostty desktop notification, focus, close, and command-finished callbacks into `AppModel`.
- Show per-thread sidebar indicators and previews; mark focused selected-thread notifications read; dispatch macOS notifications titled with the thread name and preview body when the app is not already focused on that thread.

## Test Plan

- Unit test status transitions, unread clearing, launch downgrade from `working` to `inactive`, helper-event parsing, and notification suppression.
- Unit test SQLite save/load and migration for thread activity state.
- Unit test agent terminal command wrapping for `YAAW_THREAD_ID`, `YAAW_PROJECT_ID`, `YAAW_EVENT_LOG`, helper `PATH`, and `yaaw-notify` installation.
- E2E coverage should use fixture agents that emit helper notifications and OSC notifications, then assert sidebar indicators, previews, unread clearing, and relaunch behavior.

## Acceptance Criteria

- Each active thread visibly shows one of `working`, `needs input`, `complete`, or `inactive`.
- Agent terminal notifications update the correct thread without changing the thread's CLI binding.
- `yaaw-notify` works from inside managed agent terminals and does not require project-directory metadata.
- System notification title is the thread name, with project/status subtitle and sanitized preview body.
- `scripts/test.sh` passes.
