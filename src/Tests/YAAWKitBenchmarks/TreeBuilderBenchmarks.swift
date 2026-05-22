import Foundation
import XCTest

@testable import YAAWKit

final class TreeBuilderBenchmarks: BenchmarkCase {
    private lazy var entries5k: [FileBrowserEntry] = Self.synthesizeEntries(count: 5_000)
    private lazy var entries50k: [FileBrowserEntry] = Self.synthesizeEntries(count: 50_000)
    private lazy var entries150k: [FileBrowserEntry] = Self.synthesizeEntries(count: 150_000)
    private lazy var directoryHeavyEntries150k: [FileBrowserEntry] =
        Self.synthesizeDirectoryHeavyEntries(
            directoryCount: 120_000,
            fileCount: 30_000
        )

    func test_bench_treeBuilder_5k() throws {
        let entries = entries5k
        _ = FileBrowserTreeBuilder.roots(from: entries)
        measure {
            _ = FileBrowserTreeBuilder.roots(from: entries)
        }
    }

    func test_bench_treeBuilder_50k() throws {
        let entries = entries50k
        _ = FileBrowserTreeBuilder.roots(from: entries)
        measure {
            _ = FileBrowserTreeBuilder.roots(from: entries)
        }
    }

    func test_bench_visibleRows_50k_collapsed() throws {
        let entries = entries50k
        _ = FileBrowserTreeBuilder.visibleRows(from: entries, expandedFolders: [], limit: 10_000)
        measure {
            _ = FileBrowserTreeBuilder.visibleRows(
                from: entries, expandedFolders: [], limit: 10_000)
        }
    }

    func test_bench_visibleRows_50k_oneExpandedBranch() throws {
        let entries = entries50k
        let expandedFolders: Set<String> = ["src", "src/core"]
        _ = FileBrowserTreeBuilder.visibleRows(
            from: entries, expandedFolders: expandedFolders, limit: 10_000)
        measure {
            _ = FileBrowserTreeBuilder.visibleRows(
                from: entries, expandedFolders: expandedFolders, limit: 10_000)
        }
    }

    func test_bench_visibleRows_150k_collapsed() throws {
        let entries = entries150k
        _ = FileBrowserTreeBuilder.visibleRows(from: entries, expandedFolders: [], limit: 10_000)
        measure {
            _ = FileBrowserTreeBuilder.visibleRows(
                from: entries, expandedFolders: [], limit: 10_000)
        }
    }

    func test_bench_visibleRows_150k_oneExpandedBranch() throws {
        let entries = entries150k
        let expandedFolders: Set<String> = ["src", "src/core"]
        _ = FileBrowserTreeBuilder.visibleRows(
            from: entries, expandedFolders: expandedFolders, limit: 10_000)
        measure {
            _ = FileBrowserTreeBuilder.visibleRows(
                from: entries, expandedFolders: expandedFolders, limit: 10_000)
        }
    }

    func test_bench_visibleRows_150k_cappedTenThousandRows() throws {
        let entries = entries150k
        let expandedFolders = Self.allExpandedFolders()
        _ = FileBrowserTreeBuilder.visibleRows(
            from: entries, expandedFolders: expandedFolders, limit: 10_000)
        measure {
            _ = FileBrowserTreeBuilder.visibleRows(
                from: entries, expandedFolders: expandedFolders, limit: 10_000)
        }
    }

    func test_bench_presentationEntries_150k_treeOrdered() throws {
        let entries = entries150k
        _ = FileBrowserTreeBuilder.presentationEntries(from: entries, limit: 10_000)
        measure {
            _ = FileBrowserTreeBuilder.presentationEntries(from: entries, limit: 10_000)
        }
    }

    func test_bench_presentationEntries_150k_directoryHeavy() throws {
        let entries = directoryHeavyEntries150k
        _ = FileBrowserTreeBuilder.presentationEntries(from: entries, limit: 10_000)
        measure {
            _ = FileBrowserTreeBuilder.presentationEntries(from: entries, limit: 10_000)
        }
    }

    private static func allExpandedFolders() -> Set<String> {
        let topDirs = ["src", "tests", "docs", "scripts", "vendor", "scenarios", "internal", "pkg"]
        let midDirs = ["core", "view", "model", "render", "store", "util", "feature", "api"]
        var expanded = Set(topDirs)
        for top in topDirs {
            for mid in midDirs {
                expanded.insert("\(top)/\(mid)")
            }
        }
        return expanded
    }

    private static func synthesizeEntries(count: Int) -> [FileBrowserEntry] {
        let suffixes = ["swift", "ts", "go", "py", "md", "json", "yaml", "rs", "c", "h"]
        let topDirs = ["src", "tests", "docs", "scripts", "vendor", "scenarios", "internal", "pkg"]
        let midDirs = ["core", "view", "model", "render", "store", "util", "feature", "api"]
        var entries: [FileBrowserEntry] = []
        entries.reserveCapacity(count + topDirs.count + topDirs.count * midDirs.count)
        for top in topDirs {
            entries.append(FileBrowserEntry(relativePath: top, isDirectory: true))
            for mid in midDirs {
                entries.append(FileBrowserEntry(relativePath: "\(top)/\(mid)", isDirectory: true))
            }
        }
        for index in 0..<count {
            let top = topDirs[index % topDirs.count]
            let mid = midDirs[(index / topDirs.count) % midDirs.count]
            let leaf = "module_\(index).\(suffixes[index % suffixes.count])"
            entries.append(
                FileBrowserEntry(
                    relativePath: "\(top)/\(mid)/\(leaf)",
                    isDirectory: false
                )
            )
        }
        return entries
    }

    private static func synthesizeDirectoryHeavyEntries(
        directoryCount: Int,
        fileCount: Int
    ) -> [FileBrowserEntry] {
        var entries: [FileBrowserEntry] = []
        entries.reserveCapacity(directoryCount + fileCount)
        for index in 0..<directoryCount {
            entries.append(
                FileBrowserEntry(
                    relativePath: String(format: "dir_%05d", index),
                    isDirectory: true
                ))
        }
        for index in 0..<fileCount {
            entries.append(
                FileBrowserEntry(
                    relativePath: String(format: "dir_%05d/file_%05d.swift", index, index),
                    isDirectory: false
                ))
        }
        return entries
    }
}
