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
