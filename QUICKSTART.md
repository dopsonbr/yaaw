# Quickstart

This repo is a SwiftPM-only native macOS scaffold for Agent IDE. Use the
repository scripts for build, run, and test workflows.

## Requirements

- Apple Silicon Mac.
- Latest local macOS and command-line Swift toolchain. `Package.swift` pins the platform to `.macOS(.v26)`; older macOS versions will fail to build by design (see the latest-macOS-only stance in [Technical Requirements](docs/requirements/technical-requirements.md)).
- No Xcode project is required.

## Commands

Build:

```sh
scripts/build.sh
```

Run the Hello World app shell:

```sh
scripts/run.sh
```

Run the base test suite:

```sh
scripts/test.sh
```

Run build and tests together:

```sh
scripts/check.sh
```

## Layout

- `Package.swift` defines the `AgentIDE` executable and `AgentIDEKit` library.
- `src/App/` contains the thin SwiftUI app entrypoint and root composition.
- `src/Core/`, `src/Projects/`, `src/Threads/`, `src/RightPanel/`,
  `src/FileBrowser/`, `src/Persistence/`, `src/Terminal/`, and `src/Theme/`
  contain compile-ready Hello World placeholders.
- `src/Tests/AgentIDEKitTests/` contains public behavior tests.
