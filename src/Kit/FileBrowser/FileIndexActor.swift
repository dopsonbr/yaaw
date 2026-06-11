import Foundation

/// The single synchronization point for file-browser indexing: it owns the
/// in-flight dedup table, the durable shared cache, the per-session `.git/HEAD`
/// cache, the FSEvents directory watcher, and incremental fuzzy re-ranking.
///
/// A plain `actor` (no `@globalActor`): all state lives behind the actor boundary,
/// so there is no `NSLock`, no `@unchecked Sendable`, and no `nonisolated(unsafe)`.
/// The underlying filesystem walk runs on `BackgroundFileIndexer`'s concurrent
/// queue; results hop back onto the actor before touching shared state.
public actor FileIndexActor {
    /// Presentation cap for the visible tree-row walk.
    public static let maxBrowseEntries = 10_000
    /// Cap for fuzzy search results.
    public static let maxSearchResults = 1_000
    /// Index sizes beyond this are logged as a diagnostic.
    public static let largeIndexDiagnosticThreshold = 50_000

    private let store: any YAAWStore
    private let fileIndexer: any FileIndexing
    private let gitIdentityResolver: any FileIndexGitIdentityResolving
    private let watcher: FileIndexDirectoryWatcher

    private var fullInFlight: [String: [CheckedContinuation<FileIndexResult, Error>]] = [:]
    private var subtreeInFlight: [String: [CheckedContinuation<FileIndexResult, Error>]] = [:]
    /// Session cache of resolved git identities, keyed by standardized root path.
    /// Amortizes the per-index `.git/HEAD` read; invalidated when a watched root
    /// reports a change.
    private var gitHeadCache: [String: FileIndexGitIdentity] = [:]

    /// Creates the actor over a persistence store and an indexer.
    public init(
        store: any YAAWStore,
        fileIndexer: any FileIndexing = BackgroundFileIndexer(),
        gitIdentityResolver: any FileIndexGitIdentityResolving = FileIndexGitIdentityResolver(),
        watchDebounce: DispatchTimeInterval = .milliseconds(350)
    ) {
        self.store = store
        self.fileIndexer = fileIndexer
        self.gitIdentityResolver = gitIdentityResolver
        self.watcher = FileIndexDirectoryWatcher(debounce: watchDebounce)
    }

    // MARK: - Cache key

    /// Computes the cache key for `root` + `ignoreRules`, reusing the
    /// session-cached git identity (resolving and caching it on first use).
    public func cacheKey(root: URL, ignoreRules: [String]) -> FileIndexCacheKey {
        FileIndexCacheKey(
            root: root,
            ignoreRules: ignoreRules,
            gitIdentity: resolvedGitIdentity(for: root))
    }

    private func resolvedGitIdentity(for root: URL) -> FileIndexGitIdentity {
        let path = root.standardizedFileURL.path
        if let cached = gitHeadCache[path] { return cached }
        let identity = gitIdentityResolver.gitIdentity(for: root)
        gitHeadCache[path] = identity
        return identity
    }

    /// Drops the session-cached git identity for `root`, so the next cache-key
    /// computation re-reads `.git/HEAD` (used when a watch event fires).
    public func invalidateGitIdentity(for root: URL) {
        gitHeadCache.removeValue(forKey: root.standardizedFileURL.path)
    }

    // MARK: - Cache lookup

    /// Returns the cached index for `key` (re-stamped for `threadID`), if present.
    public func cachedIndex(threadID: UUID, key: FileIndexCacheKey) async -> FileIndexResult? {
        guard let cached = await store.cachedFileIndex(cacheKey: key.value) else { return nil }
        return FileIndexResult(
            entries: cached.entries, metadata: cached.metadata.forThread(threadID))
    }

    // MARK: - Full refresh

    /// Refreshes the full index for `key`, coalescing identical concurrent
    /// requests into a single underlying walk. Each caller gets the result
    /// stamped with its own `threadID`.
    public func refreshIndex(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        key: FileIndexCacheKey
    ) async throws -> FileIndexResult {
        let raw = try await coalescedFullIndex(root: root, ignoreRules: ignoreRules, key: key)
        return FileIndexResult(entries: raw.entries, metadata: raw.metadata.forThread(threadID))
    }

    private func coalescedFullIndex(
        root: URL,
        ignoreRules: [String],
        key: FileIndexCacheKey
    ) async throws -> FileIndexResult {
        try await withCheckedThrowingContinuation { continuation in
            if fullInFlight[key.value] != nil {
                fullInFlight[key.value]?.append(continuation)
                return
            }
            fullInFlight[key.value] = [continuation]
            fileIndexer.indexFiles(threadID: UUID(), root: root, ignoreRules: ignoreRules) {
                [weak self] result in
                Task { await self?.finishFull(result: result, key: key) }
            }
        }
    }

    private func finishFull(result: Result<FileIndexResult, Error>, key: FileIndexCacheKey) async {
        let waiters = fullInFlight.removeValue(forKey: key.value) ?? []
        switch result {
        case .success(let indexed):
            let stamped = stampMetadata(indexed, key: key)
            await store.upsertCachedFileIndex(
                CachedFileIndex(metadata: stamped.metadata, entries: stamped.entries))
            for waiter in waiters { waiter.resume(returning: stamped) }
        case .failure(let error):
            for waiter in waiters { waiter.resume(throwing: error) }
        }
    }

    private func stampMetadata(_ result: FileIndexResult, key: FileIndexCacheKey) -> FileIndexResult
    {
        var metadata = result.metadata
        metadata.cacheKey = key.value
        metadata.rootPath = key.rootPath
        metadata.gitIdentity = key.gitIdentity
        metadata.ignoreRulesFingerprint = key.ignoreRulesFingerprint
        metadata.schemaVersion = key.schemaVersion
        return FileIndexResult(entries: result.entries, metadata: metadata)
    }

    // MARK: - Subtree refresh

    /// Lazily indexes a pruned subtree and merges it into the persisted full
    /// index so the directory's contents become available (and searchable)
    /// without a full re-enumeration. Coalesces concurrent expands of the same
    /// subtree.
    public func refreshSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        key: FileIndexCacheKey
    ) async throws -> FileIndexResult {
        let raw = try await coalescedSubtree(
            root: root, relativeSubpath: relativeSubpath, ignoreRules: ignoreRules, key: key)
        return FileIndexResult(entries: raw.entries, metadata: raw.metadata.forThread(threadID))
    }

    private func coalescedSubtree(
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        key: FileIndexCacheKey
    ) async throws -> FileIndexResult {
        let dedupKey = "\(key.value)|subtree:\(relativeSubpath)"
        return try await withCheckedThrowingContinuation { continuation in
            if subtreeInFlight[dedupKey] != nil {
                subtreeInFlight[dedupKey]?.append(continuation)
                return
            }
            subtreeInFlight[dedupKey] = [continuation]
            fileIndexer.indexSubtree(
                threadID: UUID(), root: root, relativeSubpath: relativeSubpath,
                ignoreRules: ignoreRules
            ) { [weak self] result in
                Task {
                    await self?.finishSubtree(
                        result: result, key: key, dedupKey: dedupKey,
                        prunedPath: relativeSubpath)
                }
            }
        }
    }

    private func finishSubtree(
        result: Result<FileIndexResult, Error>,
        key: FileIndexCacheKey,
        dedupKey: String,
        prunedPath: String
    ) async {
        let waiters = subtreeInFlight.removeValue(forKey: dedupKey) ?? []
        switch result {
        case .success(let subtreeResult):
            await mergeSubtreeIntoCache(subtreeResult, key: key, prunedPath: prunedPath)
            for waiter in waiters { waiter.resume(returning: subtreeResult) }
        case .failure(let error):
            for waiter in waiters { waiter.resume(throwing: error) }
        }
    }

    private func mergeSubtreeIntoCache(
        _ subtreeResult: FileIndexResult,
        key: FileIndexCacheKey,
        prunedPath: String
    ) async {
        guard let cached = await store.cachedFileIndex(cacheKey: key.value) else { return }
        let mergedEntries = FileBrowserTreeBuilder.merging(
            cached.entries, withSubtree: subtreeResult.entries, replacingPrunedPath: prunedPath)
        var metadata = cached.metadata
        metadata.fileCount = mergedEntries.count
        await store.upsertCachedFileIndex(
            CachedFileIndex(metadata: metadata, entries: mergedEntries))
    }

    // MARK: - Incremental re-rank

    /// Streams fuzzy-ranking results for `query` over `entries`. Today it emits a
    /// single ranked frame then finishes; the `AsyncStream` shape lets the UI
    /// consume incremental frames without the actor blocking on a synchronous
    /// rank of a 150k-entry index.
    public nonisolated func rankEntries(
        entries: [FileBrowserEntry],
        query: String,
        limit: Int? = nil
    ) -> AsyncStream<FuzzyFileMatcher.Result> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let result = FuzzyFileMatcher.rankedResult(entries, query: query, limit: limit)
                continuation.yield(result)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Watching

    /// Watches `directories`; on a debounced change, invalidates the git identity
    /// for each watched root and invokes `onChange`.
    public func watch(
        directories: Set<String>,
        onChange: @escaping @Sendable () -> Void
    ) async {
        await watcher.watch(directories: directories) { [weak self] in
            Task { await self?.handleWatchChange(directories: directories, onChange: onChange) }
        }
    }

    private func handleWatchChange(
        directories: Set<String>,
        onChange: @escaping @Sendable () -> Void
    ) {
        for path in directories {
            gitHeadCache.removeValue(forKey: URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        onChange()
    }

    /// Stops the directory watcher.
    public func stopWatching() async {
        await watcher.stop()
    }
}
