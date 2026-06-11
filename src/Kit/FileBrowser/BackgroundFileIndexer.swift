import Foundation

/// Indexes a directory tree off the main thread and reports the result through a
/// completion handler. Pure filesystem walk: the actor (and the cache) layer on
/// dedup, persistence, and watching.
public protocol FileIndexing: AnyObject, Sendable {
    /// Indexes the full tree under `root`, applying `ignoreRules`.
    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    )

    /// Indexes a single pruned subtree on demand. `relativeSubpath` is the path of
    /// the pruned directory relative to `root`. The returned entries (including the
    /// subtree root itself, un-pruned) use paths relative to `root`, so they can be
    /// merged directly into the full index.
    func indexSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    )
}

/// Concurrent-queue-backed `FileIndexing`. Holds only an immutable `DispatchQueue`,
/// so it is `Sendable` with no `@unchecked` escape.
public final class BackgroundFileIndexer: FileIndexing {
    private let queue: DispatchQueue

    /// Creates an indexer running its walks on `queue` (a concurrent, user-initiated
    /// queue by default).
    public init(
        queue: DispatchQueue = DispatchQueue(
            label: "dev.dopsonbr.YAAW.file-index",
            qos: .userInitiated,
            attributes: .concurrent
        )
    ) {
        self.queue = queue
    }

    public func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        let root = root.standardizedFileURL
        queue.async {
            completion(
                Result {
                    try Self.buildIndex(
                        threadID: threadID, root: root, ignoreRules: ignoreRules,
                        fileManager: .default)
                })
        }
    }

    public func indexSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        let root = root.standardizedFileURL
        let subpath = FilePathNormalizer.normalizedRelativePath(relativeSubpath)
        queue.async {
            completion(
                Result {
                    try Self.buildSubtreeIndex(
                        threadID: threadID, root: root, relativeSubpath: subpath,
                        ignoreRules: ignoreRules, fileManager: .default)
                })
        }
    }

    /// Indexes the subtree rooted at `relativeSubpath`, re-applying ignore rules
    /// within it (so nested heavy directories stay pruned), and returns entries
    /// whose paths are relative to `root`. Includes the subtree root itself as an
    /// un-pruned directory so a merge flips the original pruned node to "loaded".
    public static func buildSubtreeIndex(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        fileManager: FileManager = .default,
        indexedAt: Date = Date()
    ) throws -> FileIndexResult {
        guard !relativeSubpath.isEmpty else {
            return try buildIndex(
                threadID: threadID, root: root, ignoreRules: ignoreRules,
                fileManager: fileManager, indexedAt: indexedAt)
        }
        let subRoot = root.appendingPathComponent(relativeSubpath).standardizedFileURL
        let subResult = try buildIndex(
            threadID: threadID, root: subRoot, ignoreRules: ignoreRules,
            fileManager: fileManager, indexedAt: indexedAt)
        var entries = reprefix(entries: subResult.entries, under: relativeSubpath)
        entries.insert(
            FileBrowserEntry(relativePath: relativeSubpath, isDirectory: true, isPruned: false),
            at: 0)
        entries.sort(by: FileBrowserTreeBuilder.sortEntriesForTree)
        return FileIndexResult(
            entries: entries,
            metadata: FileIndexMetadata(
                threadID: threadID,
                rootPath: root.path,
                indexedAt: indexedAt,
                fileCount: entries.count,
                ignoredDirectoryCount: subResult.metadata.ignoredDirectoryCount
            )
        )
    }

    private static func reprefix(entries: [FileBrowserEntry], under prefix: String)
        -> [FileBrowserEntry]
    {
        entries.map { entry in
            FileBrowserEntry(
                relativePath: "\(prefix)/\(entry.relativePath)",
                isDirectory: entry.isDirectory,
                isPruned: entry.isPruned
            )
        }
    }

    /// Enumerates `root`, pruning ignored directories (kept as collapsed entries),
    /// and returns the entries sorted in depth-first pre-order.
    public static func buildIndex(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        fileManager: FileManager = .default,
        indexedAt: Date = Date()
    ) throws -> FileIndexResult {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw FileBrowserIndexError.missingRoot(root.path)
        }

        let ignoreMatcher = FileBrowserIgnoreMatcher(rules: ignoreRules)
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )
        else {
            throw FileBrowserIndexError.missingRoot(root.path)
        }
        let walk = try walkEntries(
            enumerator: enumerator, root: root, ignoreMatcher: ignoreMatcher)
        var entries = walk.entries
        entries.sort(by: FileBrowserTreeBuilder.sortEntriesForTree)
        return FileIndexResult(
            entries: entries,
            metadata: FileIndexMetadata(
                threadID: threadID,
                rootPath: root.path,
                indexedAt: indexedAt,
                fileCount: entries.count,
                ignoredDirectoryCount: walk.ignoredDirectoryCount
            )
        )
    }

    private static func walkEntries(
        enumerator: FileManager.DirectoryEnumerator,
        root: URL,
        ignoreMatcher: FileBrowserIgnoreMatcher
    ) throws -> (entries: [FileBrowserEntry], ignoredDirectoryCount: Int) {
        var entries: [FileBrowserEntry] = []
        var ignoredDirectoryCount = 0
        for case let url as URL in enumerator {
            let normalizedPath = FilePathNormalizer.relativePath(for: url, from: root)
            guard !normalizedPath.isEmpty else { continue }
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues.isDirectory ?? false
            if isDirectory,
                ignoreMatcher.shouldIgnore(relativePath: normalizedPath, isDirectory: true)
            {
                ignoredDirectoryCount += 1
                // Show the directory (collapsed) but do not descend into it. Its
                // contents are indexed lazily when the user expands it, so a heavy
                // directory like node_modules never bloats the eager index, yet the
                // directory is never hidden from the tree.
                entries.append(
                    FileBrowserEntry(
                        relativePath: normalizedPath, isDirectory: true, isPruned: true))
                enumerator.skipDescendants()
                continue
            }
            if ignoreMatcher.shouldIgnore(relativePath: normalizedPath, isDirectory: isDirectory) {
                continue
            }
            entries.append(FileBrowserEntry(relativePath: normalizedPath, isDirectory: isDirectory))
        }
        return (entries, ignoredDirectoryCount)
    }
}
