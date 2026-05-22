import Foundation
import XCTest
@testable import YAAWKit

final class FuzzyMatcherBenchmarks: BenchmarkCase {
    private lazy var entries5k: [FileBrowserEntry] = Self.synthesizeEntries(count: 5_000)
    private lazy var entries50k: [FileBrowserEntry] = Self.synthesizeEntries(count: 50_000)
    private lazy var entries150k: [FileBrowserEntry] = Self.synthesizeEntries(count: 150_000)

    func test_bench_fuzzy_5k_singleChar() throws {
        let entries = entries5k
        _ = FuzzyFileMatcher.rankedEntries(entries, query: "s")
        measure {
            _ = FuzzyFileMatcher.rankedEntries(entries, query: "s")
        }
    }

    func test_bench_fuzzy_5k_threeChar() throws {
        let entries = entries5k
        _ = FuzzyFileMatcher.rankedEntries(entries, query: "swi")
        measure {
            _ = FuzzyFileMatcher.rankedEntries(entries, query: "swi")
        }
    }

    func test_bench_fuzzy_5k_eightChar() throws {
        let entries = entries5k
        _ = FuzzyFileMatcher.rankedEntries(entries, query: "scenario")
        measure {
            _ = FuzzyFileMatcher.rankedEntries(entries, query: "scenario")
        }
    }

    func test_bench_fuzzy_50k_threeChar() throws {
        let entries = entries50k
        _ = FuzzyFileMatcher.rankedEntries(entries, query: "swi")
        measure {
            _ = FuzzyFileMatcher.rankedEntries(entries, query: "swi")
        }
    }

    func test_bench_fuzzy_50k_cappedThreeChar() throws {
        let entries = entries50k
        _ = FuzzyFileMatcher.rankedResult(entries, query: "swi", limit: 1_000)
        measure {
            _ = FuzzyFileMatcher.rankedResult(entries, query: "swi", limit: 1_000)
        }
    }

    func test_bench_fuzzy_150k_cappedThreeChar() throws {
        let entries = entries150k
        _ = FuzzyFileMatcher.rankedResult(entries, query: "swi", limit: 1_000)
        measure {
            _ = FuzzyFileMatcher.rankedResult(entries, query: "swi", limit: 1_000)
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
