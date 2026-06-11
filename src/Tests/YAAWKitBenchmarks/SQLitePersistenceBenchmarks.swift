import Foundation
import XCTest
// Benchmarks measure public operations only, so a non-testable import keeps the
// release perf-gate build (`swift test -c release`) working: an `@testable`
// import of an optimized module trips a Swift 6.3 compiler crash (DECISIONS-LOG
// D-010). Timing uses pure async/await + ContinuousClock rather than XCTest's
// synchronous `measure {}` + a semaphore bridge, which also tripped the release
// optimizer.
import YAAWKit

final class SQLitePersistenceBenchmarks: BenchmarkCase {
    private var workingDirectories: [URL] = []

    override func tearDown() async throws {
        for url in workingDirectories {
            BenchmarkSupport.removeDirectory(url)
        }
        workingDirectories = []
        try await super.tearDown()
    }

    func test_bench_save_100threads() async throws { try await runSaveBenchmark(threadCount: 100) }
    func test_bench_save_1k_threads() async throws {
        try await runSaveBenchmark(threadCount: 1_000)
    }
    func test_bench_save_10k_threads() async throws {
        try await runSaveBenchmark(threadCount: 10_000)
    }

    func test_bench_load_100threads() async throws { try await runLoadBenchmark(threadCount: 100) }
    func test_bench_load_1k_threads() async throws {
        try await runLoadBenchmark(threadCount: 1_000)
    }
    func test_bench_load_10k_threads() async throws {
        try await runLoadBenchmark(threadCount: 10_000)
    }

    func test_bench_save_singleThreadEdit_in10kCorpus() async throws {
        let store = try await preparedStore(threadCount: 10_000)
        var snapshot = await store.load()
        let median = await Self.median(iterations: 20) {
            snapshot.threads[0].displayName = "edited"
            let edited = snapshot.threads[0]
            await store.upsertThread(edited)
        }
        report("save single-edit @10k", median)
    }

    private func runSaveBenchmark(threadCount: Int) async throws {
        let directory = try BenchmarkSupport.temporaryDirectory(named: "sqlite-save-\(threadCount)")
        workingDirectories.append(directory)
        let store = try SQLiteYAAWStore(
            databasePath: directory.appendingPathComponent("state.sqlite"))
        let snapshot = Self.makeSnapshot(threadCount: threadCount)
        let median = await Self.median(iterations: 10) { await store.save(snapshot) }
        report("save \(threadCount)", median)
    }

    private func runLoadBenchmark(threadCount: Int) async throws {
        let store = try await preparedStore(threadCount: threadCount)
        let median = await Self.median(iterations: 10) { _ = await store.load() }
        report("load \(threadCount)", median)
    }

    private func preparedStore(threadCount: Int) async throws -> SQLiteYAAWStore {
        let directory = try BenchmarkSupport.temporaryDirectory(
            named: "sqlite-prepared-\(threadCount)")
        workingDirectories.append(directory)
        let store = try SQLiteYAAWStore(
            databasePath: directory.appendingPathComponent("state.sqlite"))
        await store.save(Self.makeSnapshot(threadCount: threadCount))
        return store
    }

    /// Median wall-clock time of `body` across `iterations` runs.
    private static func median(iterations: Int, _ body: () async -> Void) async -> Duration {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<iterations {
            let start = clock.now
            await body()
            samples.append(clock.now - start)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func report(_ label: String, _ duration: Duration) {
        let millis =
            Double(duration.components.attoseconds) / 1e15
            + Double(duration.components.seconds) * 1_000
        print("BENCH \(label): \(String(format: "%.3f", millis)) ms (median)")
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
}
