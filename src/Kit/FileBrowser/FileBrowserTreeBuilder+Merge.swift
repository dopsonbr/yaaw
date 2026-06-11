import Foundation

extension FileBrowserTreeBuilder {
    /// Merges a lazily-indexed subtree into the full entry list: drops the pruned
    /// placeholder for `prunedPath`, removes any stale entries beneath it, and
    /// splices in the subtree entries (which include `prunedPath` itself,
    /// un-pruned) while keeping depth-first pre-order. Idempotent: re-merging the
    /// same subtree replaces it cleanly.
    ///
    /// Both inputs are already sorted in pre-order, and dropping a contiguous
    /// pruned block leaves the remainder sorted, so this is a two-way merge of
    /// two sorted runs rather than a full re-sort of the combined array — the
    /// merge stays O(n) instead of O(n log n).
    public static func merging(
        _ entries: [FileBrowserEntry],
        withSubtree subtree: [FileBrowserEntry],
        replacingPrunedPath prunedPath: String
    ) -> [FileBrowserEntry] {
        let descendantPrefix = "\(prunedPath)/"
        let filtered = entries.filter { entry in
            entry.relativePath != prunedPath
                && !entry.relativePath.hasPrefix(descendantPrefix)
        }
        return mergeSortedRuns(filtered, subtree)
    }

    /// Merges two pre-order-sorted runs into one pre-order-sorted run, taking the
    /// lesser head (per `sortEntriesForTree`) at each step.
    static func mergeSortedRuns(
        _ left: [FileBrowserEntry],
        _ right: [FileBrowserEntry]
    ) -> [FileBrowserEntry] {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        var merged: [FileBrowserEntry] = []
        merged.reserveCapacity(left.count + right.count)
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex
        while leftIndex < left.endIndex, rightIndex < right.endIndex {
            if sortEntriesForTree(right[rightIndex], left[leftIndex]) {
                merged.append(right[rightIndex])
                rightIndex = right.index(after: rightIndex)
            } else {
                merged.append(left[leftIndex])
                leftIndex = left.index(after: leftIndex)
            }
        }
        if leftIndex < left.endIndex { merged.append(contentsOf: left[leftIndex...]) }
        if rightIndex < right.endIndex { merged.append(contentsOf: right[rightIndex...]) }
        return merged
    }

    /// Depth-first pre-order comparator: directories before files at each level,
    /// hidden (dot-prefixed) names last, then `localizedStandardCompare`.
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
}
