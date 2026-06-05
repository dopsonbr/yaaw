import Foundation
import XCTest

@testable import YAAWKit

final class AppModelBenchmarks: BenchmarkCase {
    private var workingDirectories: [URL] = []

    override func tearDown() async throws {
        for url in workingDirectories {
            BenchmarkSupport.removeDirectory(url)
        }
        workingDirectories = []
        try await super.tearDown()
    }

    func test_bench_activeThreadsForSelectedProject_1k() throws {
        let model = try makeModel(threadCount: 1_000)
        measure {
            for _ in 0..<100_000 {
                _ = model.activeThreadsForSelectedProject
            }
        }
    }

    func test_bench_activeThreadsForSelectedProject_10k() throws {
        let model = try makeModel(threadCount: 10_000)
        measure {
            for _ in 0..<100_000 {
                _ = model.activeThreadsForSelectedProject
            }
        }
    }

    func test_bench_selectedThread_lookup_10k() throws {
        let model = try makeModel(threadCount: 10_000)
        measure {
            for _ in 0..<100_000 {
                _ = model.selectedThread
            }
        }
    }

    func test_bench_selectThread_in_10kCorpus() throws {
        let model = try makeModel(threadCount: 10_000)
        let active = model.activeThreadsForSelectedProject
        let candidates = stride(from: 0, to: active.count, by: max(active.count / 20, 1)).map {
            active[$0].id
        }
        XCTAssertFalse(candidates.isEmpty)
        measure {
            for id in candidates {
                model.selectThread(id: id)
            }
        }
    }

    func test_bench_selectThread_sqlite_in_1kCorpus() throws {
        let model = try makeSQLiteModel(threadCount: 1_000)
        let active = model.activeThreadsForSelectedProject
        let candidates = stride(from: 0, to: active.count, by: max(active.count / 2, 1)).map {
            active[$0].id
        }
        XCTAssertGreaterThanOrEqual(candidates.count, 2)
        var index = 0
        measure {
            index = (index + 1) % candidates.count
            model.selectThread(id: candidates[index])
        }
    }

    func test_bench_visibleThreadSwitch_warm_cachedIndex() throws {
        let fixture = try makeVisibleSwitchModel(preseedCachedIndex: true)
        let model = fixture.model
        let switchThreadIDs = Array(fixture.threadIDs.prefix(2))
        XCTAssertEqual(switchThreadIDs.count, 2)

        for threadID in switchThreadIDs {
            model.selectThread(id: threadID)
            _ = model.activateSelectedProjectTerminal()
        }

        let stats = measureVisibleThreadSwitches(model: model, threadIDs: switchThreadIDs)
        reportVisibleSwitchStats("warm cached visible thread switch", stats)
        XCTAssertLessThanOrEqual(
            stats.p95,
            0.250,
            "warm cached visible thread switch p95 exceeded 250 ms: \(stats.report)"
        )
    }

    func test_bench_visibleThreadSwitch_cold_noCachedIndex() throws {
        let fixture = try makeVisibleSwitchModel(preseedCachedIndex: false)
        let model = fixture.model
        let switchThreadIDs = Array(fixture.threadIDs.prefix(2))
        XCTAssertEqual(switchThreadIDs.count, 2)

        let stats = measureVisibleThreadSwitches(model: model, threadIDs: switchThreadIDs)
        reportVisibleSwitchStats("cold uncached visible thread switch", stats)
    }

    func test_bench_duplicateActivity_in_10kCorpus() throws {
        let model = try makeModel(threadCount: 10_000)
        let threadID = try XCTUnwrap(model.selectedThreadID)
        model.recordAgentCLIOutput(threadID: threadID, output: "Thinking...\nEsc to interrupt\n")
        measure {
            for _ in 0..<10_000 {
                model.recordAgentCLIOutput(
                    threadID: threadID,
                    output: "Thinking...\nEsc to interrupt\n"
                )
            }
        }
    }

    private func makeModel(threadCount: Int) throws -> AppModel {
        let snapshot = Self.makeSnapshot(threadCount: threadCount)
        let store = InMemoryYAAWStore(snapshot: snapshot)
        return AppModel(store: store)
    }

