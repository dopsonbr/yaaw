import Foundation
import IOSurface

/// The XPC interface a `YAAWRenderHost` helper exposes to the app.
///
/// The app encodes a ``RenderMessage`` to `Data` and sends it via
/// ``handleMessage(_:reply:)``. The reply block is `@escaping` so the helper can
/// unblock the app's calling thread immediately and complete the work
/// asynchronously; it returns an optional listener endpoint used to establish
/// the reverse (``YAAWRenderReplyProtocol``) channel.
@objc public protocol YAAWRenderServiceProtocol: NSObjectProtocol {
    /// Handles a single encoded ``RenderMessage``.
    ///
    /// - Parameters:
    ///   - messageData: A `Data`-encoded ``RenderMessage``.
    ///   - reply: Called (possibly later) with the reply-channel endpoint, or
    ///     `nil` if no endpoint is being vended for this message.
    func handleMessage(
        _ messageData: Data,
        reply: @escaping (NSXPCListenerEndpoint?) -> Void
    )
}

/// The XPC interface the app exposes to receive events from a helper.
///
/// Frame-ready notifications are delivered out of band via
/// ``frameReady(generation:surface:)`` so the helper's `IOSurface` is passed
/// natively over XPC (it is `NSSecureCoding`-compliant); the app sets it as its
/// pane layer's `contents`. (CAContext/CALayerHost remote-layer hosting — ADR-004
/// Candidate 1 — was found not to share the IOSurface-backed layer across
/// processes, so the shared-IOSurface path, Candidate 2, is used.) All other
/// events arrive as encoded ``RenderEvent`` values via ``eventReceived(_:)``.
@objc public protocol YAAWRenderReplyProtocol: NSObjectProtocol {
    /// A new frame is ready to composite.
    ///
    /// - Parameters:
    ///   - generation: Monotonic frame counter; the app drops stale frames.
    ///   - surface: The `IOSurface` the helper rendered into, shared natively
    ///     over XPC; the app displays it via `layer.contents`. `nil` only if the
    ///     surface couldn't be obtained yet.
    func frameReady(
        generation: UInt64,
        surface: IOSurface?
    )

    /// Delivers a single encoded ``RenderEvent``.
    ///
    /// - Parameter eventData: A `Data`-encoded ``RenderEvent``.
    func eventReceived(_ eventData: Data)
}
