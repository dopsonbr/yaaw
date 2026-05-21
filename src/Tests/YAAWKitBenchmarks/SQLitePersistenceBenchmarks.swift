import Foundation
import XCTest
@testable import YAAWKit

final class SQLitePersistenceBenchmarks: BenchmarkCase {
    private var workingDirectories: [URL] = []

    override func tearDown() async throws {
        for url in workingDirectories {
            BenchmarkSupport.removeDirectory(url)
        }
        workingDirectories = []
        try await super.tearDown()
    }

    func test_bench_save_100threads() throws { try runSaveBenchmark(threadCount: 100) }
    func test_bench_save_1k_threads() throws { try runSaveBenchmark(threadCount: 1_000) }
    func test_bench_save_10k_threads() throws { try runSaveBenchmark(threadCount: 10_000) }

    func test_bench_load_100threads() throws { try runLoadBenchmark(threadCount: 100) }
    func test_bench_load_1k_threads() throws { try runLoadBenchmark(threadCount: 1_000) }
    func test_bench_load_10k_threads() throws { try runLoadBenchmark(threadCount: 10_000) }

    func test_bench_save_singleThreadEdit_in10kCorpus() throws {
        let store = try preparedStore(threadCount: 10_000)
        var snapshot = store.load()
        measure {
            snapshot.threads[0].displayName = "edited-\(UUID().uuidString.prefix(6))"
            store.save(snapshot)
        }
    }

    private func runSaveBenchmark(threadCount: Int) throws {
        let directory = try BenchmarkSupport.temporaryDirectory(named: "sqlite-save-\(threadCount)")
        workingDirectories.append(directory)
        let path = directory.appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        let snapshot = Self.makeSnapshot(threadCount: threadCount)
        measure {
            store.save(snapshot)
        }
    }

    private func runLoadBenchmark(threadCount: Int) throws {
        let store = try preparedStore(threadCount: threadCount)
        measure {
            _ = store.load()
        }
    }

    private func preparedStore(threadCount: Int) throws -> SQLiteYAAWStore {
        let directory = try BenchmarkSupport.temporaryDirectory(named: "sqlite-prepared-\(threadCount)")
        workingDirectories.append(directory)
        let path = directory.appendingPathComponent("state.sqlite")
        let store = try SQLiteYAAWStore(databasePath: path)
        store.save(Self.makeSnapshot(threadCount: threadCount))
        return store
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
