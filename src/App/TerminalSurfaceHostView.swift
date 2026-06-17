import AppKit
import IOSurface
import QuartzCore
import SwiftUI
import YAAWKit
import YAAWRenderProtocol

/// SwiftUI host for a render-helper surface. Displays the helper's shared
/// `IOSurface` directly as the pane layer's `contents` (ADR-004 Candidate 2):
/// the helper renders into an `IOSurface` and shares it natively over XPC, and
/// the pane shows it with native clipping/scrolling — no overlay window, no
/// viewport polling. (CAContext/`CALayerHost` remote-layer hosting — Candidate 1
/// — was found not to share the IOSurface-backed layer cross-process.)
///
/// Frames are delivered through a non-`@Published` sink registered on the client,
/// so live output / cursor blink never re-invalidate SwiftUI. Input
/// (key/mouse/scroll/paste) is forwarded to the `RenderHostClient` as raw
/// `RenderMessage.input` bytes. On `layout()` the view enforces `contentsScale`
/// per the display backing scale and sends a resize. The lifecycle overlay
/// (launching / reconnecting / exited) is layered in SwiftUI by
/// `TerminalPlaceholderView`, driven by the `@Published` phase.
struct TerminalSurfaceHostView: NSViewRepresentable {
    @ObservedObject var client: RenderHostClient
    let role: RenderSurfaceRole
    let fonts: FontSettings

    func makeNSView(context: Context) -> TerminalPaneView {
        let view = TerminalPaneView()
        view.client = client
        view.role = role
        view.registerFrameSink()
        view.display(client.surface(for: role))
        return view
    }

    func updateNSView(_ nsView: TerminalPaneView, context: Context) {
        nsView.client = client
        nsView.role = role
        // Re-assert the sink (client/role may have changed) and re-show the latest
        // surface; this runs only on rare phase/title changes, not per frame.
        nsView.registerFrameSink()
        nsView.display(client.surface(for: role))
        nsView.scheduleViewportReport()
    }
}

/// `wantsLayer` NSView that displays the helper's shared `IOSurface` as its
/// layer `contents` (ADR-004 Candidate 2), and forwards first-responder input to
/// the client. CAContext/CALayerHost (Candidate 1) was found not to share the
/// IOSurface-backed layer across processes, so the surface is shared natively
/// over XPC and shown directly here.
final class TerminalPaneView: NSView {
    weak var client: RenderHostClient?
    var role: RenderSurfaceRole?

