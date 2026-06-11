import Foundation

/// Fingerprints catalog files by size + modification time so the actor's cache
/// can detect in-place edits.
///
/// `contentModificationDate` is sub-second on APFS, so in-place edits are
/// detected; the only blind spot is a same-size rewrite within one mtime tick on
/// a coarse (1 s) filesystem, which is acceptable for session catalogs.
enum CatalogSignature {
    /// A stable, order-independent combination of the given part signatures.
    static func combined(_ parts: [String]) -> String {
        parts.sorted().joined(separator: "\n")
    }

    /// A `path:kind:size:mtime` fingerprint for one file or directory; a missing
    /// path fingerprints as `path:missing`.
    static func fileSignature(for url: URL) -> String {
        guard
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isDirectoryKey,
                .isRegularFileKey,
            ])
        else {
            return "\(url.standardizedFileURL.path):missing"
        }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        let kind =
            values.isDirectory == true
            ? "directory"
            : values.isRegularFile == true ? "file" : "other"
        return "\(url.standardizedFileURL.path):\(kind):\(size):\(modified)"
    }
}
