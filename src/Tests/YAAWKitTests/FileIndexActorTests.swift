import XCTest

@testable import YAAWKit

final class FileIndexActorTests: XCTestCase {
    func testActorDeduplicatesSameKeyRefreshesAndSharesResult() async throws {
        let root = try temporaryDirectory()
        let store = InMemoryYAAWStore.helloWorld()
        let indexer = ManualFileIndexer()
        let actor = FileIndexActor(store: store, fileIndexer: indexer)
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let key = await actor.cacheKey(
            root: root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
        let entry = FileBrowserEntry(relativePath: "README.md", isDirectory: false)

        async let first = actor.refreshIndex(
            threadID: firstThreadID, root: root,
            ignoreRules: YAAWConfiguration.defaultIgnoreRules, key: key)
        async let second = actor.refreshIndex(
            threadID: secondThreadID, root: root,
            ignoreRules: YAAWConfiguration.defaultIgnoreRules, key: key)

        try await indexer.waitForRequests(1)
        XCTAssertEqual(indexer.requestCount, 1)
        indexer.completeRequest(at: 0, result: .success(Self.result(root: root, entries: [entry])))

        let firstResult = try await first
        let secondResult = try await second
        XCTAssertEqual(firstResult.metadata.threadID, firstThreadID)
        XCTAssertEqual(secondResult.metadata.threadID, secondThreadID)
        XCTAssertEqual(firstResult.metadata.cacheKey, key.value)
        XCTAssertEqual(secondResult.entries, [entry])
        let cached = await store.cachedFileIndex(cacheKey: key.value)
        XCTAssertEqual(cached?.entries, [entry])
    }

    func testActorReturnsCachedIndexStampedForThread() async throws {
        let root = try temporaryDirectory()
        let store = InMemoryYAAWStore.helloWorld()
        let actor = FileIndexActor(store: store, fileIndexer: ManualFileIndexer())
        let key = await actor.cacheKey(
            root: root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
        let entry = FileBrowserEntry(relativePath: "cached.swift", isDirectory: false)
        await store.upsertCachedFileIndex(
            CachedFileIndex(
                metadata: FileIndexMetadata(
                    threadID: UUID(), cacheKey: key.value, rootPath: key.rootPath,
                    gitIdentity: key.gitIdentity,
                    ignoreRulesFingerprint: key.ignoreRulesFingerprint,
                    schemaVersion: key.schemaVersion, indexedAt: Date(timeIntervalSince1970: 1),
                    fileCount: 1, ignoredDirectoryCount: 0),
                entries: [entry]))

        let viewerThreadID = UUID()
        let cached = await actor.cachedIndex(threadID: viewerThreadID, key: key)

        XCTAssertEqual(cached?.entries, [entry])
        XCTAssertEqual(cached?.metadata.threadID, viewerThreadID)
        XCTAssertEqual(cached?.metadata.cacheKey, key.value)
    }

    func testActorExpandingPrunedSubtreeMergesIntoCacheAndStaysSearchable() async throws {
        let root = try temporaryDirectory()
        let store = InMemoryYAAWStore.helloWorld()
        let indexer = ManualFileIndexer()
        let actor = FileIndexActor(store: store, fileIndexer: indexer)
        let threadID = UUID()
        let key = await actor.cacheKey(
            root: root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
        let readme = FileBrowserEntry(relativePath: "README.md", isDirectory: false)
        let pruned = FileBrowserEntry(
            relativePath: "node_modules", isDirectory: true, isPruned: true)

        async let full = actor.refreshIndex(
            threadID: threadID, root: root,
            ignoreRules: YAAWConfiguration.defaultIgnoreRules, key: key)
        try await indexer.waitForRequests(1)
        indexer.completeRequest(
            at: 0, result: .success(Self.result(root: root, entries: [readme, pruned])))
        _ = try await full

        let needle = FileBrowserEntry(
            relativePath: "node_modules/pkg/needle.js", isDirectory: false)
        let subtree = [
            FileBrowserEntry(relativePath: "node_modules", isDirectory: true, isPruned: false),
            FileBrowserEntry(relativePath: "node_modules/pkg", isDirectory: true),
            needle,
        ]
        async let expand = actor.refreshSubtree(
            threadID: threadID, root: root, relativeSubpath: "node_modules",
            ignoreRules: YAAWConfiguration.defaultIgnoreRules, key: key)
        try await indexer.waitForSubtreeRequests(1)
        indexer.completeSubtreeRequest(
            at: 0, result: .success(Self.result(root: root, entries: subtree)))
        _ = try await expand

        // The pruned placeholder is replaced in the persisted cache by the loaded contents.
        let cached = await store.cachedFileIndex(cacheKey: key.value)
        let cachedEntries = try XCTUnwrap(cached?.entries)
        XCTAssertFalse(cachedEntries.contains { $0.relativePath == "node_modules" && $0.isPruned })
        XCTAssertTrue(cachedEntries.contains(needle))
        // Lazily-loaded files now participate in fuzzy search over the merged index.
        let ranked = FuzzyFileMatcher.rankedEntries(cachedEntries, query: "needle.js")
        XCTAssertEqual(ranked.first?.relativePath, needle.relativePath)
    }

    func testActorDeduplicatesConcurrentSubtreeExpands() async throws {
        let root = try temporaryDirectory()
        let store = InMemoryYAAWStore.helloWorld()
        let indexer = ManualFileIndexer()
        let actor = FileIndexActor(store: store, fileIndexer: indexer)
        let key = await actor.cacheKey(
            root: root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
        let subtree = [
            FileBrowserEntry(relativePath: "node_modules", isDirectory: true, isPruned: false),
            FileBrowserEntry(relativePath: "node_modules/a.js", isDirectory: false),
        ]

        async let first = actor.refreshSubtree(
            threadID: UUID(), root: root, relativeSubpath: "node_modules",
            ignoreRules: YAAWConfiguration.defaultIgnoreRules, key: key)
        async let second = actor.refreshSubtree(
            threadID: UUID(), root: root, relativeSubpath: "node_modules",
            ignoreRules: YAAWConfiguration.defaultIgnoreRules, key: key)
        try await indexer.waitForSubtreeRequests(1)
        XCTAssertEqual(indexer.subtreeRequestCount, 1)
        indexer.completeSubtreeRequest(
            at: 0, result: .success(Self.result(root: root, entries: subtree)))

        let firstEntries = try await first.entries
        let secondEntries = try await second.entries
        XCTAssertEqual(firstEntries, subtree)
        XCTAssertEqual(secondEntries, subtree)
    }

    func testActorSessionCachesGitHeadUntilInvalidated() async throws {
        let root = try temporaryDirectory()
        try writeFile(root.appendingPathComponent(".git/HEAD"), contents: "ref: refs/heads/main\n")
        let resolver = CountingGitIdentityResolver()
        let actor = FileIndexActor(
            store: InMemoryYAAWStore.helloWorld(),
            fileIndexer: ManualFileIndexer(),
            gitIdentityResolver: resolver)

        let first = await actor.cacheKey(root: root, ignoreRules: [".git"])
        let second = await actor.cacheKey(root: root, ignoreRules: [".git", "node_modules"])
        XCTAssertEqual(first.gitIdentity, "branch:refs/heads/main")
        XCTAssertEqual(second.gitIdentity, "branch:refs/heads/main")
        // Two cache-key computations for the same root read `.git/HEAD` exactly once.
        XCTAssertEqual(resolver.count, 1)

        // After the branch moves and the session cache is invalidated, the next
        // computation re-reads HEAD and sees the new branch.
        try writeFile(
            root.appendingPathComponent(".git/HEAD"), contents: "ref: refs/heads/feature\n")
        await actor.invalidateGitIdentity(for: root)
        let third = await actor.cacheKey(root: root, ignoreRules: [".git"])
        XCTAssertEqual(third.gitIdentity, "branch:refs/heads/feature")
        XCTAssertEqual(resolver.count, 2)
    }

    func testActorRankEntriesStreamYieldsRankedResult() async throws {
        let actor = FileIndexActor(
            store: InMemoryYAAWStore.helloWorld(), fileIndexer: ManualFileIndexer())
        let entries = [
            FileBrowserEntry(relativePath: "src/needle.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "src/haystack.swift", isDirectory: false),
        ]

        var received: FuzzyFileMatcher.Result?
        for await frame in actor.rankEntries(entries: entries, query: "needle") {
            received = frame
        }

        XCTAssertEqual(received?.entries.map(\.relativePath), ["src/needle.swift"])
        XCTAssertEqual(received?.totalMatches, 1)
        XCTAssertEqual(received?.isLimitApplied, false)
    }

    // MARK: - Fixtures

    private static func result(root: URL, entries: [FileBrowserEntry]) -> FileIndexResult {
        FileIndexResult(
            entries: entries,
            metadata: FileIndexMetadata(
                threadID: UUID(),
                rootPath: root.path,
                indexedAt: Date(timeIntervalSince1970: TimeInterval(entries.count)),
                fileCount: entries.count,
                ignoredDirectoryCount: 0))
    }

    private func writeFile(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A `FileIndexing` double that records requests and lets the test drive their
/// completion. Its mutable state is guarded by an `NSLock` (it is a test helper,
/// not production code) so the actor's background completion hops are observable.
private final class ManualFileIndexer: FileIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [@Sendable (Result<FileIndexResult, Error>) -> Void] = []
    private var subtreeCompletions: [@Sendable (Result<FileIndexResult, Error>) -> Void] = []

    var requestCount: Int { lock.withLock { completions.count } }
    var subtreeRequestCount: Int { lock.withLock { subtreeCompletions.count } }

    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        lock.withLock { completions.append(completion) }
    }

    func indexSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        lock.withLock { subtreeCompletions.append(completion) }
    }

    func completeRequest(at index: Int, result: Result<FileIndexResult, Error>) {
        let completion = lock.withLock { completions[index] }
        completion(result)
    }

    func completeSubtreeRequest(at index: Int, result: Result<FileIndexResult, Error>) {
        let completion = lock.withLock { subtreeCompletions[index] }
        completion(result)
    }

    /// Polls until at least `count` full-index requests have arrived (the actor
    /// registers them on its own executor, so the call returns asynchronously).
    func waitForRequests(_ count: Int) async throws {
        try await poll { self.requestCount >= count }
    }

    func waitForSubtreeRequests(_ count: Int) async throws {
        try await poll { self.subtreeRequestCount >= count }
    }

    private func poll(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for indexer requests")
    }
}

/// Counts how many times the git identity was resolved, to assert session caching.
/// Lock-guarded so the count is observed synchronously after the actor returns.
private final class CountingGitIdentityResolver: FileIndexGitIdentityResolving, @unchecked Sendable
{
    private let resolver = FileIndexGitIdentityResolver()
    private let lock = NSLock()
    private var resolveCount = 0

    var count: Int { lock.withLock { resolveCount } }

    func gitIdentity(for root: URL) -> FileIndexGitIdentity {
        lock.withLock { resolveCount += 1 }
        return resolver.gitIdentity(for: root)
    }
}
