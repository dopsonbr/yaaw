# Plan 02: SQLite Persistence

## Summary

Replace the in-memory placeholder store with an app-owned SQLite database that persists exactly what Plan 01 produces, plus the YAML settings boundary. Later plans add additive migrations as they produce new durable state.

## Requirements

- Technical Requirements: Storage, SQLite, JSON Configuration, Projects, Threads.
- Non-Functional Requirements: Reliability, Data Integrity, Maintainability.
- Testing Requirements: Unit Test Policy, Mocking Policy.

## Scope Boundary

This plan persists only state that Plan 01 produces. The schema is designed to be extended by later plans:

- **Plan 03** adds `agent_cli` per thread.
- **Plan 04** adds panel sizes and collapsed states.
- **Plan 07** adds CLI session identity and canonical session name per thread.
- **Plan 08** adds file-index metadata.

Each later plan adds its own migration. This plan MUST NOT introduce columns or tables that have no producer yet.

## Implementation

### SQLite

- Add a SQLite database service under `src/Persistence/` with explicit migration versions. Version `1` is the migration this plan introduces.
- Store, in migration 1:
  - Projects (id, display name, root directory, created at, last opened at).
  - Threads (id, display name, project id, working directory, created at, last opened at, archived flag).
  - Last selected project.
  - Last selected thread.
  - Right-panel mode per thread.
- Use a single SQLite file in the app-owned application support directory. Keep the database path injectable so tests can use temporary databases.
- Use transactions for any multi-record write (e.g. creating a project + its first thread atomically).
- Replace the existing in-memory snapshot loader with a SQLite-backed implementation behind the same store boundary so Plan 01 callers do not change.
- Keep all metadata in app-owned storage. The app MUST NOT write metadata into user project directories (see [Decision 002](../decisions/002-project-metadata-location.md)).

### JSON Configuration

- Add a YAML settings boundary under `src/Persistence/` separate from the SQLite store.
- Migration `1` of the YAML settings seeds Dracula as the only active theme value and seeds the default ignore rules referenced by [Plan 08](08-file-browser-fuzzy-search.md).
- Parse unknown or malformed values safely. The app MUST continue to launch when the YAML settings file is corrupt by falling back to defaults and logging a recovery event.
- Write YAML settings atomically (write to a temp file in the same directory, then rename).
- Keep the YAML settings path injectable for tests.

## Tests

- Migration tests verify a fresh database initializes to schema version 1.
- Repository tests verify projects, threads, archive state, last-selection, and right-panel modes survive store reinitialization against a real temporary SQLite file.
- Transaction tests verify a failed multi-record write does not leave partial state.
- YAML settings tests verify default seeding, atomic write, recovery from a malformed file, and round-trip read/write against a real temporary path.

## Acceptance Criteria

- App state loads from and saves to a real app-owned SQLite database at the injected path.
- Migration version 1 creates exactly the tables/columns listed above and no others.
- Project, thread, archive, last-selection, and right-panel mode records survive store reinitialization.
- The YAML settings boundary exists at an injectable path with Dracula seeded as the theme and default ignore rules seeded for later use.
- A malformed YAML settings file does not prevent app launch and is recovered to defaults with a logged event.
- Tests use real temporary SQLite files and real temporary YAML settings paths, not mocks.
- No implementation writes metadata into project directories.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with persistence coverage.
