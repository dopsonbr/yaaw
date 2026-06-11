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
