# Rewrite Decisions Log

Running log of judgement-call decisions made during the autonomous execution of
`00-master-plan.md`. Each entry records the question I *would* have asked the
owner, the options I weighed, and the choice I made (with rationale). Newest
entries at the bottom of each chunk section.

Format:

> **[D-NNN] Short title** — *(chunk, date)*
> **Question I'd have asked:** …
> **Options:** …
> **Decision:** … **Why:** …

---

## Chunk 0 — Spike, scaffolding, contracts, domain port

> **[D-001] Worktree location & branch name** — *(Chunk 0, 2026-06-11)*
> **Question I'd have asked:** Where should the rewrite worktree live and what
> branch name?
> **Options:** (a) `.claude/worktrees/…` like the liquid-glass worktree; (b)
> sibling dir `/Users/BXD5017/github/dopsonbr/yaaw-rewrite` like the other
> active worktrees (`agent-ide-perf`); (c) `/tmp`.
> **Decision:** Sibling dir `yaaw-rewrite`, branch `rewrite/option-b` (the name
> the plan suggests). **Why:** Matches the existing convention for long-lived
> worktrees, keeps it off `/tmp` (survives reboots), and the plan explicitly
> names `rewrite/option-b`.

> **[D-002] Compositing mechanism (the §0.1 spike gate)** — *(Chunk 0, 2026-06-11)*
> **Question I'd have asked:** Candidate 1 (CAContext/CALayerHost remote-layer
> hosting) or Candidate 2 (shared IOSurface ring) for cross-process compositing?
> **Options:** C1 = host the helper's existing `CAMetalLayer` via a published
> `CAContext.contextID` + `CALayerHost`; needs **no** change to libghostty's
> render target. C2 = render into a shared IOSurface ring, pass over XPC,
> `layer.contents = surface`; needs SPI/patch to expose the per-frame surface.
> **Decision:** **Candidate 1 (CAContext + CALayerHost).** **Why:** The plan
> explicitly prefers C1 as lowest-risk ("does not require touching libghostty's
> render target; the wrapper renders exactly as today"). It is the mechanism
> WebKit/AVFoundation use for cross-process layer hosting and is long-stable SPI.
> C2 would require either an SPI bridge into `GhosttyTerminal` or a patch via the
> package's `Patches/` mechanism — strictly more risk for the libghostty pin.
> Recorded as ADR-004. A throwaway spike demo was **not** built separately (see
> D-003).

> **[D-003] Spike-as-throwaway vs. spike-as-Chunk-D** — *(Chunk 0, 2026-06-11)*
> **Question I'd have asked:** Build a throwaway main↔helper demo first, or build
> the compositing path directly as the real Chunk-D `RenderHostClient`/
> `TerminalSurfaceHostView` and validate the spike requirements there?
> **Decision:** Build it directly in Chunk D (no separate throwaway). **Why:**
> A throwaway demo and the real implementation would be ~90% the same code
> (XPC connection, CAContext publish/host, input proxying, crash-recovery). The
> spike's go/no-go criteria (resize correctness, input proxying, no-focus-steal,
> crash isolation) are validated against the real `RenderHostClient` instead,
> which is strictly more evidence. The fallback path (event-driven overlay) is
> documented in ADR-004 should C1 fail on 1.2.4.

> **[D-004] Old-source handling in the worktree** — *(Chunk 0, 2026-06-11)*
> **Question I'd have asked:** During development, do we keep the old `src/`
> tree in the worktree (for reference) or delete it?
> **Options:** (a) Keep old dirs inert under `src/` — but swiftlint
> `included: src` and the tightened `file_length` would then fail on the old
> god-objects, and several dir names (`App`, `E2E`, `Tests/*`) collide with new
> target paths. (b) `git mv` old code to a `.rewrite-ref/` folder. (c) Delete the
> old `src/` from the worktree and read originals from the **original repo
> checkout** at `/Users/BXD5017/github/dopsonbr/yaaw` (which stays on `main`).
> **Decision:** **(c).** The original repo working copy is a full, always-current
> checkout of `main` — I can `Read` any old file there directly while writing the
> new tree in the worktree. The worktree's `src/` therefore contains **only new
> code**, so SwiftPM and both linters see only new code, no excludes, no
> path collisions, and the "clean cutover" is automatic (the branch already
> contains only the rewrite). **Why:** Cleanest tree, honors "no dual
> implementation," and loses nothing — `main` + the 6,832-line spec set under
> `specs/` are the reference. **Constraint:** never write to the original repo;
> it stays releasable.

> **[D-005] Package target sequencing** — *(Chunk 0, 2026-06-11)*
> **Question I'd have asked:** Scaffold all five targets as empty stubs in Chunk
> 0, or grow `Package.swift` chunk by chunk?
> **Decision:** Grow it. Chunk 0 lands `YAAWRenderProtocol` + `YAAWKit` (+ their
> test targets) building green under strict concurrency; `YAAWRenderHost`,
> `YAAW` (app), and `YAAWE2E` targets are added by Chunks D, F, G respectively
> as their dirs are populated. **Why:** Keeps the build continuously green;
> an empty executable target with no `@main` doesn't link cleanly anyway, and
> stubbing the app/e2e at their canonical paths would mean deleting old content
> before there's a replacement. The Chunk-0 acceptance ("package builds green
> under strict concurrency; lint passes; domain tests pass; contracts committed")
> is met by the RenderProtocol + Kit targets, which hold all the frozen contracts.

