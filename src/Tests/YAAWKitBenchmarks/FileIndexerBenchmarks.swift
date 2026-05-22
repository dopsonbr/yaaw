import Foundation
import XCTest

@testable import YAAWKit

final class FileIndexerBenchmarks: BenchmarkCase {
    private var smallRoot: URL?
    private var mediumRoot: URL?
    private var largeRoot: URL?

    override func tearDown() async throws {
        for root in [smallRoot, mediumRoot, largeRoot].compactMap({ $0 }) {
            BenchmarkSupport.removeDirectory(root)
        }
        smallRoot = nil
        mediumRoot = nil
        largeRoot = nil
        try await super.tearDown()
    }

    func test_bench_index_smallRepo() throws {
        let root = try makeFixture(
            named: "small", files: 100, directories: 10, withIgnoredDirs: false)
        smallRoot = root
        measure {
            _ = try? BackgroundFileIndexer.buildIndex(
                threadID: UUID(),
                root: root,
                ignoreRules: YAAWConfiguration.defaultIgnoreRules
            )
        }
    }

    func test_bench_index_mediumRepo() throws {
        let root = try makeFixture(
            named: "medium", files: 5_000, directories: 200, withIgnoredDirs: true)
        mediumRoot = root
        measure {
            _ = try? BackgroundFileIndexer.buildIndex(
                threadID: UUID(),
                root: root,
                ignoreRules: YAAWConfiguration.defaultIgnoreRules
            )
        }
    }

    func test_bench_index_largeRepo() throws {
        let root = try makeFixture(
            named: "large", files: 50_000, directories: 2_000, withIgnoredDirs: true)
        largeRoot = root
        measure {
            _ = try? BackgroundFileIndexer.buildIndex(
                threadID: UUID(),
                root: root,
                ignoreRules: YAAWConfiguration.defaultIgnoreRules
            )
        }
    }

    private func makeFixture(
        named name: String,
        files: Int,
        directories: Int,
        withIgnoredDirs: Bool
    ) throws -> URL {
        let root = try BenchmarkSupport.temporaryDirectory(named: "indexer-\(name)")
        let fileManager = FileManager.default
        let directoryURLs: [URL] = try (0..<directories).map { idx in
            let dir = root.appendingPathComponent("dir_\(idx)/sub_\(idx % 50)", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        for index in 0..<files {
            let dir = directoryURLs[index % max(directoryURLs.count, 1)]
            let file = dir.appendingPathComponent("file_\(index).txt")
            try Data().write(to: file)
        }
        if withIgnoredDirs {
            let nodeModules = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
            let dotGit = root.appendingPathComponent(".git/objects/ab", isDirectory: true)
            try fileManager.createDirectory(at: nodeModules, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: dotGit, withIntermediateDirectories: true)
            for index in 0..<1_000 {
                try Data().write(to: nodeModules.appendingPathComponent("m_\(index).js"))
                try Data().write(to: dotGit.appendingPathComponent("obj_\(index)"))
            }
        }
        return root
    }
}
