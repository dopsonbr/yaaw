import Foundation

/// Reversible encoding of a working-directory path into a claude project
/// directory name.
///
/// The legacy encoding replaced every `/` with `-`, so `/a-b` and `/a/b` both
/// collapsed to `a-b` (a collision). This encoding first escapes any literal
/// `-` inside a path component as `--`, then joins components with a single
/// `-`, making the transform reversible:
///
/// - `/home/user/a-b`  →  `-home-user-a--b`
/// - `/home/user/a/b`  →  `-home-user-a-b`
/// - `/a-b-c`           →  `-a--b--c`
///
/// `decode` reverses it. Both legacy and escaped on-disk directory names are
/// matched when scanning, so existing sessions still resolve.
public enum ClaudeProjectPathEncoding {
    /// Encodes `path` to a reversible project-directory name (with a leading
    /// `-`, matching claude's absolute-path convention).
    public static func encode(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let escaped = components.map { component in
            component.replacingOccurrences(of: "-", with: "--")
        }
        return "-" + escaped.joined(separator: "-")
    }

    /// Decodes a project-directory name produced by ``encode(_:)`` back to an
    /// absolute path, or `nil` if `name` is not a valid encoding.
    public static func decode(_ name: String) -> String? {
        guard name.hasPrefix("-") else { return nil }
        let body = String(name.dropFirst())
        var components: [String] = []
        var current = ""
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "-" {
                let next = body.index(after: index)
                if next < body.endIndex, body[next] == "-" {
                    // Escaped literal hyphen.
                    current.append("-")
                    index = body.index(after: next)
                    continue
                }
                // Separator between components.
                components.append(current)
                current = ""
                index = next
                continue
            }
            current.append(character)
            index = body.index(after: index)
        }
        components.append(current)
        return "/" + components.joined(separator: "/")
    }

    /// The legacy (lossy) encoding: every `/` becomes `-`. Retained so existing
    /// on-disk directories created by the old scheme still resolve.
    public static func legacyEncode(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    /// Decodes a legacy directory name (`-home-user-project`) to a path, or
    /// `nil` if it is not a legacy absolute-path encoding.
    public static func legacyDecode(_ name: String) -> String? {
        guard name.hasPrefix("-") else { return nil }
        return name.replacingOccurrences(of: "-", with: "/")
    }
}
