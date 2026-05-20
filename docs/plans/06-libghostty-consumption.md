# Plan 06 libghostty Consumption Notes

## Current Upstream Findings

- Official Ghostty docs describe Ghostty as a native terminal with GPU acceleration and point terminal API docs primarily at VT/control-sequence behavior: <https://ghostty.org/docs>.
- The Ghostty repository describes `libghostty` as the embeddable surface and says the current public split starts with `libghostty-vt`: <https://github.com/ghostty-org/ghostty>.
- The generated `libghostty-vt` API docs state that VT handles parsing, terminal state, input encoding, scrollback, wrapping, and resize reflow, but also warn that the API is still in development: <https://libghostty.tip.ghostty.org/>.
- Upstream has a SwiftPM example for `libghostty-vt` through a prebuilt XCFramework, produced with `zig build -Demit-lib-vt`: <https://github.com/ghostty-org/ghostty/tree/main/example/swift-vt-xcframework>.
- The full macOS embedding header exists in `include/ghostty.h`, but upstream comments still frame it as an embedding API used by Ghostty's macOS app rather than a stable general-purpose SDK: <https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h>.

## Distribution Form

Selected form: Swift Package wrapper that ships a prebuilt `libghostty` XCFramework.

Rationale:

- A Swift Package dependency only covers the `libghostty-vt` example path today, which is terminal state only and does not provide the full macOS terminal surface needed by this app.
- The official full-surface API exists in `include/ghostty.h`, but upstream does not currently publish it as a stable Swift Package product.
- Homebrew/system linking would make app startup depend on a contributor's machine state and would not describe what is packaged into the final app.
- `Lakr233/libghostty-spm` pins and distributes `GhosttyKit.xcframework` through SwiftPM and already provides a native AppKit/SwiftUI `TerminalSurfaceView` boundary.
- The app remains insulated behind `src/App/GhosttyTerminalSurfaceView.swift`, so Plan 11 can swap the package out for an upstream official package or a directly vendored XCFramework without changing `AppModel`, terminal roles, or persistence.

## Build Prerequisites

- No local Zig install is required for the current SwiftPM path.
- `scripts/build.sh` resolves `https://github.com/Lakr233/libghostty-spm.git` at `1.1.4`, downloads `GhosttyKit.xcframework.zip`, and builds the app.
- `scripts/bootstrap-libghostty.sh` is retained as an optional upstream-artifact bootstrap script for Plan 11 or for reviewers who want to compare the current package wrapper with a locally built Ghostty XCFramework.
- `script/build_and_run.sh` still copies `Vendor/Ghostty/**/Ghostty.framework` or `Vendor/Ghostty/**/libghostty.dylib` into the staged app bundle when present, but the current build does not require those files.

## Bridge Boundary

- `src/App/GhosttyTerminalSurfaceView.swift` is the only app-owned SwiftUI/AppKit boundary that attaches a Ghostty-backed terminal view.
- Direct `libghostty` calls live in the Swift Package dependency, not in app state or feature code.
- `RootView` only passes `TerminalLaunchRequest` values from `AppModel`; it does not touch libghostty types.
- Unit tests continue to use `PlaceholderTerminalSessionManager` and do not require a Ghostty framework.

## Threading Model

- Ghostty surface creation, resize, focus, text input, tick, and draw are handled by the package's AppKit terminal view on the main actor.
- The bridge does not expose PTY internals to SwiftUI. Ghostty owns the child process and terminal I/O behind the surface.
- Right-panel `nvim` and `lazygit` roles attach normal terminal surfaces, then send the configured command after the shell surface is available.

## Cleanup

- `GhosttyTerminalRuntime.closeAll()` releases retained app-owned terminal state when `NSApplication.willTerminateNotification` fires.
- Replacing a terminal role drops the prior state for that role.
- Removing a SwiftUI container detaches the retained host view but does not kill the role's terminal; this preserves runtime state while the app process remains open.

## Packaging Notes For Plan 11

- The final signed app should verify how SwiftPM embeds or links the `GhosttyKit.xcframework` binary artifact.
- Plan 11 should verify code signing and hardened runtime behavior for the embedded Ghostty artifact.
- Plan 11 should decide whether to keep `libghostty-spm`, switch to an official upstream Swift Package if one exists, or vendor the full Ghostty XCFramework directly.
