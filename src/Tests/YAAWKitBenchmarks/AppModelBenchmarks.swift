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
