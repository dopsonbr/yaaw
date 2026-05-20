# Scripts

This directory contains the canonical command-line workflow for the SwiftPM
scaffold.

## Commands

- `build.sh`: run `swift build`.
- `run.sh`: run `swift run AgentIDE`.
- `test.sh`: run `swift test`.
- `test-e2e.sh`: run the script-backed E2E behavior harness and launch the real `.app` for visual screenshots.
- `check.sh`: run build and tests together.

Future formatting scripts should stay script-backed and command-line first.
