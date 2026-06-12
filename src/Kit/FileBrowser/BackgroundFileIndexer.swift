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
    /// Hard cap on entries from a single eager walk. Bounds memory, the post-walk
    /// sort, and the SQLite cache write on pathologically large trees (e.g. a
    /// ~1.5M-file monorepo, where an unbounded walk hangs for minutes). Beyond the
    /// cap the walk stops and the result is marked truncated; deeper content stays
    /// reachable via lazy subtree expansion and fuzzy search over the indexed set.
    public static let maxIndexedEntries = 200_000
    /// Coarse wall-clock backstop for a single eager walk. The entry cap above is
    /// the reliable bound (checked every yield); this only stops a tree that is
    /// slow *per entry* yet under the cap, so the browser can't spin indefinitely.
    /// It is deliberately generous — a real 38 GB monorepo (~157k non-ignored
    /// entries) indexes fully in ~15 s, and a complete index (everything
    /// searchable) beats an early-truncated one. `FileManager`'s enumerator blocks
    /// in bursts, so this is checked between yields and may overshoot somewhat; the
    /// walk runs off-main on `queue`, so it only delays the result, never the UI.
    public static let walkTimeBudget: TimeInterval = 30.0

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

    /// Indexes the full tree under `root` on the background queue, applying
    /// `ignoreRules`, and delivers the result to `completion`.
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

    /// Indexes the pruned subtree at `relativeSubpath` on the background queue and
    /// delivers entries (relative to `root`) to `completion` for merging into the
    /// full index.
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
            ),
            isTruncated: subResult.isTruncated
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
        indexedAt: Date = Date(),
        maxEntries: Int = BackgroundFileIndexer.maxIndexedEntries,
        timeBudget: TimeInterval = BackgroundFileIndexer.walkTimeBudget
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
            enumerator: enumerator, root: root, ignoreMatcher: ignoreMatcher,
            maxEntries: maxEntries, timeBudget: timeBudget)
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
            ),
            isTruncated: walk.isTruncated
        )
    }

    private static func walkEntries(
        enumerator: FileManager.DirectoryEnumerator,
        root: URL,
        ignoreMatcher: FileBrowserIgnoreMatcher,
        maxEntries: Int = BackgroundFileIndexer.maxIndexedEntries,
        timeBudget: TimeInterval = BackgroundFileIndexer.walkTimeBudget
    ) throws -> (entries: [FileBrowserEntry], ignoredDirectoryCount: Int, isTruncated: Bool) {
        var entries: [FileBrowserEntry] = []
        var ignoredDirectoryCount = 0
        // Bound the eager walk so a pathologically large/slow tree can't hang the
        // browser or exhaust memory: stop at the entry cap or the wall-clock budget
        // (checked periodically — `Date()` per entry would itself be a cost on a
        // multi-hundred-thousand-entry walk). Deeper content stays reachable via
        // lazy subtree expansion; the partial index is searchable.
        let deadline = Date().addingTimeInterval(timeBudget)
        var isTruncated = false
        var sinceTimeCheck = 0
        for case let url as URL in enumerator {
            if entries.count >= maxEntries {
                isTruncated = true
                break
            }
            sinceTimeCheck += 1
            if sinceTimeCheck >= 1024 {
                sinceTimeCheck = 0
                if Date() > deadline {
                    isTruncated = true
                    break
                }
            }
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
        return (entries, ignoredDirectoryCount, isTruncated)
    }
}
