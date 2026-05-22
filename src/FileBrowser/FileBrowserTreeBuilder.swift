import Foundation

public struct FileBrowserTreeNode: Identifiable, Equatable, Sendable {
    public let entry: FileBrowserEntry
    public let displayName: String
    public let children: [FileBrowserTreeNode]

    public init(entry: FileBrowserEntry, displayName: String, children: [FileBrowserTreeNode]) {
        self.entry = entry
        self.displayName = displayName
        self.children = children
    }

    public var id: String { entry.id }
}

public struct FileBrowserVisibleTreeRow: Identifiable, Equatable, Sendable {
    public let entry: FileBrowserEntry
    public let displayName: String
    public let depth: Int

    public init(entry: FileBrowserEntry, displayName: String, depth: Int) {
        self.entry = entry
        self.displayName = displayName
        self.depth = depth
    }

    public var id: String { entry.id }
}

public enum FileBrowserTreeBuilder {
    private static let minimumBalancedFileRows = 1_000

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

    public static func presentationEntries(
        from entries: [FileBrowserEntry],
        limit: Int
    ) -> [FileBrowserEntry] {
        guard limit > 0 else { return [] }
        guard entries.count > limit else { return entries }

        var selectedByPath: [String: FileBrowserEntry] = [:]
        var selected: [FileBrowserEntry] = []
        selected.reserveCapacity(limit)

        func append(_ entry: FileBrowserEntry) {
            guard selected.count < limit, selectedByPath[entry.relativePath] == nil else { return }
            selectedByPath[entry.relativePath] = entry
            selected.append(entry)
        }

        let visibleFileFloor = min(minimumBalancedFileRows, max(1, limit / 10))
        let rootEntryBudget = max(1, limit - visibleFileFloor)
        // Keep the collapsed tree useful when one early branch exceeds the cap.
        for entry in entries where isRootEntry(entry) {
            guard selected.count < rootEntryBudget else { break }
            append(entry)
        }

        let directoryBudget = max(1, limit * 2 / 3)
        for entry in entries where entry.isDirectory {
            guard selected.count < directoryBudget else { break }
            append(entry)
        }

        var visibleFileCount = selected.lazy.filter { !$0.isDirectory }.prefix(visibleFileFloor)
            .count
        for entry in entries where !entry.isDirectory {
            for ancestor in ancestorEntries(for: entry.relativePath) {
                append(ancestor)
            }
            let previousCount = selected.count
            append(entry)
            if selected.count > previousCount {
                visibleFileCount += 1
            }
            if selected.count >= limit && visibleFileCount >= visibleFileFloor { break }
        }

        for entry in entries {
            append(entry)
            if selected.count >= limit { break }
        }

        return selected.sorted(by: Self.sortEntriesForTree)
    }

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

    public static func sortEntriesForTree(_ left: FileBrowserEntry, _ right: FileBrowserEntry)
        -> Bool
    {
        let leftComponents = left.relativePath.split(separator: "/").map(String.init)
        let rightComponents = right.relativePath.split(separator: "/").map(String.init)
        let sharedCount = min(leftComponents.count, rightComponents.count)

        for index in 0..<sharedCount where leftComponents[index] != rightComponents[index] {
            // At the first diverging component, all prior components matched — so the
            // entries share a parent at depth `index`. Decide order at that level by
            // whether each side is a directory there: a directory at level `index` either
            // has more components below (count > index+1) or is itself a directory leaf.
            let leftIsDirAtLevel = leftComponents.count > index + 1 || left.isDirectory
            let rightIsDirAtLevel = rightComponents.count > index + 1 || right.isDirectory
            let leftHidden = isHiddenName(leftComponents[index])
            let rightHidden = isHiddenName(rightComponents[index])
            if leftHidden != rightHidden {
                return !leftHidden
            }
            if leftIsDirAtLevel != rightIsDirAtLevel {
                return leftIsDirAtLevel && !rightIsDirAtLevel
            }
            return leftComponents[index].localizedStandardCompare(rightComponents[index])
                == .orderedAscending
        }

        if leftComponents.count != rightComponents.count {
            return leftComponents.count < rightComponents.count
        }
        if left.isDirectory != right.isDirectory {
            return left.isDirectory && !right.isDirectory
        }
        return left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
    }

    private static func isRootEntry(_ entry: FileBrowserEntry) -> Bool {
        !entry.relativePath.contains("/")
    }

    private static func isHiddenName(_ name: String) -> Bool {
        name.hasPrefix(".")
    }

    private static func ancestorEntries(for relativePath: String) -> [FileBrowserEntry] {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return [] }
        var ancestors: [FileBrowserEntry] = []
        ancestors.reserveCapacity(components.count - 1)
        var currentPath = ""
        for component in components.dropLast() {
            currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
            ancestors.append(FileBrowserEntry(relativePath: currentPath, isDirectory: true))
        }
        return ancestors
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
