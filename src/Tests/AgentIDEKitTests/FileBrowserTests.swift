import XCTest
@testable import AgentIDEKit

final class FileBrowserTests: XCTestCase {
    func testDefaultIgnoreRulesSkipHeavyDirectoriesButKeepHiddenFiles() throws {
        let matcher = FileBrowserIgnoreMatcher(rules: AgentIDEConfiguration.defaultIgnoreRules)

        XCTAssertTrue(matcher.shouldIgnore(relativePath: ".git", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "src/node_modules", isDirectory: true))
        XCTAssertTrue(matcher.shouldIgnore(relativePath: "DerivedData/App", isDirectory: true))
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
        let threadID = UUID()

        let result = try BackgroundFileIndexer.buildIndex(
            threadID: threadID,
            root: root,
            ignoreRules: AgentIDEConfiguration.defaultIgnoreRules,
            indexedAt: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(result.metadata.threadID, threadID)
        XCTAssertEqual(result.metadata.rootPath, root.standardizedFileURL.path)
        XCTAssertEqual(result.metadata.fileCount, result.entries.count)
        XCTAssertEqual(result.metadata.ignoredDirectoryCount, 4)
        XCTAssertTrue(result.entries.contains(FileBrowserEntry(relativePath: ".env", isDirectory: false)))
        XCTAssertTrue(result.entries.contains(FileBrowserEntry(relativePath: "src", isDirectory: true)))
        XCTAssertTrue(result.entries.contains(FileBrowserEntry(relativePath: "src/main.swift", isDirectory: false)))
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains("node_modules") })
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains(".git") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".agent-ide").path))
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

    func testAppModelIgnoresStaleSameThreadIndexResults() throws {
        let fixture = AppModelFixtureForFiles()
        let indexer = ManualFileIndexer()
        let model = AppModel(store: fixture.store, fileIndexer: indexer)
        let firstEntry = FileBrowserEntry(relativePath: "old.swift", isDirectory: false)
        let secondEntry = FileBrowserEntry(relativePath: "new.swift", isDirectory: false)

        model.refreshSelectedFileBrowser()
        model.refreshSelectedFileBrowser()
        indexer.completeRequest(
            at: 1,
            result: .success(indexer.result(threadID: fixture.firstThreadID, root: fixture.firstRoot, entries: [secondEntry]))
        )
        indexer.completeRequest(
            at: 0,
            result: .success(indexer.result(threadID: fixture.firstThreadID, root: fixture.firstRoot, entries: [firstEntry]))
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
            .appendingPathComponent("AgentIDEKitTests-\(UUID().uuidString)", isDirectory: true)
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

private struct AppModelFixtureForFiles {
    let projectID = UUID()
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let firstRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentIDEKitTests-first-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentIDEKitTests-second-\(UUID().uuidString)", isDirectory: true)

    var store: InMemoryAgentIDEStore {
        InMemoryAgentIDEStore(
            snapshot: AgentIDESnapshot(
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
