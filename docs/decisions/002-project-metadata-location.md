# 002: Project Metadata Location

- **Status:** Open (leaning Accepted as option 1).
- **Affects:** [Plan 02](../plans/02-sqlite-persistence.md), [Plan 03](../plans/03-project-thread-workflows.md).

## Context

[Technical Requirements](../requirements/technical-requirements.md) says the app MUST keep project metadata in app-owned storage and MUST NOT write metadata into user project directories for the first version. The original README "Open Design Questions" entry asked whether some metadata should live inside the project directory for portability across machines.

## Options

1. **App-owned only.** All metadata in app SQLite + JSON config. No files written to project directories. Survives `git clean`. Does not survive moving the project root unless the user re-adds it.
2. **Hybrid.** A lightweight `.agent-ide/` (or similar) in the project root for portable per-repo state plus app-owned metadata for everything else.

## Recommended Default

Option 1 for the first version. Matches the current MUST. Reopen if portability across machines becomes a recurring user request.

## Consequences If Deferred

The MVP ships with option 1. Moving to a hybrid model later requires a sync boundary plan and an update to the requirement that forbids writing into project directories.
