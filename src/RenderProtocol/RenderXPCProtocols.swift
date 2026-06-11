import Foundation

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
/// ``frameReady(generation:ioSurfaceRef:contextID:)`` so an `IOSurface` can be
/// passed natively (it is `NSSecureCoding`-compliant) without flowing through a
/// `Data` envelope; all other events arrive as encoded ``RenderEvent`` values
/// via ``eventReceived(_:)``.
@objc public protocol YAAWRenderReplyProtocol: NSObjectProtocol {
    /// A new frame is ready to composite.
    ///
    /// - Parameters:
    ///   - generation: Monotonic frame counter; the app drops stale frames.
    ///   - ioSurfaceRef: An `NSValue` wrapping an `IOSurfaceRef` (fallback
    ///     path), or `nil` when compositing via `CAContext`.
    ///   - contextID: A `CAContext.contextID` (primary path), or `0` when
    ///     compositing via IOSurface.
    func frameReady(
        generation: UInt64,
        ioSurfaceRef: NSValue?,
        contextID: UInt32
    )

    /// Delivers a single encoded ``RenderEvent``.
    ///
    /// - Parameter eventData: A `Data`-encoded ``RenderEvent``.
    func eventReceived(_ eventData: Data)
}
