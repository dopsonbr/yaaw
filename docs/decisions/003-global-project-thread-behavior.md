# 003: Global Project Thread Behavior

- **Status:** Accepted
- **Affects:** [Plan 03](../plans/03-project-thread-workflows.md), [Plan 07](../plans/07-agent-cli-session-binding.md).

## Context

The built-in `global` project uses a configurable global chats directory, defaulting to `~/yaaw`. The original README "Open Design Questions" entry asked whether global threads should behave exactly like project threads or remain a separate lightweight list.

## Options

1. **Same behavior.** Global threads are normal threads with the configured global chats directory as working directory. Same CLI binding, archive behavior, resume.
2. **Lightweight list.** Global threads cannot be archived, do not require CLI session identity persistence, and may share a single terminal.

## Recommended Default

Option 1, with two product guardrails: the global project sorts last, and startup/implicit new-thread actions do not open global chats by default. Users can still explicitly create global chats from the Global project row.

## Consequences If Deferred

Plan 03 must assume one of these. If left open at implementation time, default to option 1 and revisit only if user feedback flags friction.