    private func makeSQLiteModel(threadCount: Int) throws -> AppModel {
        let directory = try BenchmarkSupport.temporaryDirectory(named: "appmodel-sqlite")
        workingDirectories.append(directory)
        let store = try SQLiteYAAWStore(
            databasePath: directory.appendingPathComponent("state.sqlite"))
        store.save(Self.makeSnapshot(threadCount: threadCount))
        return AppModel(store: store)
    }

    private func makeVisibleSwitchModel(preseedCachedIndex: Bool) throws
        -> VisibleSwitchBenchmarkFixture
    {
        let directory = try BenchmarkSupport.temporaryDirectory(named: "visible-switch")
        workingDirectories.append(directory)
        let projectRoot = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/main\n".write(
            to: projectRoot.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let helperDirectory = directory.appendingPathComponent("helper-bin", isDirectory: true)
        let store = try SQLiteYAAWStore(
            databasePath: directory.appendingPathComponent("state.sqlite"))
        let snapshot = Self.makeVisibleSwitchSnapshot(
            threadCount: 1_000,
            workingDirectory: projectRoot
        )
        store.save(snapshot)
        let cacheKey = FileIndexCacheKey(
            root: projectRoot,
            ignoreRules: YAAWConfiguration.defaultIgnoreRules
        )
        if preseedCachedIndex {
            let entries = Self.largeFileIndexEntries(count: 60_000)
            store.upsertCachedFileIndex(
                CachedFileIndex(
                    metadata: FileIndexMetadata(
                        threadID: snapshot.threads[0].id,
                        cacheKey: cacheKey.value,
                        rootPath: cacheKey.rootPath,
                        gitIdentity: cacheKey.gitIdentity,
                        ignoreRulesFingerprint: cacheKey.ignoreRulesFingerprint,
                        schemaVersion: cacheKey.schemaVersion,
                        indexedAt: Date(timeIntervalSince1970: 1_779_800_000),
                        fileCount: entries.count,
                        ignoredDirectoryCount: 4
                    ),
                    entries: entries
                ))
        }
        let model = AppModel(
            store: store,
            terminalManager: PlaceholderTerminalSessionManager(),
            agentCLIBindings: AgentCLISessionBindingService(
                resolver: BenchmarkExecutableResolver(),
                captureDirectory: nil,
                activityDirectory: nil,
                helperBinDirectory: helperDirectory
            ),
            fileIndexer: NeverCompletingFileIndexer()
        )
        return VisibleSwitchBenchmarkFixture(model: model, threadIDs: snapshot.threads.map(\.id))
    }

    private func measureVisibleThreadSwitches(
        model: AppModel,
        threadIDs: [UUID]
    ) -> VisibleSwitchStats {
        let clock = ContinuousClock()
        let expandedFolders: Set<String> = ["src", "src/generated"]

        for index in 0..<5 {
            runVisibleSwitchIteration(
                model: model,
                threadID: threadIDs[index % threadIDs.count],
                expandedFolders: expandedFolders,
                clock: clock
            )
        }

        var samples: [Double] = []
        samples.reserveCapacity(30)
        for index in 0..<30 {
            samples.append(
                runVisibleSwitchIteration(
                    model: model,
                    threadID: threadIDs[index % threadIDs.count],
                    expandedFolders: expandedFolders,
                    clock: clock
                ))
        }
        return VisibleSwitchStats(samples: samples)
    }

    @discardableResult
    private func runVisibleSwitchIteration(
        model: AppModel,
        threadID: UUID,
        expandedFolders: Set<String>,
        clock: ContinuousClock
    ) -> Double {
        let startedAt = clock.now
        model.selectThread(id: threadID)
        _ = model.activateSelectedProjectTerminal()
        _ = FileBrowserTreeBuilder.visibleRows(
            from: model.fileBrowserState.entries,
            expandedFolders: expandedFolders,
            limit: 50_000
        )
        return Self.seconds(from: startedAt.duration(to: clock.now))
    }

