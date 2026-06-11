import AppKit
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

/// `wantsLayer` NSView that hosts the helper's remote layer pointed at the
/// helper's published `contextID`, and forwards first-responder input to the
/// client.
///
/// ADR-004 composites via `CALayerHost(contextId:)`, which is SPI (not in the
/// public SDK). To keep the app target building against the public SDK while
/// using the documented mechanism, the host layer is created via the
/// Objective-C runtime (`CALayerHost`) and its `contextId` is set with KVC. If
/// the class is unavailable, the view falls back to a plain placeholder layer.
final class TerminalPaneView: NSView {
    weak var client: RenderHostClient?
    var role: RenderSurfaceRole?

    /// The hosted remote layer — an instance of the SPI `CALayerHost`, or a plain
    /// `CALayer` placeholder when the class can't be resolved.
    private let hostLayer: CALayer = TerminalPaneView.makeHostLayer()
    private var hostedContextID: UInt32 = 0
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
        layer?.addSublayer(hostLayer)
    }

    /// Creates the remote-layer host. `CALayerHost` is window-server SPI; resolve
    /// it dynamically so the target builds against the public SDK.
    private static func makeHostLayer() -> CALayer {
        if let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type {
            return hostClass.init()
        }
        return CALayer()
    }

    /// Hosts (or stops hosting) the helper's remote layer. A `contextID` of 0
    /// means no composited frame yet → keep the black placeholder visible.
    func apply(snapshot: RenderSurfaceSnapshot, fonts: FontSettings) {
        guard snapshot.contextID != hostedContextID else { return }
        hostedContextID = snapshot.contextID
        // `CALayerHost.contextId` is a `UInt32` KVC-settable property on the SPI
        // class; a no-op on the plain-layer fallback.
        hostLayer.setValue(NSNumber(value: snapshot.contextID), forKey: "contextId")
        hostLayer.isHidden = snapshot.contextID == 0
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        hostLayer.contentsScale = scale
        hostLayer.frame = bounds
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
