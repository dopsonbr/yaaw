# 001: Archived Thread Scrollback Retention

- **Status:** Open
- **Affects:** [Plan 03](../plans/03-project-thread-workflows.md), [Plan 07](../plans/07-agent-cli-session-binding.md), [Plan 11](../plans/11-polish-hardening.md).

## Context

Archived threads MUST retain agent CLI selection and CLI session identity (see [Technical Requirements](../requirements/technical-requirements.md)). Whether they should also retain visible terminal scrollback and command history beyond the CLI resume metadata is unresolved.

[Non-Functional Requirements](../requirements/non-functional-requirements.md) says the app SHOULD avoid storing terminal scrollback unless explicitly added in a later plan. Retaining scrollback per archived thread adds storage and privacy considerations.

## Options

1. **Resume metadata only.** Archived threads keep CLI session identity. Scrollback is whatever the CLI itself replays on resume.
2. **App-level scrollback capture.** The app stores per-thread terminal scrollback locally so reopening a thread shows historical output even before the CLI resumes.
3. **Hybrid.** Capture a bounded recent buffer (e.g. last N lines) but not full scrollback.

## Recommended Default

Option 1, until a concrete user workflow forces otherwise. The MVP ships with option 1.

## Consequences If Deferred

Adding option 2 or 3 later requires a schema migration and a privacy review. No work in Plans 01–11 needs to change to keep option 1 the default.
