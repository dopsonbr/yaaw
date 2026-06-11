import Foundation

/// Version of the render-helper wire protocol negotiated between the app and a
/// `YAAWRenderHost` helper at connection time.
///
/// The handshake replaces the old hardcoded "protocol v2": the app sends the
/// highest version it speaks, the helper replies with the version it selected,
/// and both sides downshift to the agreed value. Bump this when the Codable
/// envelopes or `@objc` XPC protocols change incompatibly.
public enum RenderProtocolVersion {
    /// The current protocol version this build speaks.
    public static let current: Int = 1

    /// Negotiates the protocol version two peers will use.
    ///
    /// Each side offers the highest version it speaks; the agreed version is the
    /// lower of the two highest (the highest version both peers understand).
    /// Returns `nil` when either offer is non-positive, signalling an
    /// incompatible peer that should be rejected rather than downshifted.
    ///
    /// - Parameters:
    ///   - appVersion: The highest version the app speaks
    ///     (defaults to ``current``).
    ///   - helperVersion: The highest version the helper speaks.
    /// - Returns: The agreed version, or `nil` if no compatible version exists.
    public static func negotiated(
        appVersion: Int = current,
        helperVersion: Int
    ) -> Int? {
        guard appVersion > 0, helperVersion > 0 else { return nil }
        return min(appVersion, helperVersion)
    }
}
