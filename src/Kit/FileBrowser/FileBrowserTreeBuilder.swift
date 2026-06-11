import Foundation

/// A node in the file-browser tree: an entry plus its display name and children.
public struct FileBrowserTreeNode: Identifiable, Equatable, Sendable {
    /// The entry this node represents.
    public let entry: FileBrowserEntry
    /// The last path component, shown in the UI.
    public let displayName: String
    /// The sorted child nodes.
    public let children: [FileBrowserTreeNode]

    /// Creates a tree node.
    public init(entry: FileBrowserEntry, displayName: String, children: [FileBrowserTreeNode]) {
        self.entry = entry
        self.displayName = displayName
        self.children = children
    }

    /// Stable identity (the entry's relative path).
    public var id: String { entry.id }
}

/// One visible row in the flattened, expansion-aware tree walk.
public struct FileBrowserVisibleTreeRow: Identifiable, Equatable, Sendable {
    /// The entry shown in this row.
    public let entry: FileBrowserEntry
    /// The last path component, shown in the UI.
    public let displayName: String
    /// Indentation depth (0 for root entries).
    public let depth: Int

    /// Creates a visible tree row.
    public init(entry: FileBrowserEntry, displayName: String, depth: Int) {
        self.entry = entry
        self.displayName = displayName
        self.depth = depth
    }

    /// Stable identity (the entry's relative path).
    public var id: String { entry.id }
}

/// Pure, stateless helpers that turn a flat, sorted entry list into trees,
/// children indexes, visible-row walks, and merged subtrees.
public enum FileBrowserTreeBuilder {
    /// Builds the full sorted tree of root nodes from a flat entry list.
    public static func roots(from entries: [FileBrowserEntry]) -> [FileBrowserTreeNode] {
        var boxesByPath: [String: FileBrowserTreeNodeBox] = [:]
        var rootBoxes: [FileBrowserTreeNodeBox] = []

        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var currentPath = ""
            var parent: FileBrowserTreeNodeBox?

            for (index, component) in components.enumerated() {
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                let isLeaf = index == components.count - 1
                let isDirectory = isLeaf ? entry.isDirectory : true
                let isNewBox: Bool
                let box: FileBrowserTreeNodeBox
                if let existing = boxesByPath[currentPath] {
                    box = existing
                    isNewBox = false
                } else {
                    box = FileBrowserTreeNodeBox(
                        entry: FileBrowserEntry(
                            relativePath: currentPath, isDirectory: isDirectory),
                        name: component
                    )
                    boxesByPath[currentPath] = box
                    isNewBox = true
                }

                if isNewBox {
                    if let parent {
                        parent.appendChild(box)
                    } else {
                        rootBoxes.append(box)
                    }
                }
                parent = box
            }
        }

