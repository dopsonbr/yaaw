import Foundation

/// The kind of surface a render helper hosts.
///
/// A helper process is launched per surface and is permanently one kind: a
/// `.terminal` hosts a PTY + emulator, a `.browser` hosts a web view. The kind
/// is part of the launch handshake and never changes for a given helper.
public enum IsolatedToolKind: String, Codable, Equatable, Sendable {
    /// A browser/web-preview surface.
    case browser
    /// A PTY-backed terminal surface.
    case terminal
}
