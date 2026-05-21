import Foundation
import XCTest
@testable import YAAWKit

final class TreeBuilderBenchmarks: BenchmarkCase {
    private lazy var entries5k: [FileBrowserEntry] = Self.synthesizeEntries(count: 5_000)
    private lazy var entries50k: [FileBrowserEntry] = Self.synthesizeEntries(count: 50_000)

    func test_bench_treeBuilder_5k() throws {
        let entries = entries5k
        measure {
            _ = TreeBuilderSnapshot.roots(from: entries)
        }
    }

    func test_bench_treeBuilder_50k() throws {
        let entries = entries50k
        measure {
            _ = TreeBuilderSnapshot.roots(from: entries)
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
}

/// Frozen snapshot of the tree-builder algorithm currently inlined in RootView.swift
/// (private enum FileBrowserTreeBuilder, around lines 698–743). Kept here so the
/// baseline benchmark stays stable as Fix #3 moves the builder into YAAWKit.
private enum TreeBuilderSnapshot {
    static func roots(from entries: [FileBrowserEntry]) -> [BenchmarkTreeNode] {
        var boxesByPath: [String: BenchmarkTreeNodeBox] = [:]
        var rootBoxes: [BenchmarkTreeNodeBox] = []

        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var currentPath = ""
            var parent: BenchmarkTreeNodeBox?

            for (index, component) in components.enumerated() {
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                let isLeaf = index == components.count - 1
                let isDirectory = isLeaf ? entry.isDirectory : true
                let box = boxesByPath[currentPath] ?? BenchmarkTreeNodeBox(
                    entry: FileBrowserEntry(relativePath: currentPath, isDirectory: isDirectory),
                    name: component
                )
                boxesByPath[currentPath] = box

                if let parent {
                    parent.addChildIfNeeded(box)
                } else if !rootBoxes.contains(where: { $0.entry.relativePath == box.entry.relativePath }) {
                    rootBoxes.append(box)
                }
                parent = box
            }
        }

        return rootBoxes
            .sorted(by: Self.sortBoxes)
            .map { Self.node(from: $0) }
    }

    private static func node(from box: BenchmarkTreeNodeBox) -> BenchmarkTreeNode {
        let children = box.children.sorted(by: Self.sortBoxes).map { Self.node(from: $0) }
        return BenchmarkTreeNode(entry: box.entry, displayName: box.name, children: children)
    }

    private static func sortBoxes(_ left: BenchmarkTreeNodeBox, _ right: BenchmarkTreeNodeBox) -> Bool {
        if left.entry.isDirectory != right.entry.isDirectory {
            return left.entry.isDirectory && !right.entry.isDirectory
        }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
}

private final class BenchmarkTreeNodeBox {
    let entry: FileBrowserEntry
    let name: String
    private(set) var children: [BenchmarkTreeNodeBox] = []

    init(entry: FileBrowserEntry, name: String) {
        self.entry = entry
        self.name = name
    }

    func addChildIfNeeded(_ child: BenchmarkTreeNodeBox) {
        guard !children.contains(where: { $0.entry.relativePath == child.entry.relativePath }) else { return }
        children.append(child)
    }
}

private struct BenchmarkTreeNode {
    let entry: FileBrowserEntry
    let displayName: String
    let children: [BenchmarkTreeNode]
}
