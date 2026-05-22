# YAAW perf - large file browser coverage, 2026-05-22

Ran after adding large-index file-browser guardrails and refreshing the
benchmark suite:

```sh
RUN_BENCHMARKS=1 swift test -c release --filter YAAWKitBenchmarks
```

Result: 27 benchmarks passed. The regular test suite also passed with
`scripts/test.sh`: 211 tests, 27 skipped, 0 failures.

## File browser numbers

| Benchmark | Avg (s) | RSD | Note |
| --- | ---: | ---: | --- |
| `index_largeRepo` | 1.528 | 1.6% | Cold/background indexing path. |
| `fuzzy_50k_threeChar` | 0.949 | 2.7% | Legacy uncapped matcher reference. |
| `fuzzy_50k_cappedThreeChar` | 0.919 | 2.0% | Current search presentation path, capped at 1k rows. |
| `fuzzy_150k_cappedThreeChar` | 2.764 | 1.5% | Large-index regression signal for search. |
| `treeBuilder_50k` | 0.057 | 6.6% | Legacy full-tree reference, no longer the scroll hot path. |
| `visibleRows_50k_collapsed` | 0.030 | 22.2% | Current collapsed browse path. |
| `visibleRows_50k_oneExpandedBranch` | 0.030 | 13.6% | Current expanded browse path. |
| `visibleRows_150k_collapsed` | 0.084 | 6.0% | Large-index collapsed browse path. |
| `visibleRows_150k_oneExpandedBranch` | 0.088 | 10.1% | Large-index expanded browse path. |
| `visibleRows_150k_cappedTenThousandRows` | 0.008 | 21.5% | Stops once the 10k render cap is reached. |

## Interpretation

`treeBuilder_50k` remains useful as a legacy reference, but it no longer
represents the scrolling hot path. The right-panel file browser now renders
flat visible rows from expanded branches and caps the rendered tree at 10k
rows.

The capped fuzzy-search benchmarks intentionally show that limiting published
results prevents SwiftUI from diffing huge lists, but the matcher still ranks
against the full source index. That is acceptable for this guardrail pass and
now has explicit benchmark coverage.

## Stability notes

The AppModel read benchmarks now batch 100k reads per measurement block so
their averages are less dominated by timer overhead. Some sub-10ms and
filesystem-backed benchmarks still show higher RSD because the absolute times
are very small or the benchmark creates temporary files.

## Reproduction

```sh
swift test --filter FileBrowserTests
scripts/test.sh
RUN_BENCHMARKS=1 swift test -c release --filter YAAWKitBenchmarks
```
