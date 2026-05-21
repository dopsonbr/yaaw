# Plan 04: Layout Shell

## Summary

Replace fixed Hello World panels with the real native macOS layout shell: collapsible and resizeable sidebar, central workspace, right tool panel, selected-thread bottom terminal region, and a visible entry point for archived threads. This plan also owns persisting panel sizes and collapsed states (additive migration on top of [Plan 02](02-sqlite-persistence.md)).

## Requirements

- Technical Requirements: App Layout, Right Tool Panel, Global Navigation, Theme.
- Non-Functional Requirements: Responsiveness, Accessibility, Usability, Maintainability.
- Testing Requirements: E2E Scope, Screenshot Requirements.
- Standards: SwiftUI Standard, AppKit Standard.

## Implementation

- Implement the main app layout with native macOS split behavior where SwiftUI is sufficient.
- Use AppKit behind a narrow bridge only where SwiftUI does not provide acceptable resize/collapse behavior.
- Add a collapsible sidebar, collapsible right tool panel, and collapsed-by-default selected-thread bottom terminal.
- Sidebar MUST include a visible archive entry point (e.g. an "Archived" disclosure section or a dedicated row) so threads archived in [Plan 03](03-project-thread-workflows.md) remain reachable. Archived threads stay grouped under their project.
- Add a SQLite migration (version `3`) for panel sizes and collapsed states: sidebar width, right-panel width, bottom-terminal height when expanded, sidebar collapsed flag, right-panel collapsed flag, bottom-terminal expanded flag.
- Persist layout state through that migration. Loading layout state MUST tolerate missing rows so a fresh database falls back to documented defaults.
- Keep terminal contents placeholder-backed in this plan.
- Apply Dracula tokens consistently to the layout shell, selection states, and resize handles.

## Tests

- Unit tests for layout state persistence against a real temporary SQLite file, including the missing-row default behavior.
- Unit tests for archive section visibility given an empty archive vs. a populated archive.
- UI-level or integration tests for collapse/expand action state.
- Screenshot-capable smoke coverage once the E2E harness exists (Plan 10).

## Acceptance Criteria

- Sidebar, main workspace, right panel, and selected-thread bottom terminal regions are visible in the app shell.
- Sidebar and right panel can collapse and expand.
- Selected-thread bottom terminal starts collapsed and toggles with `Cmd+J`.
- Archived threads remain reachable through a visible sidebar entry point.
- Major panel sizes and collapsed states persist across app relaunch via the new migration.
- Layout state remains independent from terminal implementation.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with layout-state coverage.
