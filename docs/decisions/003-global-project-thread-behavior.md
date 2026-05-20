# 003: Global Project Thread Behavior

- **Status:** Open
- **Affects:** [Plan 03](../plans/03-project-thread-workflows.md), [Plan 07](../plans/07-agent-cli-session-binding.md).

## Context

The built-in `global` project is scoped to the user's home directory. The original README "Open Design Questions" entry asked whether global threads should behave exactly like project threads or remain a separate lightweight list.

## Options

1. **Same behavior.** Global threads are normal threads with the home directory as working directory. Same CLI binding, archive behavior, resume.
2. **Lightweight list.** Global threads cannot be archived, do not require CLI session identity persistence, and may share a single terminal.

## Recommended Default

Option 1 unless option 2's UI simplification turns out to matter. Option 1 reuses everything from [Plan 03](../plans/03-project-thread-workflows.md) and [Plan 07](../plans/07-agent-cli-session-binding.md) without special cases.

## Consequences If Deferred

Plan 03 must assume one of these. If left open at implementation time, default to option 1 and revisit only if user feedback flags friction.
