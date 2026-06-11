import XCTest

@testable import YAAWKit

final class FileBrowserTests: XCTestCase {
    func testDefaultIgnoreRulesSkipHeavyDirectoriesButKeepHiddenFiles() throws {
        let matcher = FileBrowserIgnoreMatcher(rules: YAAWConfiguration.defaultIgnoreRules)

        XCTAssertTrue(matcher.shouldIgnore(relativePath: ".git", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "src/node_modules", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "DerivedData/App", isDirectory: true))
        // Home-directory noise (Music/Movies/Pictures) is not a default rule, so it is
        // surfaced like any other directory. `worktrees` IS a default rule: each git
        // worktree is a full checkout, so it stays collapsed and is indexed lazily on expand.
        XCTAssertFalse(matcher.shouldIgnore(relativePath: "Music", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "worktrees", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "src/worktrees", isDirectory: true))
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
        let entries = Self.sampleTreeEntries()

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
        let entries = Self.sampleTreeEntries()
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
        XCTAssertFalse(
            result.entries.contains {
                $0.relativePath.contains("/") && $0.relativePath.hasPrefix("node_modules/")
            })
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

    func testMergeMatchesFullResortAcrossManyExpansions() throws {
        // The sorted-insertion merge must yield byte-for-byte the same order as
        // the historical full re-sort, regardless of where the subtree lands.
        let base = Self.largeSyntheticEntries(count: 4_000)
            .map { entry -> FileBrowserEntry in
                entry.relativePath == "src/generated"
                    ? FileBrowserEntry(
                        relativePath: entry.relativePath, isDirectory: true, isPruned: true)
                    : entry
            }
            .sorted(by: FileBrowserTreeBuilder.sortEntriesForTree)
        let subtree = [
            FileBrowserEntry(relativePath: "src/generated", isDirectory: true, isPruned: false),
            FileBrowserEntry(relativePath: "src/generated/extra", isDirectory: true),
            FileBrowserEntry(
                relativePath: "src/generated/extra/needle.swift", isDirectory: false),
        ]

        let merged = FileBrowserTreeBuilder.merging(
            base, withSubtree: subtree, replacingPrunedPath: "src/generated")

        var expected = base.filter {
            $0.relativePath != "src/generated"
                && !$0.relativePath.hasPrefix("src/generated/")
        }
        expected.append(contentsOf: subtree)
        expected.sort(by: FileBrowserTreeBuilder.sortEntriesForTree)
        XCTAssertEqual(merged, expected)
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

    // MARK: - Fixtures

    private static func sampleTreeEntries() -> [FileBrowserEntry] {
        [
            FileBrowserEntry(relativePath: "docs", isDirectory: true),
            FileBrowserEntry(relativePath: "docs/README.md", isDirectory: false),
            FileBrowserEntry(relativePath: "src", isDirectory: true),
            FileBrowserEntry(relativePath: "src/App.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "src/Core", isDirectory: true),
            FileBrowserEntry(relativePath: "src/Core/AppModel.swift", isDirectory: false),
        ]
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
