import XCTest

@testable import YAAWKit

final class FileBrowserTests: XCTestCase {
    func testDefaultIgnoreRulesSkipHeavyDirectoriesButKeepHiddenFiles() throws {
        let matcher = FileBrowserIgnoreMatcher(rules: YAAWConfiguration.defaultIgnoreRules)

        XCTAssertTrue(matcher.shouldIgnore(relativePath: ".git", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "src/node_modules", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "DerivedData/App", isDirectory: true))
        // Home-directory noise (Music/Movies/Pictures) and `worktrees` are no longer
        // default rules, so they are surfaced like any other directory.
        XCTAssertFalse(matcher.shouldIgnore(relativePath: "Music", isDirectory: true))
        XCTAssertFalse(matcher.shouldIgnore(relativePath: "worktrees", isDirectory: true))
        XCTAssertFalse(matcher.shouldIgnore(relativePath: "dist", isDirectory: false))
        XCTAssertFalse(matcher.shouldIgnore(relativePath: "src/.build", isDirectory: false))
        XCTAssertFalse(matcher.shouldIgnore(relativePath: ".env", isDirectory: false))
        XCTAssertFalse(
            matcher.shouldIgnore(relativePath: "src/.config/settings.json", isDirectory: false))
    }

    func testPathNormalizationRemovesRootAndCollapsesSeparators() throws {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let file = URL(fileURLWithPath: "/tmp/project/src//App.swift")

        XCTAssertEqual(FilePathNormalizer.relativePath(for: file, from: root), "src/App.swift")
        XCTAssertEqual(
            FilePathNormalizer.normalizedRelativePath("./src\\Core//AppModel.swift"),
            "src/Core/AppModel.swift")
        XCTAssertEqual(FilePathNormalizer.normalizedRule(" /node_modules/ "), "node_modules")
    }

