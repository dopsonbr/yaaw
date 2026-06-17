import AppKit
import CoreVideo
import Darwin
import Foundation
import IOSurface
import WebKit
import YAAWKit
import YAAWRenderProtocol

/// Hosts a `WKWebView` out-of-process for the Browser / file-preview surface.
///
/// Much simpler than the terminal path: no PTY, no capture log, no grid. The
/// initial URL arrives in the launch `command` as `["load", urlString]`;
/// subsequent navigation (back/forward/reload/stop/load) arrives as text
/// commands over the `input` channel (the typed `RenderMessage` set has no
/// browser-specific cases, so nav reuses the binary-safe input envelope).
///
/// **Compositing (ADR-004 Candidate 2):** unlike Ghostty's `IOSurfaceLayer`, a
/// `WKWebView` renders in WebKit's own process behind a remote layer, so its
/// backing layer never exposes a plain `IOSurface` we can share. Instead the
/// helper rasterizes the web view with `takeSnapshot` and draws each snapshot
/// into a shared `IOSurface` it owns, which the app displays as its pane layer's
/// `contents` — same wire path as the terminal. Snapshots are taken on
/// navigation/load + resize and on a modest timer (so async content and scrolling
/// reach the pane) and skipped when nothing changed.
@MainActor
final class BrowserHostController: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let window: HeadlessRenderWindow
    private let reply: RenderEventReply

    private var frameGeneration: UInt64 = 0
    private var currentURLString: String?
    private var isLoadingMarkdownPreview = false

    /// The shared surface the app composites, plus its pixel size + scale.
    private var surface: IOSurface?
    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var contentsScale: CGFloat = 2.0
    /// Coalesces overlapping `takeSnapshot` calls (the previous one is async).
    private var snapshotInFlight = false
    /// Drives periodic snapshots so async page rendering / scrolling reaches the
    /// pane. WebKit owns the actual rendering; this just re-rasterizes.
    private var snapshotTimer: DispatchSourceTimer?
    /// Forced-snapshot retries left in the current settle session, whether a painted
    /// (non-blank) frame has landed since it began, and whether a settle loop is
    /// already running — see ``scheduleSettlingSnapshots()``.
    private var settleAttemptsRemaining = 0
    private var capturedNonBlankFrame = false
    private var settleLoopActive = false

    init(launch: LaunchPayload, reply: RenderEventReply) {
        self.reply = reply

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        self.webView = webView

        let window = HeadlessRenderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.window = window

        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // The window must be ordered in (and composited normally) for WebKit to
        // render into a backing store: an ordered-out web view snapshots blank,
        // and so does one ordered below the desktop window level on macOS 26. It
        // stays invisible via `orderInHidden` (alpha 0, occlusionState forced
        // visible so WebKit never throttles) rather than the old below-the-
        // wallpaper trick, which macOS 26 no longer hides — that left the web view
        // floating in the screen corner and snapshotting black.
        orderInHidden(window)

        startSnapshotPump()

        // Initial URL: `["load", urlString]`.
        if launch.command.first == "load", launch.command.count > 1 {
            load(urlString: launch.command[1])
        }
    }

    /// Resizes the off-screen web view, (re)allocates the shared surface at the new
    /// pixel size, and re-rasterizes.
    func resize(_ payload: ResizePayload) {
        if payload.widthPixels > 0, payload.heightPixels > 0, payload.contentsScale > 0 {
            contentsScale = CGFloat(payload.contentsScale)
            let pointWidth = CGFloat(payload.widthPixels) / contentsScale
            let pointHeight = CGFloat(payload.heightPixels) / contentsScale
            let frame = NSRect(x: 0, y: 0, width: max(1, pointWidth), height: max(1, pointHeight))
            window.setFrame(frame, display: false, animate: false)
            webView.frame = NSRect(origin: .zero, size: frame.size)
            ensureSurface(width: Int(payload.widthPixels), height: Int(payload.heightPixels))
        }
        // Re-settle: keep forcing snapshots until WebKit finishes relaying out at the
        // new size and a painted frame lands. Blank intermediate snapshots are
        // dropped (see `draw`), so the pane holds the last good frame rather than
        // flickering to black through a drag-resize.
        scheduleSettlingSnapshots()
    }

    /// Browser navigation arrives as a UTF-8 command over the input channel.
    func handleInput(_ data: Data) {
        guard let command = String(data: data, encoding: .utf8) else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "back":
            webView.goBack()
        case "forward":
            webView.goForward()
        case "reload":
            reload()
        case "stop":
            webView.stopLoading()
            publishState()
        default:
            if trimmed.hasPrefix("load ") {
                load(urlString: String(trimmed.dropFirst("load ".count)))
            }
        }
    }

    /// Browser mouse support. The off-screen `WKWebView` can't consume synthetic
    /// `NSEvent`s (hit-testing needs an on-screen view), so scroll and left-click
    /// are applied via JavaScript against the page's own viewport coordinates
    /// (the pane sends top-left points, which match CSS pixels here), then a fresh
    /// snapshot is taken so the change reaches the pane.
    func handleMouse(_ payload: MousePayload) {
        switch payload.action {
        case .scroll:
            // Negated so a natural two-finger / wheel gesture moves the page the
            // expected direction (AppKit scroll deltas vs. window.scrollBy sign).
            let deltaX = -payload.scrollDeltaX
            let deltaY = -payload.scrollDeltaY
            evaluateJavaScript("window.scrollBy(\(deltaX), \(deltaY));", forceRender: false)
        case .up where payload.button == .left:
            let x = Int(payload.x.rounded())
            let y = Int(payload.y.rounded())
            evaluateJavaScript(
                "var __el = document.elementFromPoint(\(x), \(y)); if (__el) { __el.click(); }",
                forceRender: true)
        default:
            break
        }
    }

    private func evaluateJavaScript(_ script: String, forceRender: Bool) {
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.captureSnapshot(forcingRender: forceRender) }
        }
    }

    func terminate() {
        snapshotTimer?.cancel()
        snapshotTimer = nil
        webView.stopLoading()
        window.orderOut(nil)
        window.contentView = nil
    }

    // MARK: - Navigation

    private func load(urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }
        currentURLString = urlString
        if url.isFileURL {
            loadFileURL(url)
        } else {
            webView.load(URLRequest(url: url))
        }
        publishState()
    }

    private func loadFileURL(_ url: URL) {
        if MarkdownPreviewRenderer.isMarkdownURL(url) {
            loadMarkdownFile(url)
        } else {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    private func loadMarkdownFile(_ url: URL) {
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return }
        let html = MarkdownPreviewRenderer.renderHTML(markdown: markdown, sourceURL: url)
        currentURLString = url.absoluteString
        isLoadingMarkdownPreview = true
        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }

    private func reload() {
        if webView.url != nil {
            webView.reload()
        } else {
            load(urlString: currentURLString)
        }
        publishState()
    }

    // MARK: - Events

    private func publishState() {
        reply.send(
            .activity(ActivityPayload(activity: stateActivity, isRunning: webView.isLoading)))
    }

    private var stateActivity: String {
        webView.url?.absoluteString ?? currentURLString ?? ""
    }

    // MARK: - WKNavigationDelegate

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        publishState()
        captureSnapshot()
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
            MarkdownPreviewRenderer.isMarkdownURL(url),
            url.absoluteString != currentURLString
        {
            currentURLString = url.absoluteString
            loadMarkdownFile(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        if isLoadingMarkdownPreview {
            isLoadingMarkdownPreview = false
        } else {
            currentURLString = webView.url?.absoluteString ?? currentURLString
        }
        publishState()
        reply.send(.title(webView.title ?? ""))
        // Page just committed its first paint; keep forcing snapshots until a
        // painted (non-blank) frame actually lands, so the pane never stays black
        // when WebKit paints later than a fixed delay would have guessed.
        scheduleSettlingSnapshots()
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        publishState()
        // Loud failure: the web content process died. Exit non-zero so the app's
        // invalidation handler treats it as a crash and relaunches the pane.
        Darwin.exit(89)
    }

    func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        // Surface a target=_blank navigation request as activity; the app
        // decides whether to open a new surface.
        if navigationAction.targetFrame == nil,
            let urlString = navigationAction.request.url?.absoluteString
        {
            reply.send(.activity(ActivityPayload(activity: urlString, isRunning: false)))
        }
        return nil
    }

    // MARK: - Compositing (snapshot -> shared IOSurface — ADR-004 Candidate 2)

    private func startSnapshotPump() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.captureSnapshot() }
        }
        timer.resume()
        snapshotTimer = timer
    }

    /// (Re)allocates the shared BGRA surface when the pane pixel size changes.
    private func ensureSurface(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != surfaceWidth || height != surfaceHeight || surface == nil else { return }
        surface = IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: width * 4,
            .pixelFormat: Int(kCVPixelFormatType_32BGRA),
        ])
        surfaceWidth = width
        surfaceHeight = height
    }

    /// Rasterizes the web view and draws it into the shared surface, then notifies
    /// the app. Coalesced: a snapshot already in flight skips this tick.
    /// Rasterizes the web view into the shared surface. `forcingRender` sets
    /// `afterScreenUpdates`, which makes WebKit run a layout+paint pass before the
    /// snapshot — essential right after a load/resize (otherwise the snapshot can
    /// capture a pre-paint blank, the "stays black" symptom) but too costly to do
    /// on every steady-state pump tick, so the pump leaves it off.
    private func captureSnapshot(forcingRender: Bool = false) {
        guard surface != nil, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        // A forced-render request always runs (it must land a painted frame); only
        // best-effort pump ticks coalesce behind an in-flight snapshot.
        if snapshotInFlight, !forcingRender { return }
        snapshotInFlight = true
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.afterScreenUpdates = forcingRender
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshotInFlight = false
                guard let image else { return }
                self.draw(image: image)
            }
        }
    }

    /// After a load/resize, keep forcing snapshots — a `WKWebView` paints async, so
    /// the first attempts after a load can come back unpainted — until a painted
    /// frame lands or a bounded number of attempts elapse. The previous fixed set of
    /// delays raced WebKit's paint and sometimes *all* missed, leaving the pane black
    /// until a manual resize.
    ///
    /// Crucially this runs *at most one* loop: a drag-resize fires `resize` (hence
    /// this) dozens of times a second, and the old code took a forced
    /// `afterScreenUpdates` snapshot on each — thrashing WebKit's relayout and
    /// strobing the pane. Here repeated calls only refresh the retry budget; a
    /// single loop drives forced snapshots at ~10/s and stops the instant a real
    /// frame is captured (`draw` sets `capturedNonBlankFrame`). The steady pump's
    /// cheap non-forced snapshots carry intermediate frames in the meantime.
    private func scheduleSettlingSnapshots() {
        capturedNonBlankFrame = false
        settleAttemptsRemaining = 16  // ~1.6 s of retries at 0.1 s spacing
        guard !settleLoopActive else { return }
        settleLoopActive = true
        settleTick()
    }

    private func settleTick() {
        guard settleAttemptsRemaining > 0, !capturedNonBlankFrame else {
            settleLoopActive = false
            return
        }
        settleAttemptsRemaining -= 1
        captureSnapshot(forcingRender: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.settleTick()
        }
    }

    /// Draws `image` into the shared surface (vertically flipped: a snapshot is
    /// top-left origin, a `CGContext` is bottom-left) and publishes the frame.
    private func draw(image: NSImage) {
        guard let surface else { return }
        var proposed = CGRect(x: 0, y: 0, width: surfaceWidth, height: surfaceHeight)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return }
        // Drop unpainted snapshots: keep the last good frame rather than clearing the
        // pane to black. This is what fixes both the intermittent black pane (a blank
        // first snapshot no longer flips the pane to a black "ready" state) and the
        // resize flicker (blank mid-relayout frames during a drag are no longer
        // pushed, so the pane holds the last good frame instead of strobing).
        if isBlank(cgImage) { return }
        capturedNonBlankFrame = true
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        guard
            let context = CGContext(
                data: IOSurfaceGetBaseAddress(surface),
                width: surfaceWidth,
                height: surfaceHeight,
                bitsPerComponent: 8,
                bytesPerRow: IOSurfaceGetBytesPerRow(surface),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return }
        let rect = CGRect(x: 0, y: 0, width: surfaceWidth, height: surfaceHeight)
        context.clear(rect)
        // No CPU flip: the pane that composites this surface (`TerminalPaneView`)
        // is `isFlipped` — its hosting layer is geometry-flipped, so it already
        // samples the surface top-down (the terminal's Ghostty-rendered surface
        // relies on the same). `CGContext.draw` writes the top-left-origin snapshot
        // bottom-up into the surface, which the flipped layer reads back upright;
        // adding a `scaleBy(y: -1)` here double-flips it (page renders upside down,
        // verified on a real run).
        context.draw(cgImage, in: rect)
        reply.frameReady(generation: nextGeneration(), surface: surface)
    }

    /// Rejects transparent or black pre-paint WebKit snapshots so preview panes
    /// keep showing the loading state instead of a black frame. Legitimate
    /// documents can be mostly solid white (or otherwise sparse), so those must
    /// be accepted and allowed to update through the snapshot pump.
    private func isBlank(_ cgImage: CGImage) -> Bool {
        let side = 32
        let byteCount = side * side * 4
        var pixels = [UInt8](repeating: 0, count: byteCount)
        return pixels.withUnsafeMutableBytes { raw in
            guard let baseAddress = raw.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            var firstVisibleRGB: (red: UInt8, green: UInt8, blue: UInt8)?
            var variantPixelCount = 0
            var visiblePixelCount = 0
            var pureBlackPixelCount = 0
            for index in stride(from: 0, to: byteCount, by: 4) {
                let red = raw[index]
                let green = raw[index + 1]
                let blue = raw[index + 2]
                let alpha = raw[index + 3]
                guard alpha > 0 else { continue }
                visiblePixelCount += 1
                if red < 8 && green < 8 && blue < 8 {
                    pureBlackPixelCount += 1
                }
                guard let first = firstVisibleRGB else {
                    firstVisibleRGB = (red, green, blue)
                    continue
                }
                if abs(Int(red) - Int(first.red)) > 10
                    || abs(Int(green) - Int(first.green)) > 10
                    || abs(Int(blue) - Int(first.blue)) > 10
                {
                    variantPixelCount += 1
                    if variantPixelCount >= 6 { return false }
                }
            }
            guard visiblePixelCount > 0 else { return true }
            let blackRatio = Double(pureBlackPixelCount) / Double(visiblePixelCount)
            return blackRatio > 0.95 && variantPixelCount < 6
        }
    }

    private func nextGeneration() -> UInt64 {
        frameGeneration &+= 1
        return frameGeneration
    }
}
