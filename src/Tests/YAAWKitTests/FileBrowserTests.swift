import XCTest

@testable import YAAWKit

final class FileBrowserTests: XCTestCase {
    func testDefaultIgnoreRulesSkipHeavyDirectoriesButKeepHiddenFiles() throws {
        let matcher = FileBrowserIgnoreMatcher(rules: YAAWConfiguration.defaultIgnoreRules)

        XCTAssertTrue(matcher.shouldIgnore(relativePath: ".git", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "src/node_modules", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "DerivedData/App", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "Music", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "Movies", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "Pictures", isDirectory: true))
        XCTAssertTrue(
            matcher.shouldIgnore(
                relativePath: "Pictures/Photos Library.photoslibrary", isDirectory: true))
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

    func testPresentationEntriesIncludeFilesWhenLargeIndexStartsWithDirectories() {
        let entries = Self.directoryHeavyEntries(directoryCount: 12_000, fileCount: 4_000)

        let presented = FileBrowserTreeBuilder.presentationEntries(from: entries, limit: 10_000)
        let rows = FileBrowserTreeBuilder.visibleRows(
            from: presented,
            expandedFolders: ["dir_00000"],
            limit: 10_000
        )

        XCTAssertEqual(presented.count, 10_000)
        XCTAssertTrue(presented.contains { !$0.isDirectory })
        XCTAssertTrue(
            rows.contains(
                FileBrowserVisibleTreeRow(
                    entry: FileBrowserEntry(
                        relativePath: "dir_00000/file_00000.swift", isDirectory: false),
                    displayName: "file_00000.swift",
                    depth: 1
                )))
    }

    func testPresentationEntriesKeepRootSiblingsWhenFirstBranchExceedsLimit() {
        var entries = [
            FileBrowserEntry(relativePath: "archive", isDirectory: true),
            FileBrowserEntry(relativePath: "bin", isDirectory: true),
            FileBrowserEntry(relativePath: "docs", isDirectory: true),
            FileBrowserEntry(relativePath: "repos", isDirectory: true),
            FileBrowserEntry(relativePath: "README.md", isDirectory: false),
        ]
        for index in 0..<12_000 {
            entries.append(
                FileBrowserEntry(
                    relativePath: String(format: "archive/file_%05d.swift", index),
                    isDirectory: false
                ))
        }
        entries.sort(by: FileBrowserTreeBuilder.sortEntriesForTree)

        let presented = FileBrowserTreeBuilder.presentationEntries(from: entries, limit: 10_000)
        let rows = FileBrowserTreeBuilder.visibleRows(
            from: presented,
            expandedFolders: [],
            limit: 10_000
        )
        let visiblePaths = rows.map(\.entry.relativePath)

        XCTAssertEqual(presented.count, 10_000)
        XCTAssertTrue(visiblePaths.contains("archive"))
        XCTAssertTrue(visiblePaths.contains("bin"))
        XCTAssertTrue(visiblePaths.contains("docs"))
        XCTAssertTrue(visiblePaths.contains("repos"))
        XCTAssertTrue(visiblePaths.contains("README.md"))
    }

    func testPresentationEntriesKeepRegularRootItemsAheadOfHiddenLargeBranches() throws {
        var entries = [
            FileBrowserEntry(relativePath: ".agents", isDirectory: true),
            FileBrowserEntry(relativePath: ".claude", isDirectory: true),
            FileBrowserEntry(relativePath: ".env", isDirectory: false),
            FileBrowserEntry(relativePath: ".gitignore", isDirectory: false),
            FileBrowserEntry(relativePath: "AGENTS.md", isDirectory: false),
            FileBrowserEntry(relativePath: "README.md", isDirectory: false),
            FileBrowserEntry(relativePath: "docs", isDirectory: true),
            FileBrowserEntry(relativePath: "repos", isDirectory: true),
            FileBrowserEntry(relativePath: "src", isDirectory: true),
        ]
        for index in 0..<12_000 {
            entries.append(
                FileBrowserEntry(
                    relativePath: String(format: ".agents/cache/file_%05d.json", index),
                    isDirectory: false
                ))
        }
        entries.sort(by: FileBrowserTreeBuilder.sortEntriesForTree)

        let presented = FileBrowserTreeBuilder.presentationEntries(from: entries, limit: 10_000)
        let rows = FileBrowserTreeBuilder.visibleRows(
            from: presented,
            expandedFolders: [],
            limit: 10_000
        )
        let visiblePaths = rows.map(\.entry.relativePath)

        XCTAssertEqual(presented.count, 10_000)
        XCTAssertTrue(visiblePaths.contains("docs"))
        XCTAssertTrue(visiblePaths.contains("repos"))
        XCTAssertTrue(visiblePaths.contains("src"))
        XCTAssertTrue(visiblePaths.contains(".agents"))
        XCTAssertLessThan(
            try XCTUnwrap(visiblePaths.firstIndex(of: "docs")),
            try XCTUnwrap(visiblePaths.firstIndex(of: ".agents"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(visiblePaths.firstIndex(of: "README.md")),
            try XCTUnwrap(visiblePaths.firstIndex(of: ".env"))
        )
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

    func testTemporaryDirectoryIndexIncludesHiddenFilesAndSkipsIgnoredDirectories() throws {
        let root = try temporaryDirectory()
        try writeFile(root.appendingPathComponent(".env"), contents: "TOKEN=example")
        try writeFile(root.appendingPathComponent("README.md"), contents: "# Project")
        try writeFile(root.appendingPathComponent("src/main.swift"), contents: "print(\"hi\")")
        try writeFile(root.appendingPathComponent("node_modules/pkg/index.js"), contents: "ignored")
        try writeFile(root.appendingPathComponent(".git/config"), contents: "ignored")
        try writeFile(root.appendingPathComponent("dist/app.js"), contents: "ignored")
        try writeFile(root.appendingPathComponent("DerivedData/build.log"), contents: "ignored")
        try writeFile(
            root.appendingPathComponent("Music/Music Library.musiclibrary/db"), contents: "ignored")
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
        XCTAssertEqual(result.metadata.ignoredDirectoryCount, 5)
        XCTAssertTrue(
            result.entries.contains(FileBrowserEntry(relativePath: ".env", isDirectory: false)))
        XCTAssertTrue(
            result.entries.contains(FileBrowserEntry(relativePath: "src", isDirectory: true)))
        XCTAssertTrue(
            result.entries.contains(
                FileBrowserEntry(relativePath: "src/main.swift", isDirectory: false)))
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains("node_modules") })
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains(".git") })
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains("Music") })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".yaaw").path))
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

    func testAppModelPublishesEntireLargeIndexAndSearchesAcrossIt() throws {
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

        XCTAssertEqual(model.fileBrowserState.entries.count, allEntries.count)
        XCTAssertTrue(model.fileBrowserState.entries.contains { $0.relativePath == targetPath })
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
        XCTAssertEqual(model.fileBrowserState.visibleEntries.count, allEntries.count)
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

        XCTAssertEqual(model.fileBrowserState.visibleEntries.count, entries.count)
        XCTAssertFalse(model.fileBrowserState.isVisibleEntryLimitApplied)
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
        XCTAssertEqual(model.fileBrowserState.visibleEntries.count, entries.count)
        XCTAssertTrue(model.fileBrowserState.entries.contains { !$0.isDirectory })
        XCTAssertTrue(model.fileBrowserState.visibleEntries.contains { !$0.isDirectory })
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
}

private final class ManualFileIndexer: FileIndexing {
    private var completions: [@Sendable (Result<FileIndexResult, Error>) -> Void] = []
    var requestCount: Int { completions.count }

    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        completions.append(completion)
    }

    func completeRequest(at index: Int, result: Result<FileIndexResult, Error>) {
        completions[index](result)
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