    /// The layer that displays the shared IOSurface (a sublayer over a black
    /// backdrop so unrendered frames read as a clean black pane).
    private let surfaceLayer = CALayer()
    private var lastReportedViewport: ResizePayloadKey?
    private var didRunE2EScrollbackAutoscroll = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        surfaceLayer.contentsGravity = .resize
        layer?.addSublayer(surfaceLayer)
    }

    /// Registers this pane's frame sink with the client so new frames are pushed
    /// straight to the layer (no `@Published`, no SwiftUI invalidation per frame).
    func registerFrameSink() {
        guard let client, let role else { return }
        client.setFrameSink(role: role) { [weak self] surface in
            self?.display(surface)
        }
    }

    /// Displays the shared IOSurface as the pane layer's contents. Re-assigning
    /// `contents` forces Core Animation to re-sample even when the helper rendered
    /// in place into the same surface object (the helper only pushes a frame when
    /// the surface seed actually advanced).
    func display(_ surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface {
            surfaceLayer.contents = surface
            surfaceLayer.isHidden = false
        } else {
            surfaceLayer.isHidden = true
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        surfaceLayer.contentsScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.frame = bounds
        CATransaction.commit()
        sendViewportIfNeeded(scale: scale)
    }

    private func sendViewportIfNeeded(scale: Double) {
        guard let client, let role, bounds.width > 0, bounds.height > 0 else { return }
        // Cell size is unknown to the app (the helper owns the font metrics); use
        // a conservative monospace estimate so the grid is approximately right.
        let cellWidth = 8.0
        let cellHeight = 17.0
        let columns = UInt32(max(1, bounds.width / cellWidth))
        let rows = UInt32(max(1, bounds.height / cellHeight))
        let widthPixels = UInt32(max(1, bounds.width * scale))
        let heightPixels = UInt32(max(1, bounds.height * scale))
        let key = ResizePayloadKey(
            columns: columns, rows: rows, widthPixels: widthPixels, heightPixels: heightPixels,
            scale: scale)
        guard key != lastReportedViewport else { return }
        lastReportedViewport = key
        client.setViewport(
            role: role,
            columns: columns,
            rows: rows,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            contentsScale: scale
        )
    }

    // MARK: - Input forwarding (raw bytes; no base64)

    /// Focus the pane on the *first* click even when its window only just became
    /// key (e.g. activating the app by clicking the terminal): without this the
    /// activating click is swallowed and the pane never becomes first responder.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.characters, !characters.isEmpty else {
            super.keyDown(with: event)
            return
        }
        forward(Data(characters.utf8))
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        forward(Data(text.utf8))
    }

    // MARK: - Mouse forwarding

    // All mouse events are forwarded to the helper surface (the real NSView lives
    // off-screen in the helper, so it never receives them directly). The terminal
    // helper feeds them to libghostty (mouse-mode escape sequences for
    // nvim/lazygit/less/etc.); the browser helper maps scroll/click to WebKit.
    // Positions are the pane-local point in this flipped (top-left) view, which
    // is the coordinate space the helper expects.

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardMouse(event, action: .down, button: .left)
    }
    override func mouseUp(with event: NSEvent) { forwardMouse(event, action: .up, button: .left) }
    override func mouseDragged(with event: NSEvent) {
        forwardMouse(event, action: .dragged, button: .left)
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardMouse(event, action: .down, button: .right)
    }
    override func rightMouseUp(with event: NSEvent) {
        forwardMouse(event, action: .up, button: .right)
    }
    override func rightMouseDragged(with event: NSEvent) {
        forwardMouse(event, action: .dragged, button: .right)
    }
    override func otherMouseDown(with event: NSEvent) {
        forwardMouse(event, action: .down, button: .middle)
    }
    override func otherMouseUp(with event: NSEvent) {
        forwardMouse(event, action: .up, button: .middle)
    }
    override func otherMouseDragged(with event: NSEvent) {
        forwardMouse(event, action: .dragged, button: .middle)
    }
    override func mouseMoved(with event: NSEvent) {
        forwardMouse(event, action: .moved, button: .left)
    }
    override func scrollWheel(with event: NSEvent) {
        forwardMouse(event, action: .scroll, button: .left)
    }

    /// A tracking area so `mouseMoved` (hover, no button) reaches this view
    /// without toggling the window-global `acceptsMouseMovedEvents`.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil))
    }

    private func forwardMouse(
        _ event: NSEvent, action: MousePayload.Action, button: MousePayload.Button
    ) {
        guard let client, let role else { return }
        let point = convert(event.locationInWindow, from: nil)
        client.sendMouse(
            role: role,
            payload: MousePayload(
                action: action,
                button: button,
                x: Double(point.x),
                y: Double(point.y),
                modifierFlags: event.modifierFlags.rawValue,
                scrollDeltaX: Double(event.scrollingDeltaX),
                scrollDeltaY: Double(event.scrollingDeltaY),
                hasPreciseScrolling: event.hasPreciseScrollingDeltas))
    }

    /// Auto-focuses the project terminal only when no text/control view already
    /// owns focus, and sends the initial backing scale before the first frame.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { applyBackingScaleAndReportViewport() }
        scheduleViewportReport()
        scheduleE2EScrollbackAutoscrollIfRequested()
        DispatchQueue.main.async { [weak self] in self?.claimProjectFocusIfAppropriate() }
    }

    /// Re-sends the viewport when the backing scale becomes known or changes.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScaleAndReportViewport()
    }

    private func applyBackingScaleAndReportViewport() {
        let scale = window?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        surfaceLayer.contentsScale = scale
        sendViewportIfNeeded(scale: scale)
    }

    func scheduleViewportReport(attemptsRemaining: Int = 8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.applyBackingScaleAndReportViewport()
            guard attemptsRemaining > 0, self.window != nil,
                (self.bounds.width <= 0 || self.bounds.height <= 0)
            else { return }
            self.scheduleViewportReport(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func claimProjectFocusIfAppropriate() {
        guard let window, case .project? = role else { return }
        guard Self.canClaimFocus(from: window.firstResponder) else { return }
        window.makeFirstResponder(self)
    }

    private func scheduleE2EScrollbackAutoscrollIfRequested() {
        guard !didRunE2EScrollbackAutoscroll, case .project? = role else { return }
        guard
            let rawDelta = ProcessInfo.processInfo.environment[
                "YAAW_E2E_SCROLLBACK_AUTOSCROLL_DELTA_Y"],
            let deltaY = Double(rawDelta)
        else { return }
        didRunE2EScrollbackAutoscroll = true
        sendE2EScrollbackAutoscroll(deltaY: deltaY, attemptsRemaining: 20)
    }

    private func sendE2EScrollbackAutoscroll(deltaY: Double, attemptsRemaining: Int) {
        guard let client, let role, bounds.width > 0, bounds.height > 0 else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sendE2EScrollbackAutoscroll(
                    deltaY: deltaY, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }
        let x = Double(bounds.midX)
        let y = Double(bounds.midY)
        for index in 0..<720 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(index) * 0.002) {
                client.sendMouse(
                    role: role,
                    payload: MousePayload(
                        action: .scroll,
                        x: x,
                        y: y,
                        scrollDeltaY: deltaY,
                        hasPreciseScrolling: true))
            }
        }
    }

    private static func canClaimFocus(from responder: NSResponder?) -> Bool {
        guard let responder else { return true }
        if responder is TerminalPaneView { return false }
        if responder is NSTextView || responder is NSTextField || responder is NSControl {
            return false
        }
        if let view = responder as? NSView, view.enclosingScrollView != nil {
            return false
        }
        return true
    }

    private func forward(_ data: Data) {
        guard let client, let role else { return }
        client.sendInput(role: role, data: data)
    }
}

/// De-dupes resize sends: a layout pass that produces the same grid/pixel size
/// must not re-message the helper.
private struct ResizePayloadKey: Equatable {
    var columns: UInt32
    var rows: UInt32
    var widthPixels: UInt32
    var heightPixels: UInt32
    var scale: Double
}
