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
    private let window: HeadlessBrowserWindow
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

    init(launch: LaunchPayload, reply: RenderEventReply) {
        self.reply = reply

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        self.webView = webView

        let window = HeadlessBrowserWindow(
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

        // The window must be ordered in for WebKit to render into a backing store
        // (an ordered-out web view snapshots blank). It stays invisible by sitting
        // below the desktop window level (the wallpaper occludes it) and is never
        // key (no focus steal) — exactly like the terminal helper window.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.orderFrontRegardless()

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
        captureSnapshot()
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
        // Page just committed its first paint; rasterize a few times to catch
        // images / async layout settling (the steady pump continues afterward).
        captureSnapshot()
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
    private func captureSnapshot() {
        guard !snapshotInFlight, surface != nil, webView.bounds.width > 0,
            webView.bounds.height > 0
        else { return }
        snapshotInFlight = true
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshotInFlight = false
                guard let image else { return }
                self.draw(image: image)
            }
        }
    }

    /// Draws `image` into the shared surface (vertically flipped: a snapshot is
    /// top-left origin, a `CGContext` is bottom-left) and publishes the frame.
    private func draw(image: NSImage) {
        guard let surface else { return }
        var proposed = CGRect(x: 0, y: 0, width: surfaceWidth, height: surfaceHeight)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return }
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
        // Flip: a snapshot CGImage is top-left origin, but the surface is sampled
        // by the pane layer top-left while CGContext draws bottom-left — without
        // this the page renders upside down.
        context.translateBy(x: 0, y: CGFloat(surfaceHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: rect)
        reply.frameReady(generation: nextGeneration(), surface: surface)
    }

    private func nextGeneration() -> UInt64 {
        frameGeneration &+= 1
        return frameGeneration
    }
}

/// A borderless, off-screen window that can become key so the hosted web view
/// is interactive while remaining invisible (compositing is remote).
private final class HeadlessBrowserWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
