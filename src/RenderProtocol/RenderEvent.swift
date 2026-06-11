import Foundation

/// An upbound event from a `YAAWRenderHost` helper to the app.
///
/// Events are binary-safe `Codable` envelopes. The compositing handshake
/// (``frameReady(generation:ioSurfaceRef:contextID:)``) carries both a
/// `CAContext.contextID` (Candidate 1, the primary path per ADR-004) and an
/// optional `IOSurface` reference (Candidate 2, the fallback path); the app uses
/// whichever the helper populated. No per-frame pixel data crosses this channel.
public enum RenderEvent: Codable, Equatable, Sendable {
    /// A new frame is ready to composite.
    ///
    /// - Parameters:
    ///   - generation: Monotonic counter; the app drops frames older than the
    ///     last one it rendered.
    ///   - ioSurfaceRef: An `IOSurfaceRef` mach port value (IOSurface fallback
    ///     path), or `nil` when compositing via `CAContext`.
    ///   - contextID: A `CAContext.contextID` (primary path), or `0` when
    ///     compositing via IOSurface.
    case frameReady(generation: UInt64, ioSurfaceRef: UInt64?, contextID: UInt32)
    /// The surface title changed.
    case title(String)
    /// Parsed activity state from the capture log.
    case activity(ActivityPayload)
    /// A CLI session identifier surfaced via shell integration.
    case sessionId(String)
    /// The terminal bell rang.
    case bell
    /// A desktop notification request from the surface.
    case notification(title: String, body: String)
    /// The working directory changed (shell-integration `pwd`).
    case pwd(String)
    /// A shell command finished.
    case commandFinished(exitCode: Int?, durationNanos: UInt64)
    /// The hosted process exited with the given code (`nil` if signal-killed).
    case exited(Int32?)
    /// The circular capture buffer overflowed and discarded earlier bytes.
    case captureTruncated(truncatedAtByte: UInt64)
}

/// Parsed activity state from the terminal capture log, sent in
/// ``RenderEvent/activity(_:)``.
public struct ActivityPayload: Codable, Equatable, Sendable {
    /// The parsed invocation or running command.
    public var activity: String
    /// Whether the command is currently running.
    public var isRunning: Bool

    /// Creates an activity payload.
    public init(activity: String, isRunning: Bool) {
        self.activity = activity
        self.isRunning = isRunning
    }
}
