# Plan 09: Right Panel Tool Flows

## Summary

Wire the right panel into real terminal-backed tool flows for Files, `nvim`, and Git mode.

## Requirements

- Technical Requirements: Right Tool Panel, File Browser, nvim Mode, Git Mode, External Tools, Global Navigation.
- Non-Functional Requirements: Usability, Reliability, Accessibility.
- Testing Requirements: E2E Scope, Inputs And Outputs.
- Standards: nvim Standard, lazygit Standard, libghostty Standard.

## Implementation

- Keep right-panel state scoped to the selected thread.
- Switch modes through visible mode controls and `Cmd+Shift+[` / `Cmd+Shift+]`.
- Opening a file switches to `nvim` mode and launches `nvim <relative-file-path>` in the right-panel terminal.
- Opening Git mode launches `lazygit` in the selected thread working directory.
- Resolve `nvim` and `lazygit` from the user's `PATH`.
- Show raw terminal error output when external tools are missing or fail to launch.
- Do not implement a custom editor or source control UI.

## Tests

- Unit tests for mode-scoped state by thread.
- Unit tests for command construction using relative file paths.
- Integration tests for missing-tool behavior where safe.
- E2E coverage once the E2E harness exists.

## Acceptance Criteria

- Files, `nvim`, and Git modes are selectable in the right panel.
- Right-panel mode persists per thread.
- `Cmd+Shift+[` and `Cmd+Shift+]` cycle right-panel modes.
- Opening a file launches `nvim <relative-file-path>` inside the right panel.
- Git mode launches `lazygit` inside the right panel.
- Missing or failing tools show raw terminal error output.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with right-panel flow coverage.
