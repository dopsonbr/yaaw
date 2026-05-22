import Foundation

public struct FileIndexResult: Equatable, Sendable {
    public var entries: [FileBrowserEntry]
    public var metadata: FileIndexMetadata

    public init(entries: [FileBrowserEntry], metadata: FileIndexMetadata) {
        self.entries = entries
        self.metadata = metadata
    }
}

public enum FileBrowserIndexError: Error, Equatable {
    case missingRoot(String)
}

public protocol FileIndexing: AnyObject {
    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    )
}

public final class BackgroundFileIndexer: FileIndexing {
    private let queue: DispatchQueue

    public init(
        queue: DispatchQueue = DispatchQueue(
            label: "dev.dopsonbr.YAAW.file-index",
            qos: .userInitiated,
            attributes: .concurrent
        )
    ) {
        self.queue = queue
    }

    public func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        let root = root.standardizedFileURL
        queue.async {
            do {
                let result = try Self.buildIndex(
                    threadID: threadID,
                    root: root,
                    ignoreRules: ignoreRules,
                    fileManager: .default
                )
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    public static func buildIndex(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        fileManager: FileManager = .default,
        indexedAt: Date = Date()
    ) throws -> FileIndexResult {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw FileBrowserIndexError.missingRoot(root.path)
        }

        let ignoreMatcher = FileBrowserIgnoreMatcher(rules: ignoreRules)
        var entries: [FileBrowserEntry] = []
        var ignoredDirectoryCount = 0
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )
        else {
            throw FileBrowserIndexError.missingRoot(root.path)
        }

        for case let url as URL in enumerator {
            let normalizedPath = FilePathNormalizer.relativePath(for: url, from: root)
            guard !normalizedPath.isEmpty else { continue }
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues.isDirectory ?? false
            if isDirectory,
                ignoreMatcher.shouldIgnore(relativePath: normalizedPath, isDirectory: true)
            {
                ignoredDirectoryCount += 1
                enumerator.skipDescendants()
                continue
            }
            if ignoreMatcher.shouldIgnore(relativePath: normalizedPath, isDirectory: isDirectory) {
                continue
            }
            entries.append(FileBrowserEntry(relativePath: normalizedPath, isDirectory: isDirectory))
        }

        entries.sort(by: FileBrowserTreeBuilder.sortEntriesForTree)

        return FileIndexResult(
            entries: entries,
            metadata: FileIndexMetadata(
                threadID: threadID,
                rootPath: root.path,
                indexedAt: indexedAt,
                fileCount: entries.count,
                ignoredDirectoryCount: ignoredDirectoryCount
            )
        )
    }
}

public struct FileBrowserIgnoreMatcher: Equatable, Sendable {
    private let rules: Set<String>

    public init(rules: [String]) {
        self.rules = Set(
            rules
                .map { FilePathNormalizer.normalizedRule($0) }
                .filter { !$0.isEmpty }
        )
    }

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

public enum FilePathNormalizer {
    public static func relativePath(for url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard path.hasPrefix(prefix) else { return normalizedRelativePath(url.lastPathComponent) }
        return normalizedRelativePath(String(path.dropFirst(prefix.count)))
    }

    public static func normalizedRelativePath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }

    public static func normalizedRule(_ rule: String) -> String {
        normalizedRelativePath(rule.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum FuzzyFileMatcher {
    public struct Result: Equatable, Sendable {
        public let entries: [FileBrowserEntry]
        public let totalMatches: Int
        public let isLimitApplied: Bool
    }

    public static func rankedEntries(
        _ entries: [FileBrowserEntry],
        query: String
    ) -> [FileBrowserEntry] {
        rankedResult(entries, query: query, limit: nil).entries
    }

    public static func rankedEntries(
        _ entries: [FileBrowserEntry],
        query: String,
        limit: Int
    ) -> [FileBrowserEntry] {
        rankedResult(entries, query: query, limit: limit).entries
    }

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
        let filename = URL(fileURLWithPath: entry.relativePath).lastPathComponent.lowercased()
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
