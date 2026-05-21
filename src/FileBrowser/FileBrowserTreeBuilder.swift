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

public enum FileBrowserTreeBuilder {
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
                        entry: FileBrowserEntry(relativePath: currentPath, isDirectory: isDirectory),
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

        return rootBoxes
            .sorted(by: Self.sortBoxes)
            .map { Self.node(from: $0) }
    }

    private static func node(from box: FileBrowserTreeNodeBox) -> FileBrowserTreeNode {
        let children = box.children.sorted(by: Self.sortBoxes).map { Self.node(from: $0) }
        return FileBrowserTreeNode(entry: box.entry, displayName: box.name, children: children)
    }

    private static func sortBoxes(_ left: FileBrowserTreeNodeBox, _ right: FileBrowserTreeNodeBox) -> Bool {
        if left.entry.isDirectory != right.entry.isDirectory {
            return left.entry.isDirectory && !right.entry.isDirectory
        }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
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
