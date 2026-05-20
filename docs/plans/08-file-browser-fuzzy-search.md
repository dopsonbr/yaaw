# Plan 08: File Browser And Fuzzy Search

## Summary

Replace sample file entries with a read-only file browser for the selected thread working directory, including hidden files, ignore rules, and fuzzy search.

## Requirements

- Technical Requirements: File Browser, Right Tool Panel, Storage.
- Non-Functional Requirements: Performance, Responsiveness, Data Integrity.
- Testing Requirements: Unit Test Policy, Test Data.

## Implementation

- Index files from the selected thread working directory without blocking the main UI thread.
- Show hidden files by default.
- Ignore heavy directories by default, including `.git`, `node_modules`, `dist`, `.build`, and derived-data folders. The default ignore list lives in the JSON config seeded by [Plan 02](02-sqlite-persistence.md).
- Add deterministic ranking: exact filename matches, prefix matches, then fuzzy path matches.
- Keep indexing read-only and never modify repository files.
- Add a SQLite migration for file-index metadata (per-thread root path, last index timestamp, file count, and any other coarse stats useful for invalidation). Actual file entries do not need to be persisted; they MUST be safe to rebuild on demand. The migration version number is the next unused integer at the time this plan ships (the prior plans land migrations 1–4).

## Tests

- Unit tests for ignore-rule evaluation against the seeded default list.
- Unit tests for path normalization.
- Unit tests for fuzzy ranking order.
- Temporary-directory tests using deterministic fixture files, including hidden files.
- Migration test verifies the file-index metadata table initializes correctly on a fresh database and on an upgrade from the prior schema version.

## Acceptance Criteria

- Files mode shows the selected thread working directory.
- Hidden files are visible by default.
- Heavy ignored directories are skipped per the JSON-config default list.
- File search returns exact filename matches before prefix matches and fuzzy path matches.
- File indexing does not block primary UI state changes.
- File indexing is read-only.
- File-index metadata persists across app relaunch and is safe to rebuild from scratch.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with file browser and fuzzy search coverage.