    private func reportVisibleSwitchStats(_ name: String, _ stats: VisibleSwitchStats) {
        let report = "\(name): \(stats.report)"
        print(report)
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds)
            / 1_000_000_000_000_000_000
    }

    private static func makeSnapshot(threadCount: Int) -> YAAWSnapshot {
        let projectID = UUID()
        let project = Project(
            id: projectID,
            displayName: "BenchProject",
            rootDirectory: URL(fileURLWithPath: "/tmp/bench", isDirectory: true)
        )
        let threads: [AgentThread] = (0..<threadCount).map { index in
            AgentThread(
                id: UUID(),
                displayName: "thread-\(index)",
                projectID: projectID,
                workingDirectory: URL(fileURLWithPath: "/tmp/bench/\(index)", isDirectory: true),
                agentCLI: .codex,
                createdAt: Date(timeIntervalSince1970: Double(index)),
                lastOpenedAt: Date(timeIntervalSince1970: Double(index)),
                isArchived: index % 7 == 0
            )
        }
        return YAAWSnapshot(
            projects: [project],
            threads: threads,
            selectedProjectID: projectID,
            selectedThreadID: threads.first?.id,
            rightPanelModesByThreadID: [:],
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false
        )
    }

    private static func makeVisibleSwitchSnapshot(
        threadCount: Int,
        workingDirectory: URL
    ) -> YAAWSnapshot {
        let projectID = UUID()
        let project = Project(
            id: projectID,
            displayName: "BenchProject",
            rootDirectory: workingDirectory
        )
        let baseDate = Date(timeIntervalSince1970: 1_779_800_000)
        let threads: [AgentThread] = (0..<threadCount).map { index in
            AgentThread(
                id: UUID(),
                displayName: "thread-\(index)",
                projectID: projectID,
                workingDirectory: workingDirectory,
                agentCLI: .codex,
                createdAt: baseDate.addingTimeInterval(Double(index)),
                lastOpenedAt: baseDate.addingTimeInterval(Double(index))
            )
        }
        return YAAWSnapshot(
            projects: [project],
            threads: threads,
            selectedProjectID: projectID,
            selectedThreadID: threads.first?.id,
            rightPanelModesByThreadID: Dictionary(
                uniqueKeysWithValues: threads.map { ($0.id, RightPanelMode.files) }),
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false
        )
    }

    private static func largeFileIndexEntries(count: Int) -> [FileBrowserEntry] {
        var entries = [
            FileBrowserEntry(relativePath: "docs", isDirectory: true),
            FileBrowserEntry(relativePath: "src", isDirectory: true),
            FileBrowserEntry(relativePath: "src/generated", isDirectory: true),
            FileBrowserEntry(relativePath: "tests", isDirectory: true),
            FileBrowserEntry(relativePath: "tests/generated", isDirectory: true),
            FileBrowserEntry(relativePath: "README.md", isDirectory: false),
        ]
        entries.reserveCapacity(count + entries.count)
        for index in 0..<count {
            let root = index.isMultiple(of: 2) ? "src/generated" : "tests/generated"
            entries.append(
                FileBrowserEntry(
                    relativePath: String(format: "\(root)/module_%05d.swift", index),
                    isDirectory: false
                ))
        }
        return entries.sorted(by: FileBrowserTreeBuilder.sortEntriesForTree)
    }
}

private struct VisibleSwitchBenchmarkFixture {
    let model: AppModel
    let threadIDs: [UUID]
}

private struct VisibleSwitchStats {
    let samples: [Double]
    let min: Double
    let median: Double
    let p95: Double
    let max: Double

    init(samples: [Double]) {
        self.samples = samples
        let sorted = samples.sorted()
        self.min = sorted.first ?? 0
        self.median = Self.percentile(sorted, percentile: 0.50)
        self.p95 = Self.percentile(sorted, percentile: 0.95)
        self.max = sorted.last ?? 0
    }

    var report: String {
        "min=\(Self.format(min))s median=\(Self.format(median))s p95=\(Self.format(p95))s max=\(Self.format(max))s samples=\(samples.count)"
    }

    private static func percentile(_ sorted: [Double], percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int(ceil(Double(sorted.count) * percentile)) - 1
        return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

private final class NeverCompletingFileIndexer: FileIndexing {
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

private struct BenchmarkExecutableResolver: AgentCLIExecutableResolving {
    func executablePath(named executableName: String, environment: [String: String]) -> String? {
        "/usr/bin/true"
    }
}
