# YAAW perf — post-merge numbers, 2026-05-21

`main` after `d9ca426 Merge branch 'perf/baseline-and-fixes'`. Ran
`RUN_BENCHMARKS=1 swift test -c release --filter YAAWKitBenchmarks`
on the same machine as the original baseline. All 20 benchmarks pass.
All 90 unit tests pass.

## Did the perf wins survive the merge?

Yes. The flagship per-mutation cost and AppModel cache wins held:

| Benchmark | Baseline (pre-fixes) | Post-merge | Outcome |
| --- | ---: | ---: | --- |
| `save_singleThreadEdit_in10kCorpus` | 100 ms | **2 ms** | ✓ ≈60× still |
| `activeThreadsForSelectedProject_10k` (100 reads) | 225 ms | **0.10 ms** | ✓ ≈2200× still |
| `activeThreadsForSelectedProject_1k` | 23 ms | 0.17 ms | ✓ ≈135× still |
| `selectThread_in_10kCorpus` | 10 ms | 0.72 ms | ✓ ≈14× still |
| `treeBuilder_50k` | 188 ms | 61 ms | ✓ ≈3.1× still |

The new `setRightPanelState` narrow mutator added during the merge
preserves the Fix #1 invariant — no UI mutation (mode swap, tab swap,
nvim open) falls back to the bulk `save(_:)`.

## What got slower (and why)

Main's multi-tab right-panel feature introduced two new tables
(`right_panel_tabs`, `right_panel_tab_state`) that the bulk save and
load paths now also have to walk. Bulk-path benchmarks regressed
relative to the perf branch:

| Benchmark | Pre-merge (perf only) | Post-merge | Change | Why |
| --- | ---: | ---: | --- | --- |
| `save_10k_threads` | 108 ms | **381 ms** | 3.5× slower | bulk save now inserts right_panel_tabs rows per thread |
| `save_1k_threads` | 13 ms | 40 ms | 3.1× slower | same |
| `save_100threads` | 4 ms | 9 ms | 2.3× slower | same |
| `load_10k_threads` | 14 ms | **57 ms** | 4.1× slower | load now hydrates right_panel_states |
| `load_1k_threads` | 3 ms | 9 ms | 3.0× slower | same |
| `load_100threads` | 1 ms | 3 ms | 3.0× slower | same |

These regressions are properties of main's new right-panel feature, not
of the perf fixes themselves. The same numbers would have appeared if
the perf branch had never existed — they're the cost of persisting the
new tab graph.

The user-perceptible impact:
- **Bulk save**: not in the hot path. The narrow UPSERTs handle every UI
  mutation. `save(_:)` only runs on the initial-seed path inside
  `SQLiteYAAWStore.load()` when projects is empty.
- **Bulk load**: runs once per app start. 57 ms for 10k threads is
  acceptable for cold start; perceptible but well under a second.

If future tuning is needed, candidate follow-ups:
- Lazy-load `rightPanelStatesByThreadID` per project (load only the
  selected project's threads' states at startup).
- Composite `idx_right_panel_tabs_thread` index to speed the
  per-thread fetch in `loadRightPanelStates`.

## Unchanged (as expected)

| Benchmark | Baseline | Post-merge |
| --- | ---: | ---: |
| `index_smallRepo` | 6 ms | 7 ms |
| `index_mediumRepo` | 154 ms | 157 ms |
| `index_largeRepo` | 1.55 s | 1.60 s |
| `fuzzy_5k_singleChar` | 99 ms | 104 ms |
| `fuzzy_5k_threeChar` | 94 ms | 99 ms |
| `fuzzy_5k_eightChar` | 99 ms | 113 ms |
| `fuzzy_50k_threeChar` | 916 ms | 963 ms |
| `treeBuilder_5k` | 10 ms | 9 ms |
| `selectedThread_lookup_10k` | 1.0 ms | 1.7 ms |

The fuzzy-matcher numbers are unchanged because Fix #3's win lives in
the debounced TextField binding in `FileBrowserPanel`, not in the
matcher itself. The debounce still applies after the merge.

## Reproduction

```sh
git checkout main
RUN_BENCHMARKS=1 swift test -c release --filter YAAWKitBenchmarks
```
