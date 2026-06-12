import AppKit
import IOSurface
import QuartzCore
import SwiftUI
import YAAWKit

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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
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
