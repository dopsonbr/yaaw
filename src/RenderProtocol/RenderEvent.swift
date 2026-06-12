import Foundation

/// An upbound event from a `YAAWRenderHost` helper to the app.
///
/// Events are binary-safe `Codable` envelopes. Frames are delivered out of band
/// via the `@objc` ``YAAWRenderReplyProtocol/frameReady(generation:surface:)`` —
/// the shared `IOSurface` is passed natively over XPC (ADR-004 Candidate 2) — so
/// no per-frame pixel data crosses this `Codable` channel.
public enum RenderEvent: Codable, Equatable, Sendable {
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
