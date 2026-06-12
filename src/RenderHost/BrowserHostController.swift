import AppKit
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
/// browser-specific cases, so nav reuses the binary-safe input envelope). The
/// web view renders into a headless, off-screen window whose layer is hosted
/// remotely (ADR-004); title / loading / nav state are forwarded as
/// ``RenderEvent``s.
@MainActor
final class BrowserHostController: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let window: HeadlessBrowserWindow
    private let reply: RenderEventReply

    private var frameGeneration: UInt64 = 0
    private var lastSurfaceSeed: UInt32 = .max
    private var currentURLString: String?
    private var isLoadingMarkdownPreview = false

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
        window.orderOut(nil)

        publishContextIfNeeded()

        // Initial URL: `["load", urlString]`.
        if launch.command.first == "load", launch.command.count > 1 {
            load(urlString: launch.command[1])
        }
    }

    /// Resizes the off-screen web view and re-asserts the frame handshake.
    func resize(_ payload: ResizePayload) {
        if payload.widthPixels > 0, payload.heightPixels > 0, payload.contentsScale > 0 {
            let pointWidth = CGFloat(payload.widthPixels) / CGFloat(payload.contentsScale)
            let pointHeight = CGFloat(payload.heightPixels) / CGFloat(payload.contentsScale)
            let frame = NSRect(x: 0, y: 0, width: max(1, pointWidth), height: max(1, pointHeight))
            window.setFrame(frame, display: false, animate: false)
            webView.frame = NSRect(origin: .zero, size: frame.size)
        }
        applyContentsScale(payload.contentsScale)
        publishContextIfNeeded()
        publishFrame()
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

    // MARK: - Compositing (shared IOSurface — ADR-004 Candidate 2)
    //
    // NOTE: WKWebView hosts its content in WebKit's own process via a remote
    // layer, so its backing layer does not expose a plain IOSurface the way the
    // Ghostty IOSurfaceLayer does. Browser-pane compositing therefore needs its
    // own mechanism (e.g. periodic WKWebView.takeSnapshot into an IOSurface) and
    // is tracked separately; this keeps the structure parallel to the terminal.

    private func publishContextIfNeeded() { publishFrame() }

    private func applyContentsScale(_ contentsScale: Double) {
        guard contentsScale > 0, let layer = webView.layer else { return }
        layer.contentsScale = CGFloat(contentsScale)
    }

    private func publishFrame() {
        guard let contents = webView.layer?.contents else { return }
        let cf = contents as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else { return }
        let surface = cf as! IOSurface
        let seed = IOSurfaceGetSeed(surface)
        guard seed != lastSurfaceSeed else { return }
        lastSurfaceSeed = seed
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
