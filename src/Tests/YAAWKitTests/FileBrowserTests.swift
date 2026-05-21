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
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "Pictures/Photos Library.photoslibrary", isDirectory: true))
        XCTAssertFalse(matcher.shouldIgnore(relativePath: "dist", isDirectory: false))
        XCTAssertFalse(matcher.shouldIgnore(relativePath: "src/.build", isDirectory: false))
        XCTAssertFalse(matcher.shouldIgnore(relativePath: ".env", isDirectory: false))
        XCTAssertFalse(matcher.shouldIgnore(relativePath: "src/.config/settings.json", isDirectory: false))
    }

    func testPathNormalizationRemovesRootAndCollapsesSeparators() throws {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let file = URL(fileURLWithPath: "/tmp/project/src//App.swift")

        XCTAssertEqual(FilePathNormalizer.relativePath(for: file, from: root), "src/App.swift")
        XCTAssertEqual(FilePathNormalizer.normalizedRelativePath("./src\\Core//AppModel.swift"), "src/Core/AppModel.swift")
        XCTAssertEqual(FilePathNormalizer.normalizedRule(" /node_modules/ "), "node_modules")
    }

    func testFuzzyRankingPrefersExactFilenameThenPrefixThenFuzzyPath() {
        let entries = [
            FileBrowserEntry(relativePath: "src/r/e/a/d/m/e.swift", isDirectory: false),
            FileBrowserEntry(relativePath: "docs/README.md", isDirectory: false),
            FileBrowserEntry(relativePath: "README", isDirectory: false),
            FileBrowserEntry(relativePath: "src/other.swift", isDirectory: false)
        ]

        let ranked = FuzzyFileMatcher.rankedEntries(entries, query: "readme")

        XCTAssertEqual(ranked.map(\.relativePath), [
            "README",
            "docs/README.md",
            "src/r/e/a/d/m/e.swift"
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
        try writeFile(root.appendingPathComponent("Music/Music Library.musiclibrary/db"), contents: "ignored")
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
        XCTAssertTrue(result.entries.contains(FileBrowserEntry(relativePath: ".env", isDirectory: false)))
        XCTAssertTrue(result.entries.contains(FileBrowserEntry(relativePath: "src", isDirectory: true)))
        XCTAssertTrue(result.entries.contains(FileBrowserEntry(relativePath: "src/main.swift", isDirectory: false)))
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains("node_modules") })
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains(".git") })
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains("Music") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".yaaw").path))
    }

    func testCacheKeyIncludesDirectoryBranchAndIgnoreRules() throws {
        let root = try temporaryDirectory()
        try writeFile(root.appendingPathComponent(".git/HEAD"), contents: "ref: refs/heads/main\n")

        let mainKey = FileIndexCacheKey(root: root, ignoreRules: [".git", "node_modules"])
        let sameMainKey = FileIndexCacheKey(root: root, ignoreRules: ["node_modules", ".git"])

        XCTAssertEqual(mainKey.value, sameMainKey.value)
        XCTAssertEqual(mainKey.gitIdentity, "branch:refs/heads/main")

        try writeFile(root.appendingPathComponent(".git/HEAD"), contents: "ref: refs/heads/feature\n")
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
        let cacheKey = coordinator.cacheKey(root: root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
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
        XCTAssertTrue(model.fileBrowserState.isIndexing == false || model.fileBrowserState.rootPath == fixture.secondRoot.path)
    }

    func testAppModelShowsSharedCachedEntriesWhileRefreshIsInProgress() throws {
        let fixture = AppModelFixtureForSharedFiles()
        let store = fixture.store
        let cacheKey = FileIndexCacheKey(root: fixture.root, ignoreRules: YAAWConfiguration.defaultIgnoreRules)
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
            result: .success(indexer.result(threadID: fixture.firstThreadID, root: fixture.firstRoot, entries: [secondEntry]))
        )

        XCTAssertEqual(model.fileBrowserState.entries, [secondEntry])
        XCTAssertEqual(model.fileBrowserState.metadata?.fileCount, 1)
    }

    private func writeFile(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
                    )
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
                projects: [Project(id: projectID, displayName: "Project", rootDirectory: firstRoot)],
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
                    )
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
