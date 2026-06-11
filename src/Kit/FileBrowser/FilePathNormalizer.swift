import Foundation

/// Normalizes file paths into the project-relative, forward-slash form the file
/// browser, right-panel tabs, and icon resolver share.
///
/// Extracted from the file-browser index so the domain value types
/// (`RightPanelTab`, `FileIconResolver`) can depend on it without pulling in the
/// indexing/caching machinery, which lives in the `FileIndexActor` (Chunk B).
public enum FilePathNormalizer {
    /// The forward-slash, `.`-stripped path of `url` relative to `root`, or the
    /// last path component when `url` is not under `root`.
    public static func relativePath(for url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard path.hasPrefix(prefix) else { return normalizedRelativePath(url.lastPathComponent) }
        return normalizedRelativePath(String(path.dropFirst(prefix.count)))
    }

    /// Collapses backslashes to slashes, drops `.` segments, and removes empty
    /// components from a relative path string.
    public static func normalizedRelativePath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }

    /// Normalizes an ignore-rule string (trims whitespace, then normalizes the path).
    public static func normalizedRule(_ rule: String) -> String {
        normalizedRelativePath(rule.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
