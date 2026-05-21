# Scripts

This directory contains the canonical command-line workflow for the SwiftPM
scaffold.

## Commands

- `build.sh`: run `swift build`.
- `run.sh`: run `swift run YAAW`.
- `install.sh`: build a release-style `YAAW.app`, install it to `/Applications`, and install `yaaw` on `PATH`. Use `scripts/install.sh --test-install` for a non-sudo test install under `.build/install-test/`.
- `test.sh`: run `swift test`.
- `test-e2e.sh`: run the script-backed E2E behavior harness and launch the real `.app` for visual screenshots.
- `check.sh`: run build and tests together.

`script/build_and_run.sh --verify` remains the local app-bundle verification workflow. Set `YAAW_BUILD_CONFIGURATION=release` or use `scripts/install.sh` when you need a release-built bundle. For custom non-sudo install destinations, pass `--no-sudo --app-dir <writable-dir> --bin-dir <writable-dir>`.

Future formatting scripts should stay script-backed and command-line first.
