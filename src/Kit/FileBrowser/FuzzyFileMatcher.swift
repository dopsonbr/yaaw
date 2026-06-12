import Foundation

/// The outcome of a single file-index build: the (sorted) entries plus the
/// metadata describing the index that produced them.
public struct FileIndexResult: Equatable, Sendable {
    /// The indexed entries, sorted in depth-first pre-order.
    public var entries: [FileBrowserEntry]
    /// Metadata describing the index (root, git identity, counts, …).
    public var metadata: FileIndexMetadata
    /// Whether the eager walk stopped early at the entry cap or time budget (the
    /// tree is larger than was indexed). In-memory only — not persisted; the
    /// indexed subset is still searchable and deeper dirs remain lazily expandable.
    public var isTruncated: Bool

    /// Creates a file-index result.
    public init(
        entries: [FileBrowserEntry], metadata: FileIndexMetadata, isTruncated: Bool = false
    ) {
        self.entries = entries
        self.metadata = metadata
        self.isTruncated = isTruncated
    }
}

/// Loud failures raised while indexing a directory tree.
public enum FileBrowserIndexError: Error, Equatable {
    /// The requested root directory does not exist or is not a directory.
    case missingRoot(String)
}

/// Decides whether a directory should be pruned (shown collapsed, indexed
/// lazily) based on the configured ignore rules. Pure value type, safe to share.
public struct FileBrowserIgnoreMatcher: Equatable, Sendable {
    private let rules: Set<String>

    /// Builds a matcher from raw ignore-rule strings, normalizing each rule and
    /// dropping empties.
    public init(rules: [String]) {
        self.rules = Set(
            rules
                .map { FilePathNormalizer.normalizedRule($0) }
                .filter { !$0.isEmpty }
        )
    }

    /// Whether the directory at `relativePath` matches an ignore rule. Only
    /// directories are ever ignored; files always pass through.
    public func shouldIgnore(relativePath: String, isDirectory: Bool) -> Bool {
        guard isDirectory else { return false }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        guard !normalizedPath.isEmpty else { return false }
        let components = normalizedPath.split(separator: "/").map(String.init)
        for component in components where rules.contains(component) {
            return true
        }
        return rules.contains(normalizedPath)
    }
}

/// Ranks file entries against a fuzzy query. Pure, stateless algorithm: exact
/// filename match (rank 0) beats a filename prefix (1000+), which beats a path
/// prefix (2000+), which beats a gap-penalised fuzzy subsequence (3000+).
public enum FuzzyFileMatcher {
    /// A bounded ranking result: the kept entries plus how many matched in total
    /// and whether a limit truncated the output.
    public struct Result: Equatable, Sendable {
        /// The kept entries, best-ranked first.
        public let entries: [FileBrowserEntry]
        /// How many entries matched the query before any limit was applied.
        public let totalMatches: Int
        /// Whether `entries` was truncated by the limit.
        public let isLimitApplied: Bool

        /// Creates a ranking result.
        public init(entries: [FileBrowserEntry], totalMatches: Int, isLimitApplied: Bool) {
            self.entries = entries
            self.totalMatches = totalMatches
            self.isLimitApplied = isLimitApplied
        }
    }

    /// Ranks `entries` against `query`, returning all matches best-first.
    public static func rankedEntries(
        _ entries: [FileBrowserEntry],
        query: String
    ) -> [FileBrowserEntry] {
        rankedResult(entries, query: query, limit: nil).entries
    }

    /// Ranks `entries` against `query`, keeping at most `limit` best matches.
    public static func rankedEntries(
        _ entries: [FileBrowserEntry],
        query: String,
        limit: Int
    ) -> [FileBrowserEntry] {
        rankedResult(entries, query: query, limit: limit).entries
    }

    /// Ranks `entries` against `query`. An empty query returns the (optionally
    /// limited) input unchanged; a non-empty query ranks and sorts matches.
    public static func rankedResult(
        _ entries: [FileBrowserEntry],
        query: String,
        limit: Int?
    ) -> Result {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedQuery.isEmpty {
            let limitedEntries = limit.map { Array(entries.prefix($0)) } ?? entries
            return Result(
                entries: limitedEntries, totalMatches: entries.count,
                isLimitApplied: limitedEntries.count < entries.count)
        }
        if let limit {
            return rankedLimitedResult(entries, query: normalizedQuery, limit: limit)
        }
        let ranked =
            entries
            .compactMap { entry -> RankedFileBrowserEntry? in
                rank(entry, query: normalizedQuery).map {
                    RankedFileBrowserEntry(entry: entry, rank: $0)
                }
            }
            .sorted { left, right in
                if left.rank != right.rank { return left.rank < right.rank }
                return left.entry.relativePath.localizedStandardCompare(right.entry.relativePath)
                    == .orderedAscending
            }
        let limitedEntries = limit.map { Array(ranked.prefix($0)) } ?? ranked
        return Result(
            entries: limitedEntries.map(\.entry),
            totalMatches: ranked.count,
            isLimitApplied: limitedEntries.count < ranked.count
        )
    }

