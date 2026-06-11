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
}