        return
            rootBoxes
            .sorted(by: Self.sortBoxes)
            .map { Self.node(from: $0) }
    }

    /// Maps each parent relative path (root entries use an empty string) to its
    /// ordered child entries. Built once per index so the visible-row walk can
    /// descend only into expanded folders instead of rescanning every entry on
    /// each expand/collapse. The input is assumed pre-sorted by
    /// `sortEntriesForTree` (depth-first pre-order), so appending in input order
    /// already leaves each parent's children in their correct sibling order.
    public static func childrenIndex(
        from entries: [FileBrowserEntry]
    ) -> [String: [FileBrowserEntry]] {
        var childrenByParent: [String: [FileBrowserEntry]] = [:]
        for entry in entries {
            let parent: String
            if let slashIndex = entry.relativePath.lastIndex(of: "/") {
                parent = String(entry.relativePath[..<slashIndex])
            } else {
                parent = ""
            }
            childrenByParent[parent, default: []].append(entry)
        }
        return childrenByParent
    }

    /// Walks a prebuilt children index depth-first, emitting a row for every
    /// entry whose ancestors are all expanded. Cost is proportional to the rows
    /// emitted (bounded by `limit`), not the size of the full index, so expanding
    /// a folder in a 150k-entry monorepo stays responsive — the full index is
    /// fed in without a lossy presentation cap, so every folder reveals its
    /// actual contents on demand.
    public static func visibleRows(
        childrenIndex: [String: [FileBrowserEntry]],
        expandedFolders: Set<String>,
        limit: Int
    ) -> [FileBrowserVisibleTreeRow] {
        guard limit > 0 else { return [] }
        var rows: [FileBrowserVisibleTreeRow] = []
        rows.reserveCapacity(min(limit, 256))

        func appendChildren(of parent: String, depth: Int) {
            guard let children = childrenIndex[parent] else { return }
            for child in children {
                if rows.count >= limit { return }
                let displayName: String
                if let slashIndex = child.relativePath.lastIndex(of: "/") {
                    displayName = String(
                        child.relativePath[child.relativePath.index(after: slashIndex)...])
                } else {
                    displayName = child.relativePath
                }
                rows.append(
                    FileBrowserVisibleTreeRow(
                        entry: child, displayName: displayName, depth: depth))
                if child.isDirectory, expandedFolders.contains(child.relativePath) {
                    appendChildren(of: child.relativePath, depth: depth + 1)
                }
            }
        }

        appendChildren(of: "", depth: 0)
        return rows
    }

    /// Walks a flat entry list, emitting a row for every entry whose ancestors
    /// are all expanded. O(entries); prefer the children-index variant for hot
    /// paths. Kept for parity with the historical walk and as a cross-check.
    public static func visibleRows(
        from entries: [FileBrowserEntry],
        expandedFolders: Set<String>,
        limit: Int
    ) -> [FileBrowserVisibleTreeRow] {
        guard limit > 0 else { return [] }
        var rows: [FileBrowserVisibleTreeRow] = []
        rows.reserveCapacity(min(entries.count, limit))

        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            guard isVisible(components: components, expandedFolders: expandedFolders) else {
                continue
            }

            rows.append(
                FileBrowserVisibleTreeRow(
                    entry: entry,
                    displayName: components.last ?? entry.relativePath,
                    depth: components.count - 1
                )
            )

            if rows.count >= limit { break }
        }

        return rows
    }

    private static func isVisible(components: [String], expandedFolders: Set<String>) -> Bool {
        guard components.count > 1 else { return true }
        var ancestor = ""
        for component in components.dropLast() {
            ancestor = ancestor.isEmpty ? component : "\(ancestor)/\(component)"
            if !expandedFolders.contains(ancestor) {
                return false
            }
        }
        return true
    }

    private static func node(from box: FileBrowserTreeNodeBox) -> FileBrowserTreeNode {
        let children = box.children.sorted(by: Self.sortBoxes).map { Self.node(from: $0) }
        return FileBrowserTreeNode(entry: box.entry, displayName: box.name, children: children)
    }

    private static func sortBoxes(_ left: FileBrowserTreeNodeBox, _ right: FileBrowserTreeNodeBox)
        -> Bool
    {
        let leftHidden = isHiddenName(left.name)
        let rightHidden = isHiddenName(right.name)
        if leftHidden != rightHidden {
            return !leftHidden
        }
        if left.entry.isDirectory != right.entry.isDirectory {
            return left.entry.isDirectory && !right.entry.isDirectory
        }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    static func isHiddenName(_ name: String) -> Bool {
        name.hasPrefix(".")
    }
}

private final class FileBrowserTreeNodeBox {
    let entry: FileBrowserEntry
    let name: String
    private(set) var children: [FileBrowserTreeNodeBox] = []

    init(entry: FileBrowserEntry, name: String) {
        self.entry = entry
        self.name = name
    }

    func appendChild(_ child: FileBrowserTreeNodeBox) {
        children.append(child)
    }
}
