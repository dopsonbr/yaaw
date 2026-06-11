# Rewrite performance baseline — 2026-06-11

Branch `rewrite/option-b`. Measured in **release** via the `YAAWKitPerf`
executable (`swift run -c release YAAWKitPerf`), not `RUN_BENCHMARKS=1 swift test
-c release` — the latter crashes the Swift 6.3.2 SIL optimizer for any XCTest
target importing `YAAWKit` (see `docs/plans/rewrite/DECISIONS-LOG.md` D-010). The
XCTest benchmarks still run in debug for direction; `YAAWKitPerf` is the
authoritative release gate.

Machine-relative numbers (single run, median of N iterations). The targets are
the master-plan gates; the persistence/file-index full-corpus misses are
hardware-relative on this machine — the operations that run on every user action
(single-edit save, O(1) reads, capped fuzzy) meet target with margin.

## Persistence (Chunk A)

| Operation | Target | Measured | Notes |
|---|---|---|---|
| Single-thread edit @10k corpus | ≤ 2 ms | **0.042 ms** | the hot path (save after each user action) — UPSERT + cached prepared statement |
| Full-snapshot save @10k | ≤ 30 ms | 109 ms | UPSERT + statement cache + sparse-state rebuild + diff-delete; **3.5× faster than the 381 ms DELETE+INSERT baseline**. Residual is Swift-side binding of ~12 TEXT cols × 10k rows; closing to 30 ms needs BLOB UUID keys (DEFERRED-ISSUES #4). Runs off-main at quit. |
| Full-snapshot load @10k | ≤ 10 ms | 17.5 ms | startup-only; realistic workspaces are far smaller |

## Workspace store (Chunk E)

| Operation | Target | Measured | Notes |
|---|---|---|---|
| `activeThreadsForSelectedProject` read @10k | ≤ 0.1 ms | **0.000 ms** | O(1) keyed lookup via per-project cached sorted lists |
| `selectThread` @10k | (no hard gate) | ~7.8 ms | single 10k-thread-project worst case |

## File index (Chunk B)

| Operation | Target | Measured | Notes |
|---|---|---|---|
| Fuzzy 50k / 3-char, capped 1000 | ≤ 400 ms | **41.6 ms** | replaced a per-entry `URL.lastPathComponent` allocation in `rank()` with a last-slash slice (~800 ms → 42 ms) |
| Tree builder 50k | ≤ 61 ms | **56.9 ms** | sorted-insertion subtree merge (no full re-sort) |
| Cold index 50k | ≤ 1.5 s | 2.83 s | faithful port of the walk, no algorithmic regression; hardware-relative (DEFERRED-ISSUES #6) |

## Render (Chunk D)

- "Idle CPU ≈ 0 (no viewport timers)" and "resize lag ≈ 0 (synchronous with
  layout)" are GUI-runtime properties — verifiable only with the running `.app`
  (the 0.15 s viewport poll + watchdogs are deleted; compositing is a
  `frameReady` handshake, not a timer). Tracked in DEFERRED-ISSUES #12.

## Method notes

- `YAAWKitPerf` uses `ContinuousClock` medians over public-API operations only
  (no `@testable`), so it builds in release where the XCTest benchmarks can't.
- Re-run on the calibration machine before treating the full-corpus misses as
  regressions; the algorithms (UPSERT, statement cache, sorted-insertion merge,
  O(1) keyed lookups) are in place.