    func testFuzzyRankingPrefersExactFilenameThenPrefixThenFuzzyPath() {
        let entries = [
            FileBrowserEntry(relativePath: "src/r/e/a/d/m/e.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "docs/README.md", isDirectory: false),
            FileBrowserEntry(relativePath: "README", isDirectory: false),
            FileBrowserEntry(relativePath: "src/other.swift", isDirectory: false),
        ]

        let ranked = FuzzyFileMatcher.rankedEntries(entries, query: "readme")

        XCTAssertEqual(
            ranked.map(\.relativePath),
            [
                "README",
                "docs/README.md",
                "src/r/e/a/d/m/e.swift",
            ])
    }

    func testFuzzyRankingLimitedResultKeepsBestMatchesAndCountsAllMatches() {
        let entries = [
            FileBrowserEntry(relativePath: "src/generated/z-target.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "Target.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "docs/target-notes.md", isDirectory: false),
            FileBrowserEntry(relativePath: "src/t/a/r/g/e/t.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "src/unrelated.swift", isDirectory: false),
        ]

        let result = FuzzyFileMatcher.rankedResult(entries, query: "target", limit: 2)

        XCTAssertEqual(
            result.entries.map(\.relativePath), ["Target.swift", "docs/target-notes.md"])
        XCTAssertEqual(result.totalMatches, 4)
        XCTAssertTrue(result.isLimitApplied)
    }

    func testVisibleTreeRowsOnlyIncludeExpandedBranchesAndHonorLimit() {
        let entries = [
            FileBrowserEntry(relativePath: "docs", isDirectory: true),
            FileBrowserEntry(relativePath: "docs/README.md", isDirectory: false),
            FileBrowserEntry(relativePath: "src", isDirectory: true),
            FileBrowserEntry(relativePath: "src/App.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "src/Core", isDirectory: true),
            FileBrowserEntry(relativePath: "src/Core/AppModel.swift", isDirectory: false),
        ]

        let collapsed = FileBrowserTreeBuilder.visibleRows(
            from: entries, expandedFolders: [], limit: 10)
        XCTAssertEqual(collapsed.map(\.entry.relativePath), ["docs", "src"])

        let expanded = FileBrowserTreeBuilder.visibleRows(
            from: entries, expandedFolders: ["src"], limit: 10)
        XCTAssertEqual(
            expanded.map(\.entry.relativePath), ["docs", "src", "src/App.swift", "src/Core"])

        let limited = FileBrowserTreeBuilder.visibleRows(
            from: entries, expandedFolders: ["src"], limit: 2)
        XCTAssertEqual(limited.map(\.entry.relativePath), ["docs", "src"])
    }

    func testVisibleTreeRowsCapsExpandedLargeBranch() {
        let rows = FileBrowserTreeBuilder.visibleRows(
            from: Self.largeSyntheticEntries(count: 25_000),
            expandedFolders: ["src", "src/generated"],
            limit: 10_000
        )

        XCTAssertEqual(rows.count, 10_000)
        XCTAssertEqual(rows.first?.entry.relativePath, "src")
        XCTAssertTrue(rows.contains { $0.entry.relativePath == "src/generated" })
    }

    func testVisibleRowsRevealDeepFilesInLargeIndexWhenExpanded() {
        // Regression: a deeply nested directory whose files sort far down the
        // global order used to be dropped by the 10k presentation cap, so
        // expanding the folder showed nothing. The tree now walks the full
        // index lazily, so the markdown files appear once their ancestors are
        // expanded — even when the index dwarfs the render ceiling.
        var entries = [
            FileBrowserEntry(relativePath: "repos", isDirectory: true),
            FileBrowserEntry(relativePath: "repos/order-up", isDirectory: true),
            FileBrowserEntry(relativePath: "repos/order-up/docs", isDirectory: true),
        ]
        // A large, shallow filler branch that sorts ahead of the target so the
        // target's files land well past any historical 10k cut-off.
        entries.append(FileBrowserEntry(relativePath: "apps", isDirectory: true))
        for index in 0..<60_000 {
            entries.append(
                FileBrowserEntry(
                    relativePath: String(format: "apps/gen_%05d.ts", index),
                    isDirectory: false
                ))
        }
        let docFiles = ["adr.md", "architecture.md", "server-side-state.md"]
        for name in docFiles {
            entries.append(
                FileBrowserEntry(
                    relativePath: "repos/order-up/docs/\(name)", isDirectory: false))
        }
        entries.sort(by: FileBrowserTreeBuilder.sortEntriesForTree)

        let index = FileBrowserTreeBuilder.childrenIndex(from: entries)
        let rows = FileBrowserTreeBuilder.visibleRows(
            childrenIndex: index,
            expandedFolders: ["repos", "repos/order-up", "repos/order-up/docs"],
            limit: 10_000
        )
        let visiblePaths = Set(rows.map(\.entry.relativePath))

        for name in docFiles {
            XCTAssertTrue(
                visiblePaths.contains("repos/order-up/docs/\(name)"),
                "Expected expanded docs folder to reveal \(name)"
            )
        }
    }

    func testVisibleRowsViaChildrenIndexMatchEntryWalkOrdering() {
        let entries = [
            FileBrowserEntry(relativePath: "docs", isDirectory: true),
            FileBrowserEntry(relativePath: "docs/README.md", isDirectory: false),
            FileBrowserEntry(relativePath: "src", isDirectory: true),
            FileBrowserEntry(relativePath: "src/App.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "src/Core", isDirectory: true),
            FileBrowserEntry(relativePath: "src/Core/AppModel.swift", isDirectory: false),
        ]
        let expanded: Set<String> = ["src", "src/Core"]

        let viaEntries = FileBrowserTreeBuilder.visibleRows(
            from: entries, expandedFolders: expanded, limit: 10)
        let viaIndex = FileBrowserTreeBuilder.visibleRows(
            childrenIndex: FileBrowserTreeBuilder.childrenIndex(from: entries),
            expandedFolders: expanded,
            limit: 10
        )

        XCTAssertEqual(viaIndex, viaEntries)
        XCTAssertEqual(
            viaIndex.map(\.entry.relativePath),
            ["docs", "src", "src/App.swift", "src/Core", "src/Core/AppModel.swift"])
        XCTAssertEqual(viaIndex.last?.depth, 2)
    }

    func testSortKeepsDeepDirectoryContentsAheadOfLaterRootSiblings() throws {
        // Regression: when comparing a deep entry under one root dir (e.g.
        // `reports/bq-order-analytics`) against a file under a later root
        // sibling (e.g. `tmp-apps/FINAL.md`), the dir-first rule at the
        // divergence point must still apply — otherwise the children of
        // `reports` end up interleaved with `tmp-apps` contents.
        let entries: [FileBrowserEntry] = [
            FileBrowserEntry(relativePath: "AGENTS.md", isDirectory: false),
            FileBrowserEntry(relativePath: "command-center-v2", isDirectory: true),
            FileBrowserEntry(relativePath: "command-center-v2/sub", isDirectory: true),
            FileBrowserEntry(
                relativePath: "command-center-v2/sub/deep.txt", isDirectory: false),
            FileBrowserEntry(relativePath: "reports", isDirectory: true),
            FileBrowserEntry(relativePath: "reports/bq-order-analytics", isDirectory: true),
            FileBrowserEntry(
                relativePath: "reports/bq-order-analytics/x.txt", isDirectory: false),
            FileBrowserEntry(relativePath: "tmp-apps", isDirectory: true),
            FileBrowserEntry(relativePath: "tmp-apps/FINAL.md", isDirectory: false),
        ]

        let sorted = entries.sorted(by: FileBrowserTreeBuilder.sortEntriesForTree)

        XCTAssertEqual(
            sorted.map(\.relativePath),
            [
                "command-center-v2",
                "command-center-v2/sub",
                "command-center-v2/sub/deep.txt",
                "reports",
                "reports/bq-order-analytics",
                "reports/bq-order-analytics/x.txt",
                "tmp-apps",
                "tmp-apps/FINAL.md",
                "AGENTS.md",
            ])
    }

    func testTemporaryDirectoryIndexUsesTreeOrderWithFilesNearParents() throws {
        let root = try temporaryDirectory()
        try writeFile(root.appendingPathComponent("a-dir/file.swift"), contents: "print(\"a\")")
        try writeFile(root.appendingPathComponent("b-dir/file.swift"), contents: "print(\"b\")")
        try writeFile(root.appendingPathComponent("root-file.swift"), contents: "print(\"root\")")
        let threadID = UUID()

        let result = try BackgroundFileIndexer.buildIndex(
            threadID: threadID,
            root: root,
            ignoreRules: [],
            indexedAt: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(
            result.entries.map(\.relativePath),
            [
                "a-dir",
                "a-dir/file.swift",
                "b-dir",
                "b-dir/file.swift",
                "root-file.swift",
            ])
    }

    func testTemporaryDirectoryIndexShowsIgnoredDirectoriesButPrunesDescendants() throws {
        let root = try temporaryDirectory()
        try writeFile(root.appendingPathComponent(".env"), contents: "TOKEN=example")
        try writeFile(root.appendingPathComponent("README.md"), contents: "# Project")
        try writeFile(root.appendingPathComponent("src/main.swift"), contents: "print(\"hi\")")
        try writeFile(root.appendingPathComponent("node_modules/pkg/index.js"), contents: "ignored")
        try writeFile(root.appendingPathComponent(".git/config"), contents: "ignored")
        try writeFile(root.appendingPathComponent("dist/app.js"), contents: "ignored")
        try writeFile(root.appendingPathComponent("DerivedData/build.log"), contents: "ignored")
        let threadID = UUID()

        let result = try BackgroundFileIndexer.buildIndex(
            threadID: threadID,
            root: root,
            ignoreRules: YAAWConfiguration.defaultIgnoreRules,
            indexedAt: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(result.metadata.threadID, threadID)
        XCTAssertEqual(result.metadata.rootPath, root.standardizedFileURL.path)
        XCTAssertEqual(result.metadata.fileCount, result.entries.count)
        // node_modules, .git, dist, DerivedData are pruned (collapsed) but visible.
        XCTAssertEqual(result.metadata.ignoredDirectoryCount, 4)
        XCTAssertTrue(
            result.entries.contains(FileBrowserEntry(relativePath: ".env", isDirectory: false)))
        XCTAssertTrue(
            result.entries.contains(FileBrowserEntry(relativePath: "src", isDirectory: true)))
        XCTAssertTrue(
            result.entries.contains(
                FileBrowserEntry(relativePath: "src/main.swift", isDirectory: false)))
        // Ignored directories appear as pruned entries...
        XCTAssertTrue(
            result.entries.contains(
                FileBrowserEntry(relativePath: "node_modules", isDirectory: true, isPruned: true)))
        XCTAssertTrue(
            result.entries.contains(
                FileBrowserEntry(relativePath: ".git", isDirectory: true, isPruned: true)))
        // ...but their descendants are not eagerly indexed.
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains("/") && $0.relativePath.hasPrefix("node_modules/") })
        XCTAssertFalse(result.entries.contains { $0.relativePath.hasPrefix(".git/") })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".yaaw").path))
    }

    func testIndexSubtreeReturnsDescendantsAndUnprunedRoot() throws {
        let root = try temporaryDirectory()
        try writeFile(root.appendingPathComponent("node_modules/pkg/index.js"), contents: "x")
        try writeFile(root.appendingPathComponent("node_modules/pkg/readme.md"), contents: "y")
        let threadID = UUID()

        let result = try BackgroundFileIndexer.buildSubtreeIndex(
            threadID: threadID,
            root: root,
            relativeSubpath: "node_modules",
            ignoreRules: YAAWConfiguration.defaultIgnoreRules,
            indexedAt: Date(timeIntervalSince1970: 1)
        )

        // The subtree root comes back un-pruned so a merge flips the collapsed node.
        XCTAssertTrue(
            result.entries.contains(
                FileBrowserEntry(relativePath: "node_modules", isDirectory: true, isPruned: false)))
        // Descendants are re-prefixed to be root-relative.
        XCTAssertTrue(
            result.entries.contains(
                FileBrowserEntry(relativePath: "node_modules/pkg/index.js", isDirectory: false)))
        XCTAssertTrue(
            result.entries.contains(
                FileBrowserEntry(relativePath: "node_modules/pkg", isDirectory: true)))
    }

    func testTreeBuilderMergingReplacesPrunedNodeAndSortsInPreOrder() throws {
        let entries = [
            FileBrowserEntry(relativePath: "AGENTS.md", isDirectory: false),
            FileBrowserEntry(relativePath: "node_modules", isDirectory: true, isPruned: true),
            FileBrowserEntry(relativePath: "src", isDirectory: true),
            FileBrowserEntry(relativePath: "src/main.swift", isDirectory: false),
        ]
        let subtree = [
            FileBrowserEntry(relativePath: "node_modules", isDirectory: true, isPruned: false),
            FileBrowserEntry(relativePath: "node_modules/pkg", isDirectory: true),
            FileBrowserEntry(relativePath: "node_modules/pkg/index.js", isDirectory: false),
        ]

        let merged = FileBrowserTreeBuilder.merging(
            entries, withSubtree: subtree, replacingPrunedPath: "node_modules")

        // The pruned placeholder is gone; the loaded node and its children are present.
        XCTAssertFalse(merged.contains { $0.relativePath == "node_modules" && $0.isPruned })
        XCTAssertTrue(
            merged.contains(
                FileBrowserEntry(relativePath: "node_modules/pkg/index.js", isDirectory: false)))
        // Children sort immediately after their parent (depth-first pre-order).
        let nodeModulesIndex = merged.firstIndex { $0.relativePath == "node_modules" }
        let pkgIndex = merged.firstIndex { $0.relativePath == "node_modules/pkg" }
        XCTAssertNotNil(nodeModulesIndex)
        XCTAssertNotNil(pkgIndex)
        XCTAssertEqual(pkgIndex, nodeModulesIndex.map { $0 + 1 })
    }

    func testCacheKeyIncludesDirectoryBranchAndIgnoreRules() throws {
        let root = try temporaryDirectory()
        try writeFile(root.appendingPathComponent(".git/HEAD"), contents: "ref: refs/heads/main\n")

        let mainKey = FileIndexCacheKey(root: root, ignoreRules: [".git", "node_modules"])
        let sameMainKey = FileIndexCacheKey(root: root, ignoreRules: ["node_modules", ".git"])

        XCTAssertEqual(mainKey.value, sameMainKey.value)
        XCTAssertEqual(mainKey.gitIdentity, "branch:refs/heads/main")

        try writeFile(
            root.appendingPathComponent(".git/HEAD"), contents: "ref: refs/heads/feature\n")
        let featureKey = FileIndexCacheKey(root: root, ignoreRules: [".git", "node_modules"])

        XCTAssertNotEqual(mainKey.value, featureKey.value)
        XCTAssertEqual(featureKey.gitIdentity, "branch:refs/heads/feature")

        let detachedCommit = "0123456789abcdef0123456789abcdef01234567"
        try writeFile(root.appendingPathComponent(".git/HEAD"), contents: "\(detachedCommit)\n")
        let detachedKey = FileIndexCacheKey(root: root, ignoreRules: [".git", "node_modules"])

        XCTAssertEqual(detachedKey.gitIdentity, "detached:\(detachedCommit)")
        XCTAssertNotEqual(featureKey.value, detachedKey.value)

        let nonGitRoot = try temporaryDirectory()
        let nonGitKey = FileIndexCacheKey(root: nonGitRoot, ignoreRules: [".git", "node_modules"])

        XCTAssertEqual(nonGitKey.gitIdentity, "nogit")
        XCTAssertNotEqual(mainKey.value, nonGitKey.value)
    }

    func testCacheCoordinatorDeduplicatesSameKeyRefreshesAndSharesResult() throws {
        let root = try temporaryDirectory()
        let store = InMemoryYAAWStore.helloWorld()
        let indexer = ManualFileIndexer()
        let coordinator = FileIndexCacheCoordinator(store: store, fileIndexer: indexer)
        let firstThreadID = UUID()
        let secondThreadID = UUID()
        let cacheKey = coordinator.cacheKey(
            root: root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
        let entry = FileBrowserEntry(relativePath: "README.md", isDirectory: false)
        let firstResult = FileIndexResultBox()
        let secondResult = FileIndexResultBox()

        coordinator.refreshIndex(
            threadID: firstThreadID,
            root: root,
            ignoreRules: YAAWConfiguration.defaultIgnoreRules,
            key: cacheKey
        ) { result in
            firstResult.value = try? result.get()
        }
        coordinator.refreshIndex(
            threadID: secondThreadID,
            root: root,
            ignoreRules: YAAWConfiguration.defaultIgnoreRules,
            key: cacheKey
        ) { result in
            secondResult.value = try? result.get()
        }

        XCTAssertEqual(indexer.requestCount, 1)

        indexer.completeRequest(
            at: 0,
            result: .success(indexer.result(threadID: firstThreadID, root: root, entries: [entry]))
        )

        XCTAssertEqual(firstResult.value?.metadata.threadID, firstThreadID)
        XCTAssertEqual(secondResult.value?.metadata.threadID, secondThreadID)
        XCTAssertEqual(firstResult.value?.metadata.cacheKey, cacheKey.value)
        XCTAssertEqual(secondResult.value?.entries, [entry])
        XCTAssertEqual(store.cachedFileIndex(cacheKey: cacheKey.value)?.entries, [entry])
    }

    func testAppModelFileIndexingDoesNotBlockSelectionChanges() throws {
        let fixture = AppModelFixtureForFiles()
        let indexer = DelayedFileIndexer()
        let model = AppModel(store: fixture.store, fileIndexer: indexer)

        model.refreshSelectedFileBrowser()
        model.selectThread(id: fixture.secondThreadID)
        model.toggleRightPanelCollapsed()

        XCTAssertEqual(model.selectedThreadID, fixture.secondThreadID)
        XCTAssertTrue(model.layoutState.isRightPanelCollapsed)
        XCTAssertTrue(
            model.fileBrowserState.isIndexing == false
                || model.fileBrowserState.rootPath == fixture.secondRoot.path)
    }

    func testAppModelShowsSharedCachedEntriesWhileRefreshIsInProgress() throws {
        let fixture = AppModelFixtureForSharedFiles()
        let store = fixture.store
        let cacheKey = FileIndexCacheKey(
            root: fixture.root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
        let cachedEntry = FileBrowserEntry(relativePath: "cached.swift", isDirectory: false)
        store.upsertCachedFileIndex(
            CachedFileIndex(
                metadata: FileIndexMetadata(
                    threadID: fixture.firstThreadID,
                    cacheKey: cacheKey.value,
                    rootPath: cacheKey.rootPath,
                    gitIdentity: cacheKey.gitIdentity,
                    ignoreRulesFingerprint: cacheKey.ignoreRulesFingerprint,
                    schemaVersion: cacheKey.schemaVersion,
                    indexedAt: Date(timeIntervalSince1970: 42),
                    fileCount: 1,
                    ignoredDirectoryCount: 0
                ),
                entries: [cachedEntry]
            )
        )
        let indexer = DelayedFileIndexer()
        let model = AppModel(store: store, fileIndexer: indexer)

        model.selectThread(id: fixture.secondThreadID)
        model.refreshSelectedFileBrowser()

        XCTAssertEqual(model.fileBrowserState.entries, [cachedEntry])
        XCTAssertEqual(model.fileBrowserState.visibleEntries, [cachedEntry])
        XCTAssertTrue(model.fileBrowserState.isIndexing)
        XCTAssertEqual(model.fileBrowserState.metadata?.threadID, fixture.secondThreadID)
        XCTAssertEqual(model.fileBrowserState.metadata?.cacheKey, cacheKey.value)
    }

    func testWarmThreadSwitchUsesBoundedCachedBrowseAndFullSearch() throws {
        let fixture = AppModelFixtureForSharedFiles()
        let store = fixture.store
        let cacheKey = FileIndexCacheKey(
            root: fixture.root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
        let targetPath = "zz-special/warm-target.swift"
        let entries = Self.largeSyntheticEntries(count: 12_000) + [
            FileBrowserEntry(relativePath: targetPath, isDirectory: false)
        ]
        store.upsertCachedFileIndex(
            CachedFileIndex(
                metadata: FileIndexMetadata(
                    threadID: fixture.firstThreadID,
                    cacheKey: cacheKey.value,
                    rootPath: cacheKey.rootPath,
                    gitIdentity: cacheKey.gitIdentity,
                    ignoreRulesFingerprint: cacheKey.ignoreRulesFingerprint,
                    schemaVersion: cacheKey.schemaVersion,
                    indexedAt: Date(timeIntervalSince1970: 42),
                    fileCount: entries.count,
                    ignoredDirectoryCount: 0
                ),
                entries: entries
            )
        )
        let model = AppModel(store: store, fileIndexer: DelayedFileIndexer())

        model.selectThread(id: fixture.secondThreadID)

        XCTAssertEqual(model.fileBrowserState.indexedEntryCount, entries.count)
        XCTAssertEqual(model.fileBrowserState.entries.count, entries.count)
        XCTAssertFalse(model.fileBrowserState.isBrowseEntryLimitApplied)

        model.updateFileSearchQuery("warm-target")

        XCTAssertEqual(model.fileBrowserState.visibleEntries.map(\.relativePath), [targetPath])

        model.selectThread(id: fixture.firstThreadID)

        XCTAssertEqual(model.fileBrowserState.indexedEntryCount, entries.count)
        XCTAssertEqual(model.fileBrowserState.entries.count, entries.count)
        XCTAssertFalse(model.fileBrowserState.isBrowseEntryLimitApplied)
    }

    func testAppModelDeduplicatesSameThreadIndexRefreshes() throws {
        let fixture = AppModelFixtureForFiles()
        let indexer = ManualFileIndexer()
        let model = AppModel(store: fixture.store, fileIndexer: indexer)
        let secondEntry = FileBrowserEntry(relativePath: "new.swift", isDirectory: false)

        model.refreshSelectedFileBrowser()
        model.refreshSelectedFileBrowser()

        XCTAssertEqual(indexer.requestCount, 1)

        indexer.completeRequest(
            at: 0,
            result: .success(
                indexer.result(
                    threadID: fixture.firstThreadID, root: fixture.firstRoot, entries: [secondEntry]
                ))
        )

        XCTAssertEqual(model.fileBrowserState.entries, [secondEntry])
        XCTAssertEqual(model.fileBrowserState.metadata?.fileCount, 1)
    }

    func testExpandingPrunedDirectoryMergesLazySubtreeAndMakesItSearchable() throws {
        let fixture = AppModelFixtureForFiles()
        let indexer = ManualFileIndexer()
        let model = AppModel(store: fixture.store, fileIndexer: indexer)
        let prunedDir = FileBrowserEntry(
            relativePath: "node_modules", isDirectory: true, isPruned: true)
        let readme = FileBrowserEntry(relativePath: "README.md", isDirectory: false)

        model.refreshSelectedFileBrowser()
        indexer.completeRequest(
            at: 0,
            result: .success(
                indexer.result(
                    threadID: fixture.firstThreadID, root: fixture.firstRoot,
                    entries: [readme, prunedDir])))

        XCTAssertTrue(model.fileBrowserState.entries.contains(prunedDir))

        model.expandPrunedDirectory(relativePath: "node_modules")
        XCTAssertEqual(indexer.subtreeRequestCount, 1)

        let needle = FileBrowserEntry(
            relativePath: "node_modules/pkg/needle.js", isDirectory: false)
        let subtree = [
            FileBrowserEntry(relativePath: "node_modules", isDirectory: true, isPruned: false),
            FileBrowserEntry(relativePath: "node_modules/pkg", isDirectory: true),
            needle,
        ]
        indexer.completeSubtreeRequest(
            at: 0,
            result: .success(
                FileIndexResult(
                    entries: subtree,
                    metadata: FileIndexMetadata(
                        threadID: fixture.firstThreadID,
                        rootPath: fixture.firstRoot.path,
                        indexedAt: Date(timeIntervalSince1970: 5),
                        fileCount: subtree.count,
                        ignoredDirectoryCount: 0))))

        // The pruned placeholder is replaced by the loaded contents.
        XCTAssertFalse(model.fileBrowserState.entries.contains { $0.relativePath == "node_modules" && $0.isPruned })
        XCTAssertTrue(model.fileBrowserState.entries.contains(needle))
        XCTAssertEqual(model.fileBrowserState.metadata?.ignoredDirectoryCount, 0)

        // Lazily-loaded files now participate in fuzzy search.
        model.updateFileSearchQuery("needle.js")
        XCTAssertEqual(model.fileBrowserState.visibleEntries.map(\.relativePath), [needle.relativePath])
    }

    func testExpandingDirectoryIgnoresNonPrunedAndDuplicateRequests() throws {
        let fixture = AppModelFixtureForFiles()
        let indexer = ManualFileIndexer()
        let model = AppModel(store: fixture.store, fileIndexer: indexer)
        let prunedDir = FileBrowserEntry(
            relativePath: "node_modules", isDirectory: true, isPruned: true)
        let plainDir = FileBrowserEntry(relativePath: "src", isDirectory: true)

        model.refreshSelectedFileBrowser()
        indexer.completeRequest(
            at: 0,
            result: .success(
                indexer.result(
                    threadID: fixture.firstThreadID, root: fixture.firstRoot,
                    entries: [plainDir, prunedDir])))

        // Ordinary directories never trigger a lazy load.
        model.expandPrunedDirectory(relativePath: "src")
        XCTAssertEqual(indexer.subtreeRequestCount, 0)

        // Repeated expands of the same pruned directory coalesce to one request.
        model.expandPrunedDirectory(relativePath: "node_modules")
        model.expandPrunedDirectory(relativePath: "node_modules")
        XCTAssertEqual(indexer.subtreeRequestCount, 1)
    }

    func testAppModelPublishesFullBrowseIndexAndSearchesAcrossFullIndex() throws {
        let fixture = AppModelFixtureForFiles()
        let indexer = ManualFileIndexer()
        let recorder = RecordingDiagnosticEventRecorder()
        let model = AppModel(
            store: fixture.store, fileIndexer: indexer, diagnosticRecorder: recorder)
        let entries = Self.largeSyntheticEntries(count: 150_000)
        let targetPath = "zz-special/needle-target.swift"
        let adjacentTargetPath = "zz-special/needle-target-next.swift"
        let allEntries =
            entries + [
                FileBrowserEntry(relativePath: targetPath, isDirectory: false),
                FileBrowserEntry(relativePath: adjacentTargetPath, isDirectory: false),
            ]

        model.refreshSelectedFileBrowser()
        indexer.completeRequest(
            at: 0,
            result: .success(
                FileIndexResult(
                    entries: allEntries,
                    metadata: FileIndexMetadata(
                        threadID: fixture.firstThreadID,
                        rootPath: fixture.firstRoot.path,
                        indexedAt: Date(),
                        fileCount: allEntries.count,
                        ignoredDirectoryCount: 0
                    )
                ))
        )

        XCTAssertEqual(model.fileBrowserState.indexedEntryCount, allEntries.count)
        XCTAssertEqual(model.fileBrowserState.entries.count, allEntries.count)
        XCTAssertEqual(model.fileBrowserState.visibleEntries.count, allEntries.count)
        XCTAssertFalse(model.fileBrowserState.isBrowseEntryLimitApplied)
        XCTAssertFalse(model.fileBrowserState.isVisibleEntryLimitApplied)

        model.updateFileSearchQuery("needle-target")

        XCTAssertEqual(
            model.fileBrowserState.visibleEntries.map(\.relativePath),
            [targetPath, adjacentTargetPath])
        model.selectFile(relativePath: targetPath)
        XCTAssertEqual(model.selectedFileRelativePath, targetPath)
        model.selectAdjacentFile(direction: .down)
        XCTAssertEqual(model.selectedFileRelativePath, adjacentTargetPath)
        model.updateFileSearchQuery("")
        XCTAssertEqual(model.fileBrowserState.visibleEntries.count, model.fileBrowserState.entries.count)
        XCTAssertFalse(model.fileBrowserState.isVisibleEntryLimitApplied)
        XCTAssertTrue(recorder.events.contains { $0.name == "file_index_completed" })
        XCTAssertTrue(recorder.events.contains { $0.name == "file_browser_search_completed" })
    }

    func testClearingLargeIndexSearchRestoresFullBrowseList() throws {
        let fixture = AppModelFixtureForFiles()
        let indexer = ManualFileIndexer()
        let model = AppModel(store: fixture.store, fileIndexer: indexer)
        let entries = Self.largeSyntheticEntries(count: 12_000)

        model.refreshSelectedFileBrowser()
        indexer.completeRequest(
            at: 0,
            result: .success(
                FileIndexResult(
                    entries: entries,
                    metadata: FileIndexMetadata(
                        threadID: fixture.firstThreadID,
                        rootPath: fixture.firstRoot.path,
                        indexedAt: Date(),
                        fileCount: entries.count,
                        ignoredDirectoryCount: 0
                    )
                ))
        )

        model.updateFileSearchQuery("module_11")
        XCTAssertLessThanOrEqual(model.fileBrowserState.visibleEntries.count, 1_000)
        XCTAssertTrue(model.fileBrowserState.isVisibleEntryLimitApplied)

        model.updateFileSearchQuery("")

        XCTAssertEqual(model.fileBrowserState.visibleEntries.count, model.fileBrowserState.entries.count)
        XCTAssertEqual(model.fileBrowserState.entries.count, entries.count)
        XCTAssertFalse(model.fileBrowserState.isVisibleEntryLimitApplied)
        XCTAssertFalse(model.fileBrowserState.isBrowseEntryLimitApplied)
    }

    func testAppModelPublishesFilesWhenLargeCachedIndexStartsWithDirectories() throws {
        let fixture = AppModelFixtureForFiles()
        let indexer = ManualFileIndexer()
        let model = AppModel(store: fixture.store, fileIndexer: indexer)
        let entries = Self.directoryHeavyEntries(directoryCount: 12_000, fileCount: 4_000)

        model.refreshSelectedFileBrowser()
        indexer.completeRequest(
            at: 0,
            result: .success(
                FileIndexResult(
                    entries: entries,
                    metadata: FileIndexMetadata(
                        threadID: fixture.firstThreadID,
                        rootPath: fixture.firstRoot.path,
                        indexedAt: Date(),
                        fileCount: entries.count,
                        ignoredDirectoryCount: 0
                    )
                ))
        )

        XCTAssertEqual(model.fileBrowserState.entries.count, entries.count)
        XCTAssertEqual(model.fileBrowserState.visibleEntries.count, model.fileBrowserState.entries.count)
        XCTAssertTrue(model.fileBrowserState.entries.contains { !$0.isDirectory })
        XCTAssertTrue(model.fileBrowserState.visibleEntries.contains { !$0.isDirectory })
        XCTAssertFalse(model.fileBrowserState.isBrowseEntryLimitApplied)
        XCTAssertNotNil(model.selectedFileRelativePath)
    }

    private static func largeSyntheticEntries(count: Int) -> [FileBrowserEntry] {
        var entries = [
            FileBrowserEntry(relativePath: "src", isDirectory: true),
            FileBrowserEntry(relativePath: "src/generated", isDirectory: true),
            FileBrowserEntry(relativePath: "tests", isDirectory: true),
            FileBrowserEntry(relativePath: "tests/generated", isDirectory: true),
        ]
        entries.reserveCapacity(count + entries.count)
        for index in 0..<count {
            let root = index.isMultiple(of: 2) ? "src/generated" : "tests/generated"
            entries.append(
                FileBrowserEntry(relativePath: "\(root)/module_\(index).swift", isDirectory: false))
        }
        return entries
    }

    private static func directoryHeavyEntries(directoryCount: Int, fileCount: Int)
        -> [FileBrowserEntry]
    {
        var entries: [FileBrowserEntry] = []
        entries.reserveCapacity(directoryCount + fileCount)
        for index in 0..<directoryCount {
            entries.append(
                FileBrowserEntry(
                    relativePath: String(format: "dir_%05d", index),
                    isDirectory: true
                ))
        }
        for index in 0..<fileCount {
            entries.append(
                FileBrowserEntry(
                    relativePath: String(format: "dir_%05d/file_%05d.swift", index, index),
                    isDirectory: false
                ))
        }
        return entries
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

private final class DelayedFileIndexer: FileIndexing {
    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {}

    func indexSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {}
}

private final class ManualFileIndexer: FileIndexing {
    private var completions: [@Sendable (Result<FileIndexResult, Error>) -> Void] = []
    private var subtreeCompletions: [@Sendable (Result<FileIndexResult, Error>) -> Void] = []
    var requestCount: Int { completions.count }
    var subtreeRequestCount: Int { subtreeCompletions.count }

    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        completions.append(completion)
    }

    func indexSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        subtreeCompletions.append(completion)
    }

    func completeRequest(at index: Int, result: Result<FileIndexResult, Error>) {
        completions[index](result)
    }

    func completeSubtreeRequest(at index: Int, result: Result<FileIndexResult, Error>) {
        subtreeCompletions[index](result)
    }

    func result(threadID: UUID, root: URL, entries: [FileBrowserEntry]) -> FileIndexResult {
        FileIndexResult(
            entries: entries,
            metadata: FileIndexMetadata(
                threadID: threadID,
                rootPath: root.path,
                indexedAt: Date(timeIntervalSince1970: TimeInterval(entries.count)),
                fileCount: entries.count,
                ignoredDirectoryCount: 0
            )
        )
    }
}

private final class FileIndexResultBox: @unchecked Sendable {
    var value: FileIndexResult?
}

private final class RecordingDiagnosticEventRecorder: DiagnosticEventRecording, @unchecked Sendable
{
    private(set) var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        events.append(event)
    }
}

private struct AppModelFixtureForSharedFiles {
    let projectID = UUID()
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("YAAWKitTests-shared-\(UUID().uuidString)", isDirectory: true)

    var store: InMemoryYAAWStore {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: root)],
                threads: [
                    AgentThread(
                        id: firstThreadID,
                        displayName: "First",
                        projectID: projectID,
                        workingDirectory: root
                    ),
                    AgentThread(
                        id: secondThreadID,
                        displayName: "Second",
                        projectID: projectID,
                        workingDirectory: root
                    ),
                ],
                selectedProjectID: projectID,
                selectedThreadID: firstThreadID,
                rightPanelModesByThreadID: [firstThreadID: .files, secondThreadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
    }
}

private struct AppModelFixtureForFiles {
    let projectID = UUID()
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let firstRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("YAAWKitTests-first-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("YAAWKitTests-second-\(UUID().uuidString)", isDirectory: true)

    var store: InMemoryYAAWStore {
        try? FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        return InMemoryYAAWStore(
            snapshot: YAAWSnapshot(
                projects: [
                    Project(id: projectID, displayName: "Project", rootDirectory: firstRoot)
                ],
                threads: [
                    AgentThread(
                        id: firstThreadID,
                        displayName: "First",
                        projectID: projectID,
                        workingDirectory: firstRoot
                    ),
                    AgentThread(
                        id: secondThreadID,
                        displayName: "Second",
                        projectID: projectID,
                        workingDirectory: secondRoot
                    ),
                ],
                selectedProjectID: projectID,
                selectedThreadID: firstThreadID,
                rightPanelModesByThreadID: [firstThreadID: .files, secondThreadID: .files],
                selectedRightPanelMode: .files,
                isGlobalTerminalExpanded: false
            )
        )
    }
}