    private static func rankedLimitedResult(
        _ entries: [FileBrowserEntry],
        query: String,
        limit: Int
    ) -> Result {
        guard limit > 0 else {
            let totalMatches = entries.reduce(0) { count, entry in
                rank(entry, query: query) == nil ? count : count + 1
            }
            return Result(entries: [], totalMatches: totalMatches, isLimitApplied: totalMatches > 0)
        }

        var buffer = BoundedRankedFileBuffer(limit: limit)
        var totalMatches = 0
        for entry in entries {
            guard let rank = rank(entry, query: query) else { continue }
            totalMatches += 1
            buffer.insert(RankedFileBrowserEntry(entry: entry, rank: rank))
        }
        let ranked = buffer.sortedEntries()
        return Result(
            entries: ranked.map(\.entry),
            totalMatches: totalMatches,
            isLimitApplied: ranked.count < totalMatches
        )
    }

    private static func rank(_ entry: FileBrowserEntry, query: String) -> Int? {
        let path = entry.relativePath.lowercased()
        // Slice the last path component directly rather than building a `URL`:
        // entries always use forward-slash relative paths, so this is identical
        // to `URL(fileURLWithPath:).lastPathComponent` but far cheaper in the hot
        // ranking loop (no URL allocation per entry).
        let filename: String
        if let slash = path.lastIndex(of: "/") {
            filename = String(path[path.index(after: slash)...])
        } else {
            filename = path
        }
        if filename == query {
            return 0
        }
        if filename.hasPrefix(query) {
            return 1_000 + filename.count
        }
        if path.hasPrefix(query) {
            return 2_000 + path.count
        }
        guard let fuzzyScore = fuzzyScore(path: path, query: query) else {
            return nil
        }
        return 3_000 + fuzzyScore
    }

    private static func fuzzyScore(path: String, query: String) -> Int? {
        var searchStart = path.startIndex
        var previousMatch: String.Index?
        var gapPenalty = 0
        for character in query {
            guard let match = path[searchStart...].firstIndex(of: character) else {
                return nil
            }
            if let previousMatch {
                gapPenalty += path.distance(from: path.index(after: previousMatch), to: match)
            } else {
                gapPenalty += path.distance(from: path.startIndex, to: match)
            }
            previousMatch = match
            searchStart = path.index(after: match)
        }
        return gapPenalty + path.count
    }
}

private struct RankedFileBrowserEntry {
    let entry: FileBrowserEntry
    let rank: Int
}

/// A fixed-capacity max-heap (worst rank at the root) used to keep the best
/// `limit` matches while scanning a large index without sorting everything.
private struct BoundedRankedFileBuffer {
    private let limit: Int
    private var storage: [RankedFileBrowserEntry] = []

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(limit)
    }

    mutating func insert(_ entry: RankedFileBrowserEntry) {
        guard storage.count >= limit else {
            storage.append(entry)
            siftUp(from: storage.count - 1)
            return
        }
        guard let worst = storage.first, Self.precedes(entry, worst) else { return }
        storage[0] = entry
        siftDown(from: 0)
    }

    func sortedEntries() -> [RankedFileBrowserEntry] {
        storage.sorted(by: Self.precedes)
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.precedes(storage[parent], storage[child]) else { break }
            storage.swapAt(parent, child)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let leftChild = parent * 2 + 1
            let rightChild = leftChild + 1
            var worst = parent

            if leftChild < storage.count, Self.precedes(storage[worst], storage[leftChild]) {
                worst = leftChild
            }
            if rightChild < storage.count, Self.precedes(storage[worst], storage[rightChild]) {
                worst = rightChild
            }
            guard worst != parent else { break }
            storage.swapAt(parent, worst)
            parent = worst
        }
    }

    private static func precedes(_ left: RankedFileBrowserEntry, _ right: RankedFileBrowserEntry)
        -> Bool
    {
        if left.rank != right.rank { return left.rank < right.rank }
        return left.entry.relativePath.localizedStandardCompare(right.entry.relativePath)
            == .orderedAscending
    }
}
