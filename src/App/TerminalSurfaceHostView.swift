import AppKit
import IOSurface
import QuartzCore
import SwiftUI
import YAAWKit

/// SwiftUI host for a render-helper surface. Composites the helper's remote
/// layer inside the pane via `CALayerHost(contextID:)` (ADR-004 Candidate 1):
/// the helper publishes a `CAContext.contextID`, the window server shares the
/// layer tree, and we host it with native clipping/scrolling — no overlay window,
/// no viewport polling.
///
/// Input (key/mouse/scroll/paste) is forwarded to the `RenderHostClient` as raw
/// `RenderMessage.input` bytes. On `layout()` the view enforces `contentsScale`
/// per the display backing scale and sends a resize. Overlay states cover
/// launching / reconnecting / exited.
struct TerminalSurfaceHostView: NSViewRepresentable {
    @ObservedObject var client: RenderHostClient
    let role: RenderSurfaceRole
    let fonts: FontSettings

    func makeNSView(context: Context) -> TerminalPaneView {
        let view = TerminalPaneView()
        view.client = client
        view.role = role
        return view
    }

    func updateNSView(_ nsView: TerminalPaneView, context: Context) {
        nsView.client = client
        nsView.role = role
        nsView.apply(snapshot: client.snapshot(for: role), fonts: fonts)
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
    private var lastShownGeneration: UInt64 = 0
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

    /// Displays the latest shared IOSurface for this role. Re-asserts contents on
    /// each new frame generation; `setContentsChanged` forces a re-sample when the
    /// helper renders in place into the same surface.
    func apply(snapshot: RenderSurfaceSnapshot, fonts: FontSettings) {
        guard let client, let role else { return }
        guard snapshot.generation != lastShownGeneration else { return }
        lastShownGeneration = snapshot.generation
        let surface = client.surface(for: role)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface {
            // Re-assigning contents each generation forces CA to re-display; the
            // helper advances the generation only when the surface seed changes.
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
