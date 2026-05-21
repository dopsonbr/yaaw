import Foundation
import XCTest
@testable import YAAWKit

final class FuzzyMatcherBenchmarks: BenchmarkCase {
    private lazy var entries5k: [FileBrowserEntry] = Self.synthesizeEntries(count: 5_000)
    private lazy var entries50k: [FileBrowserEntry] = Self.synthesizeEntries(count: 50_000)

    func test_bench_fuzzy_5k_singleChar() throws {
        let entries = entries5k
        measure {
            _ = FuzzyFileMatcher.rankedEntries(entries, query: "s")
        }
    }

    func test_bench_fuzzy_5k_threeChar() throws {
        let entries = entries5k
        measure {
            _ = FuzzyFileMatcher.rankedEntries(entries, query: "swi")
        }
    }

    func test_bench_fuzzy_5k_eightChar() throws {
        let entries = entries5k
        measure {
            _ = FuzzyFileMatcher.rankedEntries(entries, query: "scenario")
        }
    }

    func test_bench_fuzzy_50k_threeChar() throws {
        let entries = entries50k
        measure {
            _ = FuzzyFileMatcher.rankedEntries(entries, query: "swi")
        }
    }

    private static func synthesizeEntries(count: Int) -> [FileBrowserEntry] {
        let suffixes = ["swift", "ts", "go", "py", "md", "json", "yaml", "rs", "c", "h"]
        let topDirs = ["src", "tests", "docs", "scripts", "vendor", "scenarios", "internal", "pkg"]
        let midDirs = ["core", "view", "model", "render", "store", "util", "feature", "api"]
        var entries: [FileBrowserEntry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            let top = topDirs[index % topDirs.count]
            let mid = midDirs[(index / topDirs.count) % midDirs.count]
            let leaf = "module_\(index)_scenario.\(suffixes[index % suffixes.count])"
            entries.append(
                FileBrowserEntry(
                    relativePath: "\(top)/\(mid)/\(leaf)",
                    isDirectory: false
                )
            )
        }
        return entries
    }
}
