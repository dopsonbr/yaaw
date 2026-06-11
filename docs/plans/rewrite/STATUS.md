# YAAW Rewrite — Status & Handoff

Branch: `rewrite/option-b` (worktree `/Users/BXD5017/github/dopsonbr/yaaw-rewrite`).
Companion docs: [`00-master-plan.md`](00-master-plan.md) (the work order),
[`DECISIONS-LOG.md`](DECISIONS-LOG.md) (every judgement call, D-001…D-015),
[`DEFERRED-ISSUES.md`](DEFERRED-ISSUES.md) (tracked follow-ups),
[`specs/`](specs/) (the 9 detailed port specs the chunks were built against),
[`../../decisions/004-render-helper-compositing.md`](../../decisions/004-render-helper-compositing.md) (ADR).

## TL;DR

The rewrite **inverts the three structural bets** the architecture review flagged
and is **complete and verified as far as a headless (no-GUI) environment allows**:

- **`AppModel` god object → five `@MainActor @Observable` stores** + `AppEnvironment`
  (Chunk E). ✓ Done, 90 parity tests.
- **Poll-everything → actors + `AsyncStream` + Task cancellation** (Chunks A/B/C/E).
  ✓ Done; every generation counter / in-flight boolean removed.
- **Overlay-window rendering → typed XPC + CAContext compositing in a headless
  helper** (Chunk D). ✓ Code complete + compiles + the helper is self-contained;
  **runtime compositing needs the GUI** (see "What remains").

Everything that can be verified without a screen **is green**: the full package
builds (debug **and** release), **327 headless tests pass (0 failures)**, both
linters pass at the tightened thresholds (0 serious), the release perf gate runs,
and **the signed `.app` launches and survives startup**.

## Build / test / lint state

| Gate | Result |
|---|---|
| `swift build` (full package: YAAW app, YAAWRenderHost helper, YAAWKit, YAAWRenderProtocol, YAAWKitPerf) | ✓ Build complete |
| `swift build -c release --target YAAWKit` / `YAAWRenderProtocol` | ✓ complete (the `isolated deinit` release-optimizer crash was found and fixed — D-011) |
| `swift test` | ✓ **327 passed, 0 failures**, 24 benchmark-skips |
| `swiftlint` (warn 400/err 800 file_length, 8/12 cyclomatic, 50/120 function, 250/400 type) | ✓ 0 serious |
| `swift-format --strict` | ✓ clean |
| `swift run -c release YAAWKitPerf` | ✓ runs (numbers below) |
| `script/build_and_run.sh --build-only` → `.app` + `codesign --verify --deep --strict` | ✓ stages, self-contained, valid |
| `open -n YAAW.app` liveness (5 s, no crash) | ✓ launches and survives startup |

## Tightened standards (DoD)

