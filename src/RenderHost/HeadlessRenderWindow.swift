import AppKit

/// The off-screen window that hosts a render surface (a libghostty `TerminalView`
/// or a `WKWebView`) inside the render-host helper. It is never shown to the user
/// — the app composites the surface's shared `IOSurface` into its own pane — but
/// it must stay *live and composited by the render server* so libghostty's Metal
/// renderer and `WKWebView.takeSnapshot` keep producing real pixels.
///
/// It can become key/main so the hosted view can be first responder if needed,
/// and it always reports its `occlusionState` as `.visible` so WebKit never
/// throttles painting on the (alpha-0, see ``orderInHidden(_:)``) window.
final class HeadlessRenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}

/// Orders a headless render window in while keeping it invisible to the user.
///
/// History: before macOS 26 the helper ordered this window *below the desktop
/// window level* and relied on the wallpaper to occlude it. macOS 26 no longer
/// covers that level, so the window became visible at the screen origin (the
/// "web view / terminal floating detached in the bottom corner" bug), and a
/// window below the desktop level is in an odd compositing state that can make
/// `WKWebView.takeSnapshot` return blank (the "browser pane stays black" bug).
///
/// Instead the window sits just below the normal window level — composited like
/// any ordinary window, so snapshots and Metal rendering work — and is hidden
/// with `alphaValue = 0`. WindowServer draws nothing to screen for a fully
/// transparent window, yet its backing layer tree is still maintained for
/// `takeSnapshot` / IOSurface sharing. `ignoresMouseEvents` stops the invisible
/// window from swallowing clicks meant for the app, and it is never made key, so
/// it never steals focus (the E2E `frontmost` assertion depends on this).
@MainActor
func orderInHidden(_ window: HeadlessRenderWindow) {
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.isExcludedFromWindowsMenu = true
    window.collectionBehavior.formUnion([.stationary, .ignoresCycle])
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
    window.orderFrontRegardless()
}
