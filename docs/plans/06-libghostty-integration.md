# Plan 06: libghostty Integration

## Summary

Implement embedded terminal rendering with `libghostty` behind the terminal abstraction from Plan 05.

## Requirements

- Technical Requirements: Terminal Requirements, nvim Mode, Git Mode, External Tools.
- Non-Functional Requirements: Responsiveness, Reliability, Packaging.
- Standards: libghostty Standard, AppKit Standard.

## Implementation

- Add the `libghostty` bridge behind the terminal abstraction without changing public app-state APIs.
- Embed project terminal and global terminal surfaces first.
- Embed right-panel `nvim` and `lazygit` terminal surfaces after project/global terminals are stable. YAAW-side `codex` / `claude` launch and resume behavior for user-provided CLIs is owned by [Plan 07](07-agent-cli-session-binding.md); this plan only renders the surface.
- Launch project terminals in the selected thread working directory.
- Launch the global terminal in the user's home directory.
- Preserve terminal runtime state while the app process is open.
- Do not restore live terminal processes after app restart.

## libghostty Consumption Surface

`libghostty` is the highest-risk integration in the project. Before coding starts, this plan MUST resolve the following and capture the answer in the plan PR description so reviewers can verify the choice:

1. **Distribution form.** Pick one: (a) Swift Package from upstream Ghostty, (b) vendored `xcframework` built locally from Ghostty source, (c) Homebrew/system library linked at build time. Default recommendation: (b) vendored xcframework, because it gives reproducible builds without forcing every contributor to build Ghostty from source.
2. **Build prerequisites.** Document any one-time steps (Zig toolchain, Ghostty submodule checkout, framework build script) in `scripts/` so a new contributor can produce a working build with `scripts/build.sh`. If a separate `scripts/bootstrap.sh` is needed, add it here.
3. **AppKit bridge.** Define a narrow `NSViewRepresentable` (or `NSViewControllerRepresentable`) wrapper that owns the libghostty surface lifecycle. The wrapper MUST be the only place that touches libghostty types directly; everything else talks to the terminal abstraction from Plan 05.
4. **Threading model.** Confirm libghostty's main-thread expectations and document them in the bridge file. PTY I/O happens off the main thread; UI updates marshal back to main.
5. **Memory and process cleanup.** The bridge MUST tear down the underlying PTY process when the surface is removed from view. Closing the app MUST not leak child processes.
6. **Packaging implication.** If the distribution form requires bundling resources or signing entitlements, note them now so [Plan 11](11-polish-hardening.md) can pick them up without surprises.

## Tests

- Unit tests continue to use the placeholder terminal implementation.
- Integration smoke tests verify terminal surfaces can be created and attached.
- Manual smoke test verifies shell input works in project and global terminals.

## Acceptance Criteria

- Every embedded terminal surface uses `libghostty`.
- Project terminal launches in the selected thread working directory.
- Global terminal launches in the user's home directory.
- Terminal sessions remain isolated by thread while the app is open.
- Restarting the app does not attempt to restore live terminal processes.
- The libghostty distribution form, bridge boundary, threading model, and cleanup behavior are documented in the plan PR.
- `scripts/build.sh` passes for a contributor following the documented bootstrap steps.
- `scripts/test.sh` passes.
- A manual smoke run verifies visible project and global terminal surfaces and verifies no orphaned PTY processes remain after quitting the app.