- ✓ **Swift 6 language mode (strict concurrency `complete`) on every target.**
- ✓ **Zero `@unchecked Sendable` in new code** except, by deliberate documented
  decision (D-013): the 5 KEEP-verbatim terminal primitives (NSCondition/NSLock-based,
  can't be actors without losing the lossless-PTY blocking-wait semantics) and 3
  XPC/threading bridge objects in the helper + app (the idiomatic NSXPCConnection
  proxy pattern). No `nonisolated(unsafe)`, no `isolated deinit`, **zero
  `swiftlint:disable`** anywhere.
- ✓ Tightened file/complexity thresholds met (largest file ≤ ~580 lines).
- ⏳ **Public-API documentation** (`AllPublicDeclarationsHaveDocumentation`):
  enforced on new API as written; the verbatim-ported domain types have a tracked
  doc sweep before cutover (D-007; `YAAW_LINT_DOCS=1 scripts/lint.sh`).
- ⏳ **Warnings-as-errors CI gate**: gated, to flip on at cutover (D-006).

## Measured performance (release, `YAAWKitPerf`)

| Gate | Target | Measured | Verdict |
|---|---|---|---|
| Persistence single-edit @10k | ≤ 2 ms | **0.042 ms** | ✓ (the hot path; crushed) |
| Persistence full-snapshot save @10k | ≤ 30 ms | 109 ms | ▲ 3.5× faster than the 381 ms baseline; aspirational target missed on the 10k synthetic extreme (D-012) |
| Persistence load @10k | ≤ 10 ms | 17.5 ms | ▲ close; startup-only |
| `activeThreadsForSelectedProject` @10k | ≤ 0.1 ms | **0.000 ms** | ✓ (O(1) keyed lookup) |
| Fuzzy 50k / 3-char capped | ≤ 400 ms | **41.6 ms** | ✓ (was ~800 ms; rank() allocation fix) |
| Tree builder 50k | ≤ 61 ms | **56.9 ms** | ✓ |
| Cold index 50k | ≤ 1.5 s | 2.83 s | ▲ hardware-relative; faithful port, no regression (DEFERRED #6) |

Persistence + file-index numbers under target are hardware-relative on this
machine (the hot single-edit / O(1) reads — the operations that actually run on
every user action — meet target with huge margin; the misses are extreme
synthetic full-corpus operations). See DEFERRED-ISSUES #4/#6.

## Per-chunk status

| Chunk | Scope | Status |
|---|---|---|
| **0** | worktree, Package.swift, strict concurrency, tightened lint, ADR-004, domain port | ✓ done (49 domain tests) |
| **A** | PersistenceActor: UPSERT + statement cache + sparse-state rebuild + v17; **release-build crash fixed** | ✓ done (114 tests) |
| **B** | FileIndexActor: sorted-merge, `.git/HEAD` session cache, AsyncStream re-rank | ✓ done (+ FileBrowser tests) |
| **C** | SessionBindingActor + 4 declarative CLIManifests; drift detection; reversible path encoding | ✓ done (45 tests) |
| **D** | YAAWRenderProtocol (typed Codable + @objc XPC) + terminal stack; YAAWRenderHost helper (XPC + CAContext); RenderHostClient + TerminalSurfaceHostView | ✓ **code complete + compiles**; runtime compositing GUI-bound |
| **E** | AppModel → 5 stores + AppEnvironment; generation counters → Task cancellation; v18 persists per-thread UI state | ✓ done (90 parity tests) |
| **F** | thin SwiftUI views per store + appearance structure + AX ids + YAAWApp | ✓ **compiles + app launches**; appearance/screenshot parity GUI-bound |
| **G** | E2E driver + runner + crash-isolation probe + perf gate wiring | ◐ E2E target ported to compile + headless durable-state assertions + `test-e2e.sh` wired; **full GUI run needs a screen + accessibility** |
| **cutover** | docs, scripts, clean merge | ◐ docs updated; scripts wired; final merge is the owner's call after GUI verification |

## What remains (all GUI-verification-bound)

These cannot be verified in a headless environment; they are the owner's
finish-line, fully scoped in DEFERRED-ISSUES:

1. **Render-helper runtime + compositing (#12, #15).** Run `script/build_and_run.sh`,
   create a project → thread → CLI, and confirm: the `YAAWRenderHost` XPC service
   spawns, the per-surface `NSXPCConnection` resolves, and the terminal composites
   **in-pane** via `CALayerHost`/`CAContext` with no tearing/scale-drift. If the
   launchd XPC-service model fights AppKit/Ghostty, switch `RenderHostClient` to a
   child-`Process` + anonymous `NSXPCListener` endpoint (the helper already runs an
   NSApplication; the wire protocol is identical). The `frameReady` envelope
   carries both `contextID` and `ioSurfaceRef`, so the IOSurface fallback needs no
   protocol change.
2. **Appearance / screenshot parity (#16).** Capture via the E2E SCK path, diff
   against `docs/examples/screenshots/current/*`, fix deltas.
3. **Full E2E run (Chunk G).** Needs the running `.app` + accessibility permission;
   the headless durable-state assertions + the driver/probe machinery are in place.
4. **Crash-isolation probe** — `kill -9` a render helper, assert app + siblings
   survive and the pane recovers (the recovery code path exists in RenderHostClient).
5. **Doc sweep + warnings-as-errors flip** (D-006/D-007) — mechanical, pre-merge.

## How to finish

```sh
cd /Users/BXD5017/github/dopsonbr/yaaw-rewrite
scripts/check.sh                 # build + 327 tests
scripts/lint.sh                  # tightened, 0 serious
swift run -c release YAAWKitPerf # perf gate
script/build_and_run.sh          # launch the real app, then exercise a terminal pane
scripts/test-e2e.sh              # full acceptance (needs GUI + accessibility)
```

The architecture, all business logic, persistence, indexing, session binding,
the store decomposition, the typed XPC seam, and the render-helper structure are
done, tested, and committed across 12 one-concern commits. The remaining work is
exercising and tuning the live GUI — which is exactly the part a headless agent
cannot see.