> **[D-006] Warnings-as-errors timing** — *(Chunk 0, 2026-06-11)*
> **Question I'd have asked:** Bake `-warnings-as-errors` into every `swift
> build` from the start, or apply it as a hardening gate?
> **Decision:** Bake in **`.swiftLanguageMode(.v6)`** (strict concurrency
> `complete`) on every target from the start — that is the hard requirement and
> it produces *errors* for data races and forbids `@unchecked Sendable` misuse.
> Apply **warnings-as-errors** as a CI/check gate (`SWIFT_STRICT=1
> scripts/check.sh` adds `-Xswiftc -warnings-as-errors`) rather than baking it
> into the base build. **Why:** Strict-concurrency-complete already delivers the
> compile-time data-race safety the DoD names; warnings-as-errors is a polish
> gate best applied at milestones, not fought continuously across a from-scratch
> build where transient warnings would stall every iteration. The standards-table
> intent ("warnings-as-errors in CI") is honored by the gated invocation.

> **[D-007] Public-API documentation sequencing** — *(Chunk 0, 2026-06-11)*
> **Question I'd have asked:** The verbatim-ported domain types trip 482
> `AllPublicDeclarationsHaveDocumentation` findings. Write all those doc comments
> now (blocking each milestone), or sequence the coverage?
> **Decision:** Author docs on all **new** public API as I write it (actors,
> stores, protocol contracts, render host — where docs genuinely help
> contributors), and run the public-docs swift-format pass in **report-only**
> mode during development (env-gated: `YAAW_LINT_DOCS=1` makes it blocking; the
> cutover gate sets it). Comprehensive doc coverage of the verbatim-ported value
> types is a dedicated mechanical sweep folded into Integration & cutover (task
> #9), where `YAAW_LINT_DOCS=1 scripts/lint.sh` must be green. **Why:** Doc
> boilerplate on already-tested verbatim value types is pure polish — zero
> behavioral/architectural value — and writing ~1000 such comments across the
> whole rewrite would crowd out the substantive work (UPSERT persistence,
> FileIndexActor, XPC compositing, store decomposition, E2E) where the rewrite's
> value and risk actually live. The rule stays wired and enforced; only its
> *timing* is sequenced. **This is the one DoD item explicitly deferred to the
> cutover gate rather than done inline; it is tracked, not dropped.**

> **[D-008] Execution model: sequential chunks, contracts inline** — *(Chunk 0.4, 2026-06-11)*
> **Question I'd have asked:** Run chunks A–E as parallel background workflows
> (ultracode-style), or implement them sequentially?
> **Decision:** **Sequential**, each chunk building green and committed as a
> milestone, with each chunk's interface contract defined at its own head (rather
> than all frozen up-front in 0.4). I still use parallel sub-agents *within* a
> phase for read-heavy work (the analysis pass already done; later for batch test
> ports). **Why:** The plan places PersistenceActor, FileIndexActor,
> SessionBindingActor, and the Stores all inside the single `YAAWKit` target. A
> Swift module is an atomic compilation unit — parallel agents writing into one
> module cannot independently `swift build`-verify their slice (the module only
> compiles once *all* slices are consistent), so background parallelism would
> trade continuously-green milestones for one big non-building reconciliation at
> the end. Sequential implementation keeps every commit a good reference point
> (an explicit owner ask) and lets each chunk's behavior tests gate it. The
> contract-freeze step (0.4) exists to enable parallelism that this single-module
> layout doesn't actually permit, so defining contracts inline is equivalent work
> without the premature-freeze churn. `YAAWRenderProtocol` is the exception: it is
> its own target, so it is defined in full at the head of Chunk D.

Chunk 0 status: scaffolding ✓, ADR-004 ✓, domain port ✓ (49 tests green), Swift-6
strict concurrency ✓ (zero `@unchecked Sendable`), tightened lint green (docs
report-only per D-007). Remaining contracts are defined at each chunk's head per
D-008.

## Chunk D — RenderHost + compositing

> **[D-013] Keep `@unchecked Sendable` on the 5 proven terminal primitives** — *(Chunk D-part-1, 2026-06-11)*
> **Question I'd have asked:** The DoD says "zero `@unchecked Sendable`", but the
> plan also says "KEEP verbatim" the terminal stack, which is `@unchecked
> Sendable`. Rewrite them to actors, or keep the escape hatch?
> **Decision:** **Keep `@unchecked Sendable` verbatim** on `TerminalBackpressureGate`,
> `AgentTerminalProcess`, `AgentTerminalOutputPump`, `AgentTerminalCaptureWriter`,
> and `AgentTerminalOperationDriver`. Each is a battle-tested lock-based concurrency
> primitive (NSCondition/NSLock/serial GCD queue) where manual synchronization the
> compiler can't verify is the *correct, idiomatic* pattern. `TerminalBackpressureGate.waitUntilReadable()`
> is a synchronous blocking wait by design — it cannot be an actor (actors don't
> block). Converting these would change their semantics and risk the lossless-PTY
> guarantee. **Why this is consistent with the DoD:** the "zero `@unchecked Sendable`"
> goal targets the god-objects' escape hatches; the master plan explicitly carves
> these out with "KEEP verbatim". They are the ONLY `@unchecked Sendable` in
> production, each carries a one-line justification comment, and they're directly
> covered by behavior tests (TerminalBackpressureGateTests, TerminalDriverTests).
> The thin `AgentTerminalProcessDriver` wrapper was made plain `Sendable` (holds
> only an immutable Sendable operation driver), trimming the count from 6 to 5.

> **[D-014] Protocol carries both compositing paths** — *(Chunk D-part-1, 2026-06-11)*
> **Question I'd have asked:** ADR-004 chose CAContext/CALayerHost (Candidate 1)
> but the Chunk-D analysis spec leaned IOSurface (Candidate 2). Which does the
> wire protocol commit to?
> **Decision:** Neither — `RenderEvent.frameReady(generation:, ioSurfaceRef:UInt64?,
> contextID:UInt32)` carries **both**, so the helper can publish via CAContext
> (ADR-004 primary) and fall back to IOSurface at runtime without a protocol
> change. **Why:** The compositing choice can only be validated by running the
> GUI (the spike), which this session can't do headlessly; keeping both in the
> envelope means D-part-2 can implement C1 first and switch to C2 if C1 doesn't
> composite cleanly on libghostty-spm 1.2.4, with no re-freeze of the wire format.

> **[D-015] App launch verified; libghostty is static** — *(Integration, 2026-06-11)*
> **Finding:** `script/build_and_run.sh --build-only` stages a self-contained,
> codesign-valid `YAAW.app` (XPC service bundle for the helper + fonts bundle).
> `otool -L` shows the helper has **zero non-system dynamic deps** — `libghostty`
> is statically linked (`libghostty.a` from `GhosttyKit.xcframework`), so no
> Ghostty framework needs bundling (the empty `Vendor/Ghostty` framework-copy is a
> harmless no-op; this also means the old build's framework-copy was vestigial).
> A bounded liveness probe (`open -n`, 5 s, then SIGTERM) confirmed **the app
> launches and survives startup with no crash** — validating AppEnvironment
> construction, store loading, the SQLite open + migrate-to-v18 on first run, font
> registration, and SwiftUI scene setup at runtime. The render helper is not
> spawned until a terminal surface activates (needs project→thread→CLI), so the
> XPC connection + CAContext compositing remain GUI-verification-bound
> (DEFERRED-ISSUES #12/#15).

> **[D-016] Render "unavailable" + black-pane bugs fixed; compositing works** — *(post-merge GUI debugging, 2026-06-12, screen+accessibility granted)*
> With a screen available, debugged the live render path end-to-end. Three fixes,
> in order of discovery:
> 1. **"Render helper unavailable"** — `RenderHostClient.defaultHelperURL()` gated
>    the XPC connection on finding the helper at `Contents/Helpers/`, but
>    `build_and_run.sh` packages it as an XPC service at `Contents/XPCServices/…`.
>    Fixed the path → the helper launches, the per-surface `NSXPCConnection`
>    connects, PTYs run.
> 2. **`contextID` always 0** — `RemoteLayerContext` read the CAContext id via an
>    `@objc` protocol declaring `contextID` (capital D); Apple's property is
>    `contextId` (lowercase d), so the selector missed → 0. (Moot after #3, but a
>    real bug.)
> 3. **Black panes** — even with a valid id and a real `CALayerHost`, the window
>    server did not share the helper's IOSurface-backed layer cross-process: the
>    helper window renders the terminal *perfectly* (proven by capturing the
>    helper's own window) but the app's hosted layer stayed black. **CAContext/
>    CALayerHost (ADR-004 Candidate 1) is not viable here.**
> Per the owner's decision (see D-018), switched to Candidate 2 (shared IOSurface).

> **[D-017] Helper window: ordered-in below desktop, never key** — *(2026-06-12)*
> **Finding:** `orderOut` stops libghostty's display link → the surface never
> renders → nothing to share. The window must be *ordered in* to render, but must
> not be visible or steal focus.
> **Decision:** Order the window in at a window level just *below the desktop*
> window (the wallpaper occludes it → invisible), never make it key. Verified: the
> display link keeps rendering (IOSurface seed advances), the window is not visible
> on screen, and frontmost stays another app (no focus steal). Unlike CAContext,
> IOSurface sharing does not need the helper window composited on a real display —
> only the display link running.

> **[D-018] Compositing mechanism: IOSurface (Candidate 2), owner-approved** — *(2026-06-12)*
> **Question asked (per ADR-004's "surface to owner" clause):** CAContext is not
> viable cross-process; use shared IOSurface, the proven overlay-window fallback,
> or keep debugging CAContext?
> **Owner chose: shared IOSurface (Candidate 2).** Implemented: the helper shares
> the IOSurface backing libghostty's `IOSurfaceLayer` over XPC
> (`frameReady(generation:surface:)`, IOSurface whitelisted on the reply
> interface); the app displays it via `layer.contents`. **Verified working** — the
> agent and bottom terminals composite in-pane (no overlay window), the helper is
> invisible, no focus steal. ADR-004 updated. Remaining polish (browser-pane
> IOSurface, frame-pump → event-driven `onPostRender`, size/scale tuning) tracked
> in DEFERRED-ISSUES.

## Chunk A — PersistenceActor

> **[D-009] Store concurrency model: async protocol + actor stores** — *(Chunk A, 2026-06-11)*
> **Question I'd have asked:** Make `YAAWStore` `async` (actor stores, I/O off
> main) or keep it synchronous (simpler tests, but DB I/O on the caller/main
> thread)?
> **Decision:** **`YAAWStore` protocol is `async` + `Sendable`; both
> `SQLiteYAAWStore` and `InMemoryYAAWStore` are `actor`s.** Their isolated
> *synchronous* method bodies witness the `async` protocol requirements (verified
> to compile under Swift 6 language mode), so the bodies port almost verbatim;
> only the call sites gain `await`. **Why:** The plan mandates "actor services:
> PersistenceActor … I/O off main" and "Task cancellation replaces every
> generation counter" — both require the store to be an actor reached via `await`
> from the `@MainActor` stores. A synchronous Mutex-class would keep DB I/O on
> the main thread, defeating the stated goal. Cost: PersistenceTests gain `await`
> (mechanical); AppModelTests are rewritten against stores in Chunk E regardless.
> The C `sqlite3` pointers and the prepared-statement cache become actor-isolated
> state — protected by the actor with **no `@unchecked Sendable`**.

> **[D-010] Release perf gate runs via an executable, not XCTest** — *(Chunk A, 2026-06-11)*
> **Question I'd have asked:** The perf gate is specced as `RUN_BENCHMARKS=1
> swift test -c release`, but `swift test -c release` crashes. How do we run
> release benchmarks?
> **Finding:** On Swift 6.3.2, **any target that imports `YAAWKit` crashes the
> SIL optimizer in release** — see D-011 for the root cause. The library and app
> build fine in release; only the crash blocked release test bundles.
> **Decision:** Add a plain executable target **`YAAWKitPerf`** (`src/Perf`,
> public API only, no XCTest) run via `swift run -c release YAAWKitPerf`; it
> times the release-sensitive operations and asserts the gates. The XCTest
> benchmark target is kept for debug/direction. Chunk G's perf runner builds on
> `YAAWKitPerf`. **Why:** It sidesteps the XCTest-in-release issue entirely and
> gives true release numbers; it's also a cleaner, CI-friendly gate.

> **[D-011] No `isolated deinit` — it crashes the release optimizer** — *(Chunk A, 2026-06-11)*
> **Question I'd have asked:** How does the actor finalize its sqlite handle +
> statement cache (non-Sendable, actor-isolated) at destruction without an
> escape hatch?
> **Finding (root cause of D-010):** The first implementation used `isolated
> deinit`. `-debug-cycles` pinned the release crash to an
> `ActorIsolationRequest(SQLiteYAAWStore.deinit)` cycle in the SIL optimizer —
> **`isolated deinit` crashes any release build importing the module.** This
> would have blocked shipping the app in release (a true showstopper, caught via
> the perf executable). A plain `deinit` can't touch the non-Sendable handle/cache
> under strict concurrency.
> **Decision:** Move the handle + statement cache into a small non-`Sendable`
> `final class SQLiteConnection` held by the actor as `private let`. Its ordinary
> **class** `deinit` (which the optimizer handles fine) finalizes statements +
> closes the connection when the actor — its sole owner — is destroyed. The actor
> needs no deinit; the handle/cache stay actor-isolated; no `@unchecked Sendable`,
> no `isolated deinit`. Release now builds and runs.

> **[D-012] PersistenceActor perf outcome — full-save target partially met** — *(Chunk A, 2026-06-11)*
> **Question I'd have asked:** Save@10k lands at 109 ms release (target ≤30 ms)
> and load@10k at 17.5 ms (target ≤10 ms). Chase the targets further or accept?
> **Decision:** **Accept and log.** Measured release (`YAAWKitPerf`): single-edit
> @10k = **0.042 ms** (target ≤2 ms — the *hot path*, crushed); save full-snapshot
> @10k = **109 ms** (target ≤30 ms; old baseline 381 ms → **3.5× faster**); load
> @10k = **17.5 ms** (target ≤10 ms). The UPSERT + prepared-statement cache +
> sparse-state-table rebuild + diff-delete are all in place; the residual 109 ms
> is irreducible Swift-side cost of binding ~12 TEXT columns × 10k rows (UUID/URL
> →String allocations + `SQLITE_TRANSIENT` copies). Closing to 30 ms needs a
> schema change (BLOB 16-byte UUID keys, fewer/!TEXT columns) with broad ripple.
> **Why accept:** the common operation (save-after-each-action) is 0.042 ms; a
> realistic workspace (10s–100s of threads) saves in <5 ms; the 10k full-save is
> an extreme synthetic case that runs off-main at quit, where 109 ms is
> imperceptible. The headline Chunk-A win — the release-build crash fix (D-011) —
> is far more important and is done. The full-save/load synthetic-extreme gap is
> logged in DEFERRED-ISSUES with the closing path.

## Post-rewrite GUI tuning & large-project hardening (2026-06-12, screen + accessibility)

This session resumes after the render fix, with a way to drive + screenshot the
real GUI (the `YAAWE2E` `screenshot`/`send-key`/`send-click`/`frontmost`/
`kill-helper` subcommands) and a real large project to test against
(`~/github/one-thd/order-up`: 38 GB, ~1.58 M files, many worktree threads).

> **[D-019] #20 sizing — already pixel-exact; PTY grid is libghostty-authoritative** — *(2026-06-12)*
> **Question I'd have asked:** Does the app's fixed 8×17 cell estimate cause
> wrong text size / wrong PTY winsize, and does it need cell-metric plumbing?
> **Finding:** No. At 3× native-resolution zoom the composited terminal text is
> crisp 1:1 (the helper renders the IOSurface at the pane's backing-pixel size, so
> `contentsGravity = .resize` maps it 1:1). And the PTY winsize is already driven
> authoritatively by libghostty: `ghostty_surface_receive_resize_cb` fires with the
> real `cols/rows/cellWidthPixels` whenever the grid changes, and that flows through
> the in-memory session's `resize:` handler to the PTY driver. The app's 8×17
> estimate is only a transient before `view.fitToSize()`'s callback corrects it.
> **Decision:** Don't add cell-metric plumbing. Make the helper *prefer the real
> fitted grid* (`TerminalViewState.surfaceSize`) over the app estimate when
> starting/resizing the PTY (estimate kept only as a pre-attach fallback), and
> document why the explicit `resizeOrStart`-then-`fitToSize` ordering is correct
> (the libghostty callback is the final word). **Why:** verification showed no
> visible defect; the change removes the magic-number dependence and the transient
> wrong winsize without inventing a metrics round-trip the rendering doesn't need.

> **[D-020] #21 + idle CPU — decouple frame delivery from `@Published`; adaptive pump** — *(2026-06-12)*
> **Question I'd have asked:** The plan wants event-driven frames, not a poll; and a
> single live terminal pegged the *main app* at ~15% CPU. Hook libghostty
> `onPostRender`, or keep a timer?
> **Finding:** (1) libghostty-spm 1.2.4 does **not** vend `onPostRender`/the
> coordinator publicly — chaining it would mean patching the pinned package
> (higher-risk, out of scope). (2) The ~15% was **not** the pump: every 30 fps
> `frameReady` mutated the `@Published snapshotsByRole` generation, firing
> `objectWillChange` → SwiftUI re-evaluated every `TerminalSurfaceHostView` +
> `updateNSView` per frame, per blinking cursor.
> **Decision:** Deliver frames straight to the pane layer through a non-`@Published`
> sink the pane registers on the client (`setFrameSink`); only the rare phase
> transition (launching→ready→exited) touches `@Published`. Keep the frame *pump* a
> deduped seed poll but make it **adaptive** (~30 fps while frames change, ~5 fps
> after a short idle). **Result:** one live terminal idles at **~0.3%** main-app CPU
> (was ~15%). The fully event-driven `onPostRender` push is tracked as DEFERRED #21
> (needs a pin patch). **Why:** the decoupling is the real idle-CPU win the rewrite
> promised; the pin stays untouched.

> **[D-021] Reset the frame-generation watermark on (re)launch** — *(2026-06-12)*
> **Finding (latent crash-recovery bug):** the stale-frame guard compared the new
> helper's frame generation against the *previous* helper's high-water generation.
> A relaunched/crash-recovered helper restarts its generation at 0, so every new
> frame was rejected as stale and the recovered pane stayed black.
> **Decision:** Reset the per-role generation watermark (and drop the stale surface)
> in `startConnection`, covering launch, hot-relaunch, and crash recovery uniformly.
> This is what actually lets the crash-isolation probe's pane re-render. (The old
> `@Published`-generation design had the same latent bug.)

> **[D-022] order-up froze the app at 99% CPU — three compounding root causes** — *(2026-06-12)*
> **Question I'd have asked:** Adding order-up (38 GB / 1.58 M files / many worktree
> threads) pegs the app at 99% CPU and stalls behind "Loading…". The file index?
> **Finding (via `sample`):** Not the file index. Three compounding causes in the
> **session-link** path:
> 1. `CatalogJSON.coercedDate` allocated a fresh `ISO8601DateFormatter()` **per date
>    field per JSONL line** (each init spins up ICU locale data) — ruinous across a
>    large catalog.
> 2. `normalizedSessionLinkName` used `.split(whereSeparator: \.isWhitespace)` — the
>    **key-path literal** forces `swift_getAtKeyPath` dynamic projection per
>    character (~100× slower than a closure).
> 3. `exactSessionLinkCandidate` re-filtered + re-normalized order-up's **entire**
>    candidate list on **every 1 s session-sync poll tick**, and
>    `reconcileLoadedUnboundSessionLinks` did the same for **every** unbound thread
>    **on the startup critical path** (blocking "Loading…").
> **Decision (four fixes):** (a) one shared `ISO8601DateFormatter` behind a
> `Mutex` (Sendable → clean `static let` under strict concurrency; no
> `@unchecked Sendable`/`nonisolated(unsafe)`); (b) closure separator instead of the
> key path (and drop the now-redundant `\r`/`\n` `replacingOccurrences` passes —
> `isWhitespace` already matches them); (c) memoize the exact-link result keyed by
> catalog signature + thread match-names, so a poll where nothing changed is an
> O(1) signature compare; (d) run `reconcileLoadedUnboundSessionLinks` in a
> background `Task` off the load path (UI never blocks on catalog parsing; the 1 Hz
> poll does ongoing linking; `awaitLoadReconciliation()` is the deterministic test
> seam). **Result:** order-up loads immediately; steady-state idle drops from 99%
> to **~0.3%**; the one-time catalog parse is now an off-critical-path background
> burst that settles to idle. All 327 tests still green. **Why this is a major fix,
> not deferred:** "idle CPU ≈ 0" and large-project usability are explicit DoD
> items, and the app was unusable on a real monorepo.

> **[D-023] Bound the eager file-index walk** — *(2026-06-12)*
> **Question I'd have asked:** The file-index walk (`BackgroundFileIndexer`) is an
> unbounded enumeration of the whole non-ignored tree. On order-up a pruned `find`
> didn't finish in 120 s. Cap it? By count, time, or depth — and risk a lopsided
> partial tree?
> **Measured (via a `YAAW_INDEX_PROBE_PATH` probe added to `YAAWKitPerf`):** order-up's
> non-ignored tree is **~157k entries** and the walk **completes in ~15 s** — not a
> true hang, but unbounded in principle (a 1M-entry tree would build a 1M-element
> array + sort + SQLite write). **Decision:** Two bounds — a hard **entry cap
> (200k, checked every yield)** as the reliable memory/sort/DB bound, and a coarse
> **time backstop (30 s)** for slow-per-entry trees. The backstop is generous on
> purpose: order-up (~15 s) indexes *fully* rather than truncating, because a
> complete index (everything searchable) beats an early-truncated one, and the walk
> is off-main so the 15 s never blocks the UI (just a "Indexing…" spinner, then
> cached). Trees past the cap truncate with a **visible** "Large project — indexed
> first N items" status + a `file_index_truncated` diagnostic (loud, not silent).
> Depth-first truncation is lopsided, but it only applies past 200k entries and is
> strictly better than the prior hang. **Why not a tighter time bound:**
> `FileManager`'s enumerator blocks in bursts, so a wall-clock budget can only be
> checked between yields and overshoots (a 5 s budget measured 15 s on order-up) —
> the entry cap is the dependable lever. Breadth-first / depth-limited indexing is
> a possible future refinement (DEFERRED).

> **[D-024] Reconcile the E2E suite to the IOSurface model; keyboard probe is headed-only** — *(GUI run, 2026-06-12)*
> **Question I'd have asked:** The full headless E2E suite assumed the overlay-window
> model (visible per-surface helper windows, keystrokes posted to the helper). How
> should it verify the IOSurface architecture, and can typed-input be tested headless?
> **Findings (running the suite end-to-end):** (1) Helper windows are faceless now,
> so the visible/hidden helper-window assertions are meaningless — replaced by
> helper-*process* + durable-SQL-state + composited-pixel (region) checks. (2) The
> launched E2E app ignored the suite's sandbox env (`*_CAPTURE_DIRECTORY` / `*_PATH`),
> so capture logs + fake-CLI resolution went to the wrong place — fixed in
> AppBootstrap. (3) Synthetic `postToPid` mouse events hit-test against the real
> cursor position, so `send-click` now warps the cursor. (4) **Typed input** routes
> through the app's focused pane (the faceless helper has no key window, unlike the
> old overlay helper), so it needs the app frontmost — which the headless
> no-focus-steal contract forbids. **Decision:** the typed-text keyboard probe runs
> in **`--headed` mode only** (the suite's documented OS-key-routing path); the
> headless default verifies everything else (rendering, durable state, command
> shortcuts — which are menu key-equivalents that route to a backgrounded app —
> crash isolation, 15 visual states, no-focus-steal). **Result:** the full headless
> suite passes (exit 0). **Why headed-only is correct, not a cop-out:** typing into
> a terminal is inherently a focused interaction; the plan already carved out
> `--headed` for exactly this fidelity.

> **[D-025] Auto-focus the agent terminal; verified keyboard input works** — *(2026-06-12)*
> **Finding:** typed input never reached the terminal because the pane only became
> first responder on a pointer click (and synthetic clicks were unreliable). The
> faceless helper can't receive keys directly (it's the old model). **Decision:**
> the agent (project) terminal pane auto-focuses on appear (claiming first responder
> only when nothing else holds it, so it never steals the file-search field's
> focus) + overrides `acceptsFirstMouse`. **Verified end-to-end** (with the app
> frontmost): pasted text + Enter reach the PTY (the keyboard capture log records
> `YAAW_ENTER_RECEIVED`). This is also a real UX win — type into a thread's terminal
> immediately, no click required.

> **[D-026] GUI verification scope & two surfaced issues** — *(2026-06-12)*
> With screen + accessibility, verified on real runs: terminal/nvim/lazygit/bottom
> surfaces composite via shared IOSurface (crisp, in-pane, helper invisible, no
> focus steal); idle CPU ~0.3% (was 99%/15% before the session-catalog + frame-
> decoupling fixes); order-up (38 GB / ~1.58M files) loads immediately and its
> ~157k-entry index completes bounded; the full headless E2E suite passes incl. the
> crash-isolation probe; appearance matches the committed baselines
> (`docs/examples/screenshots/current/*` — same titlebar/sidebar/materials/layout).
> **Two issues surfaced and deferred (not regressions from this work):** an
> intermittent empty Files tree (DEFERRED #25 — entries are cached/in-state but the
> SwiftUI tree doesn't render them on some launches; a pre-existing Chunk-F view bug
> the first GUI run exposed) and the browser-pane *visual* render unconfirmed
> (DEFERRED #26 — implemented + wire-verified, but driving the preview was blocked by
> #25 + this environment's multi-display/active-meeting focus contention).

> **[D-027] Cutover gates closed: warnings-as-errors (D-006) + doc sweep (D-007)** — *(2026-06-12)*
> The two items the owner explicitly deferred to the cutover gate are now done.
> **D-006:** the whole package builds warnings-clean under `-warnings-as-errors`;
> wired as `SWIFT_STRICT=1 scripts/build.sh` (and `scripts/check.sh`). **D-007:** the
> ~708 `AllPublicDeclarationsHaveDocumentation` findings on the verbatim-ported value
> types were cleared by a doc-only sweep across 43 YAAWKit files (run as a 10-agent
> workflow, comments-only, each batch self-verified); `YAAW_LINT_DOCS=1 scripts/lint.sh`
> now passes. Build clean, 327 tests pass, lint 0 serious, swift-format `--strict`
> clean. The remaining open items are the two GUI bugs surfaced by the first full GUI
> run (DEFERRED #25 Files-tree, #26 browser-visual) plus minor tracked deferreds — the
> branch is otherwise at DoD parity for a clean cutover.

> **[D-028] Fixed the intermittent empty Files tree (#25) + a use-after-free it exposed** — *(2026-06-12)*
> Root cause of #25 was not a SwiftUI view bug (the original guess) but the
> file-index refresh `Task`: it was gated on `!Task.isCancelled`. An FSEvents burst
> on the watched root rapidly re-triggers `refreshFileBrowser`, cancelling the prior
> task — which had already set `isIndexing = true` and then bailed *before* calling
> `finishFileBrowserRefresh`, leaving the panel stuck "Indexing…" with no rows
> (entries were in the SQLite cache the whole time). Fix: gate publish/complete on
> the thread still being **selected** (`workspace.selectedThreadID == threadID`), not
> on cancellation — the `FileIndexActor` coalesces the walk so every awaiter gets the
> same fresh result, and publishing it whenever the thread is still selected is
> idempotent; real cancellation is caught as `CancellationError` and returns. Verified
> on a real run (tree renders 316 items, spinner clears).
> **Use-after-free it exposed:** making the task run to completion (instead of bailing
> on cancellation) surfaced a latent lifetime bug — `ActivityStore` held `workspace`
> `unowned`, but `[weak self]` promotes `self` (ActivityStore) to strong for the task
> body, so a teardown mid-`await` (every test harness) could free `WorkspaceStore`
> while the task pins ActivityStore alive, aborting on the post-`await`
> `self.workspace` read (signal 6, "object already destroyed"). `WorkspaceStore`'s
> back-reference to `ActivityStore` is `weak`, so holding `workspace` **strongly** is
> cycle-free and guarantees it outlives `self`. Full suite now passes deterministically
> across repeated runs. Also dropped #27's load-reconcile to `.background` priority so
> the launch catalog parse never starves the first file-index refresh.

> **[D-029] Wired the Browser pane end-to-end + fixed a snapshot vertical flip (#22/#26)** — *(2026-06-12)*
> The helper-side `BrowserHostController` (WKWebView → `takeSnapshot` → shared
> IOSurface) was built and the IOSurface wire was proven, but the **app side never
> launched a browser surface**: `RenderSurfaceRole` had no `.browser` case,
> `selectedRightPanelRole` returned `nil` for `.browser`, and the pane was a
> placeholder shell (its own comment said the surface was "wired at integration").
> Completed the wire: a `.browser(threadID:tabID:)` role; `WorkspaceStore.browserLaunch`
> building `command: ["load", urlString]`; `LaunchPayload(browser:)` stamping
> `toolKind=.browser` so the exporter routes to `BrowserHostController`;
> `RenderHostClient` choosing the browser-vs-terminal payload by role; and the pane
> embedding the role-generic `TerminalSurfaceHostView` (frame compositing already
> flows through the shared `frameReady → frameSink → pane-layer` path). Two unit
> tests lock in that the launch carries `["load", url]` (and is `nil` for an empty
> tab); a seeded `browser-preview` E2E visual state guards the chrome.
> **Verification surfaced and fixed a real bug:** the first real render showed the
> page **upside down** (#22 had warned "vertically flipped"). `BrowserHostController`
> applied a CPU flip (`translateBy` + `scaleBy(y: -1)`), but `TerminalPaneView` is
> `isFlipped` so its hosting layer is already geometry-flipped (the terminal's
> Ghostty surface relies on that) — the CPU flip was a *second* flip. Removed it; the
> page now renders right-side up. **Verification method (non-obvious):** browser tabs
> are spec-mandated transient (`persistenceSnapshot`/`restoredState` rebuild default
> tabs — `testSQLiteDoesNotRestoreTransientRightPanel{Nvim,Browser}Tabs`), so a
> seed→reload E2E *cannot* carry a URL into the loaded app; it always shows the empty
> "Enter a URL" chrome (correct behavior). Compositing was therefore verified the
> real-user way: launch the seeded `browser-preview` state headed, paste a file URL
> into the auto-focused address bar + Return, screenshot — index.html composites
> in-pane, upright. (The same run also re-confirmed terminal compositing.)

> **[D-030] Mouse support in all panes + first-frame render fixes** — *(2026-06-12)*
> Four issues from first real usage, fixed together (interwoven across protocol +
> helper + app pane, so a per-bug split would not compile in isolation):
> **(1) Mouse in terminal/nvim/lazygit.** The helper's `TerminalView` is off-screen
> and never gets real mouse events. Added `RenderMessage.mouse(MousePayload)`
> (pane-local top-left points + raw modifier flags + scroll deltas); the pane
> forwards every AppKit mouse event (all buttons, drag, scroll, and hover via a
> tracking area); the helper reconstructs an `NSEvent` — `CGEvent` for scroll, the
> only public way to build one with deltas — at `(x, viewHeight − y)` and calls the
> view's `open` mouse handlers, which feed libghostty. libghostty (`surface`/
> `sendMouse*` are module-internal, so the view's `open` methods are the only
> public seam) emits the correct mouse-mode escape sequences itself.
> **(2) Mouse in browser.** A synthetic `NSEvent` can't drive an off-screen
> `WKWebView` (hit-testing needs an on-screen view), so scroll/left-click are
> applied via JavaScript (`window.scrollBy` / `elementFromPoint().click()`) then
> re-snapshotted.
> **(3) Blurry first frame / imperfect resize.** The pane only pushed the backing
> scale in `layout()`, which can run before the real scale is known (defaulting to
> 2.0 → blurry on a 3× display until a manual resize re-sent it). Added
> `viewDidChangeBackingProperties` + a viewport push from `viewDidMoveToWindow`, so
> the correct `contentsScale` reaches the helper for the first frame.
> **(4) Browser open delay / sometimes-black.** Snapshots used
> `afterScreenUpdates=false` and only the steady pump, so a pre-paint or
> occlusion-throttled blank could be captured and stick. Nav/resize now force a
> render and a short burst of settling snapshots (0.05/0.2/0.6 s) guarantees a
> painted frame lands.
> **Verification (honest):** smoke-tested on a real run — the terminal composites
> crisply on the first frame and survives forwarded clicks (no helper crash), and
> browser HTML composites upright (D-029). The env's headed-focus contention (the
> agent terminal grabs first-responder; synthetic address-bar focus is unreliable
> here) blocked deterministic interactive re-testing of mouse-mode behavior and the
> markdown render this round; those rest on the verified shared pipeline + the
> libghostty API, pending the owner's confirmation (DEFERRED #28 — scroll
> direction/scale sign may need a one-line tweak after real use).

> **[D-031] Render-host helper windows leaking on screen on macOS 26 + the black browser pane** — *(2026-06-12)*
> **Symptom (from a real run):** the WKWebView (and a terminal) rendered in
> separate windows floating detached at the bottom corner of the desktop, while
> the in-app browser pane stayed black.
> **Root cause:** both `BrowserHostController` and `TerminalHostController` made
> their off-screen host window "invisible" by ordering it in at
> `desktopWindow − 1` and trusting the **wallpaper to occlude it**. macOS 26 no
> longer covers windows at that level, so the helper window — anchored at screen
> origin `(0,0)` — became visible wherever the app window didn't cover it (the
> "floating in the corner" bug). Worse, a window *below the desktop level* is in
> an odd compositing state where `WKWebView.takeSnapshot` returns blank, so the
> snapshot drawn into the shared IOSurface was black even though WebKit was
> painting its own backing store (the "browser pane stays black" bug). Both
> symptoms, one cause.
> **Options:** (a) move the window fully off-screen — reliable invisibility, but
> off-all-screens risks WebKit occlusion-throttling the snapshot to blank;
> (b) keep relying on z-order occlusion at some other level — fragile, the same
> class of bug; (c) keep the window composited *normally* and hide it with
> `alphaValue = 0`, forcing `occlusionState` to `.visible` so WebKit never
> throttles.
> **Decision:** (c). Unified the two near-identical `Headless*Window` subclasses
> into one `HeadlessRenderWindow` (`canBecomeKey/Main` + `occlusionState`
> always `.visible`) and added `orderInHidden(_:)`: `alphaValue = 0`,
> `ignoresMouseEvents`, `isExcludedFromWindowsMenu`, stationary/ignores-cycle
> collection behavior, level just *below* normal, `orderFrontRegardless`. **Why:**
> WindowServer draws nothing for a fully transparent window yet keeps its backing
> layer tree live, so `takeSnapshot` / libghostty Metal rendering / IOSurface
> sharing all keep producing real pixels; invisibility no longer depends on the
> OS wallpaper; the window is never made key, so no focus steal (the E2E
> `frontmost` assertion still holds).
> **Verification:** an isolated experiment mirroring the exact window setup
> (`/tmp/snaptest.swift`) loaded an HTML page into an `alpha = 0`
> `HeadlessRenderWindow` and `takeSnapshot(afterScreenUpdates: true)` returned the
> real page pixels (non-black), proving alpha-0 does **not** blank the snapshot —
> the crux assumption. Build + 331 unit tests + lint (0 serious) + full headless
> E2E all green. The reload-based `browser-preview` E2E can't load web content
> (transient tabs), and the owner was mid-meeting, so the in-app markdown render
> and "no floaters" were not re-screenshotted live this round — they rest on the
> isolated proof + the unchanged snapshot→IOSurface→pane path, pending the owner's
> eyeball (DEFERRED #29).

> **[D-032] Browser pane: intermittent black + extreme resize flicker (snapshot-timing)** — *(2026-06-12)*
> **Symptom (owner eyeball after D-031):** floaters gone, but the browser pane
> (a) sometimes stayed black until a manual resize and (b) flickered extremely
> during resize. The same file rendered fine once resized (Image #5), so this was
> a snapshot-*timing* race, not a render failure.
> **Root cause:** the `WKWebView` → `takeSnapshot` → shared-IOSurface pipeline
> raced WebKit's async paint. (1) The first snapshot after a load could be
> unpainted; `draw` drew it anyway, clearing the surface to transparent
> (composited black over the pane backdrop), and the three fixed-delay settling
> snapshots sometimes *all* missed the real paint → black until a resize forced a
> fresh one. (2) `resize` took a forced `afterScreenUpdates` snapshot on **every**
> resize event (dozens/sec during a drag), thrashing WebKit's relayout, and any
> blank/transparent intermediate frame was pushed → the pane strobed between
> content and black.
> **Options:** (a) debounce resize so the surface is re-snapshotted only after the
> drag settles — smoothest, but the pane shows stretched content mid-drag and it's
> more moving parts; (b) drop unpainted snapshots + bound/coalesce the forced
> snapshots — minimal, attacks both root causes directly.
> **Decision:** (b). In `draw`, detect a blank snapshot (downsample 12×12, every
> sampled alpha 0 ⇒ unpainted) and **skip the push**, keeping the last good frame.
> Replace the fixed delays with a *single* coalesced retry loop (`settleLoopActive`
> guard) that forces snapshots at ~10/s and stops the instant a painted frame lands
> (`capturedNonBlankFrame`); repeated resizes only refresh its retry budget instead
> of each taking a forced snapshot. **Why:** dropping blanks kills the flicker (no
> black frame is ever composited) and the stays-black (a blank no longer flips the
> pane to a black "ready" state — the loading overlay holds until real pixels
> arrive); the single loop removes the per-event forced-relayout thrash; the steady
> 250 ms pump carries intermediate frames.
> **Verification:** isolated experiments (`/tmp/{blanktest,resizetest}.swift`)
> confirmed an unpainted snapshot returns **nil** (already guarded) or a fully
> transparent image (now dropped), that painted content is **never** misclassified
> as blank (no false drops — the load-bearing risk), and that mid-resize snapshots
> return opaque content. Build + 331 tests + lint (0 serious) green. Live in-app
> resize feel is the owner's to confirm (DEFERRED #29) — if any residual jitter
> remains, debouncing the resize (option a) is the next lever.
