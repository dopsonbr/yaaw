# 004: Render-Helper Cross-Process Compositing Mechanism

- **Status:** Accepted, then **revised by runtime outcome** — Candidate 1
  (CAContext) was found non-viable cross-process; **Candidate 2 (shared IOSurface)
  is the implemented, verified-working mechanism** (see "Outcome" below).
- **Affects:** [Rewrite master plan](../plans/rewrite/00-master-plan.md) Chunk D;
  `YAAWRenderProtocol`, `YAAWRenderHost`, `RenderHostClient`,
  `TerminalSurfaceHostView`.
- **Supersedes the overlay-window approach** used by the old `YAAWToolHost`.

## Outcome (2026-06-12, verified on a real run)

The spike was completed against the real Chunk-D code on a machine with screen +
accessibility. **Candidate 1 (CAContext + CALayerHost) is NOT viable** here: the
helper renders the terminal perfectly into libghostty's `IOSurfaceLayer` and
publishes a valid `CAContext.contextID`, and the app hosts it in a real
`CALayerHost`, but the window server does not share that layer's content to the
host process — the pane stays black even with the source window visible and
actively rendering. Per the "surface to the owner" clause below, this was brought
to the owner, who chose **Candidate 2 (shared IOSurface)**.

**Implemented & verified:** the helper shares the IOSurface backing its
`IOSurfaceLayer` natively over XPC (`frameReady(generation:surface:)`, IOSurface
whitelisted on the reply `NSXPCInterface`); the app displays it via
`layer.contents`. The helper window is ordered-in *below the desktop window level*
so libghostty's display link keeps rendering into the surface while the window
stays invisible and never key (no focus steal). The agent and bottom terminals
composite in-pane with no overlay window. The `frameReady` envelope still also
carries (now-unused) room for the CAContext path; the active path is IOSurface.
Follow-ups (browser-pane IOSurface, event-driven frame push, size/scale tuning)
are tracked in `docs/plans/rewrite/DEFERRED-ISSUES.md`.

## Context

The fixed point of the rewrite is **per-panel crash isolation**: the libghostty
emulator + PTY run in a per-surface helper process so a crash in one agent
panel/terminal can never take down the app or sibling panels. In-process
rendering is therefore ruled out.

The old design composited the helper's output by floating a borderless `NSWindow`
over a placeholder, steered by a 0.15 s viewport-polling loop with visibility
leases, z-order repair, and orphan watchdogs, over an NDJSON `[String:String]`
base64 IPC channel. That works but pays for it in idle CPU, latency, z-order
fragility, and "peek-over-sheet" visual bugs.

§0.1 of the rewrite requires choosing a cross-process compositing mechanism that
keeps crash isolation while eliminating overlay windows and viewport polling, and
composites the helper's rendered output **inside the real pane** with native
clipping/layering.

## Options

1. **Remote layer hosting — `CAContext` + `CALayerHost`.** The helper keeps
   rendering into its existing `CAMetalLayer`, wraps it in a `CAContext`, and
   publishes the context's `contextID` (a small integer) to the main app over
   XPC. The main app hosts it with a `CALayerHost { layerHost.contextId = … }`
   inside the pane's `wantsLayer` view. This is the exact mechanism
   WebKit/QuickLook/video use for cross-process layer compositing. **It does not
   require touching libghostty's render target** — the wrapper renders exactly as
   it does today. `CAContext`/`CALayerHost`/`contextID` are SPI but have been
   stable for many macOS releases.

2. **Shared IOSurface ring.** The helper renders into a shared `IOSurface`
   (double/triple-buffered ring), passes it over `NSXPCConnection` (IOSurface is
   `NSSecureCoding`), and the main app sets `layer.contents = surface` in a
   `wantsLayer` host view, gated by a `frameReady(generation:)` handshake.
   Zero-copy and fully public API on the main side, **but** exposing the
   per-frame IOSurface from libghostty's renderer needs either a thin SPI bridge
   in `YAAWRenderHost` or a patch via the package's `Patches/` mechanism — extra
   risk against the `libghostty-spm` 1.2.4 pin.

3. **Last-resort fallback — improved out-of-process overlay window.**
   Event-driven positioning (no 150 ms poll), no z-order repair loop. Still
   crash-isolated, but keeps some overlay edge cases (Spaces/Mission Control,
   peek-over-sheet). Only if 1 and 2 both prove non-viable on 1.2.4.

## Decision

**Adopt Candidate 1 (`CAContext` + `CALayerHost` remote layer hosting).**

Rationale:
- Lowest risk to the libghostty pin: the wrapper's render target is untouched;
  it keeps rendering into its `CAMetalLayer` exactly as today. We only need to
  obtain/create a `CAContext` over that layer and ship the `contextID` up.
- It is the same mechanism Apple's own frameworks use for cross-process
  compositing of a remote process's layer tree — well-trodden.
- It eliminates the overlay window, the 0.15 s viewport poll, visibility leases,
  z-order repair, and orphan watchdogs in one move: the hosted layer participates
  in the main app's layer tree, so clipping, scrolling, Spaces, and screenshots
  are all native.
- The `contextID` is a small `UInt32` — trivially `Codable`/XPC-friendly, no
  per-frame data crosses the boundary at all (the layer tree is shared by the
  window server).

If Candidate 1 fails to composite cleanly at display rate on 1.2.4 (tearing,
scale-drift that can't be corrected, or `CAContext` over the wrapper's layer not
hostable), fall back to Candidate 2, then Candidate 3, surfacing the perf/UX
trade-off to the owner before adopting the overlay fallback.

### Spike validation strategy

Per decision **D-003** in `DECISIONS-LOG.md`, no throwaway demo is built. The
spike's go/no-go criteria are validated directly against the real Chunk-D
`RenderHostClient` + `TerminalSurfaceHostView` (which is ~90% the same code as a
demo would be):

- **Resize correctness** — main → helper pixel size; helper re-fits the grid;
  `contentsScale` set per backing scale; replicate the coordinator's
  `onPostRender` scale-drift correction. No visible jump on pane drag, sidebar
  collapse, or theme toggle.
- **Input proxying** — pane view is first responder; key/mouse/scroll forwarded
  over XPC; helper injects into the surface. Minimum bar: ASCII, modifiers,
  paste, Enter. IME/marked-text/dead-keys recorded; any gap filed as a tracked
  acceptance exception, never silently regressed.
- **No focus steal** — helper is faceless/accessory with no window; main owns
  focus (E2E `frontmost` check).
- **Crash isolation** — `kill -9` the helper mid-render; app survives, pane goes
  to "reconnecting", relaunch + viewport replay + CLI session resume restore it.

## Consequences

- Ghostty types stay confined to `YAAWRenderHost`. `YAAWRenderProtocol` carries
  only the `contextID` (`UInt32`) + typed Codable events; no Ghostty types, no
  IOSurface handles in the common path.
- `RenderHostClient` (main-side actor) owns helper lifecycle; the XPC
  invalidation handler reaps + relaunches on helper death.
- The compositing handshake is a `frameReady`/`contextID`-update event, not a
  per-frame buffer copy.
- Documented risks (IME, scale-drift, handle leaks) are tracked in the master
  plan's Risks table and verified by the Chunk-G crash-isolation probe.
