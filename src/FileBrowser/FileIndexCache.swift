import Foundation

public enum FileIndexGitIdentity: Equatable, Sendable {
    case branch(String)
    case detached(String)
    case notRepository

    public var cacheComponent: String {
        switch self {
        case .branch(let ref):
            "branch:\(ref)"
        case .detached(let commit):
            "detached:\(commit)"
        case .notRepository:
            "nogit"
        }
    }
}

public protocol FileIndexGitIdentityResolving: Sendable {
    func gitIdentity(for root: URL) -> FileIndexGitIdentity
}

public struct FileIndexGitIdentityResolver: FileIndexGitIdentityResolving {
    public init() {}

    public func gitIdentity(for root: URL) -> FileIndexGitIdentity {
        guard let gitURL = Self.findGitURL(startingAt: root.standardizedFileURL) else {
            return .notRepository
        }
        let headURL = gitURL.appendingPathComponent("HEAD")
        guard
            let head = try? String(contentsOf: headURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !head.isEmpty
        else {
            return .notRepository
        }
        if head.hasPrefix("ref: ") {
            return .branch(String(head.dropFirst("ref: ".count)))
        }
        return .detached(head)
    }

    private static func findGitURL(startingAt root: URL) -> URL? {
        var currentPath = root.path
        while true {
            let current = URL(fileURLWithPath: currentPath, isDirectory: true)
            let dotGit = current.appendingPathComponent(".git")
            if let gitURL = resolvedGitURL(dotGit: dotGit, repositoryRoot: current) {
                return gitURL
            }
            let parentPath = (currentPath as NSString).deletingLastPathComponent
            guard !parentPath.isEmpty, parentPath != currentPath else { return nil }
            currentPath = parentPath
        }
    }

    private static func resolvedGitURL(dotGit: URL, repositoryRoot: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return dotGit
        }
        guard
            let contents = try? String(contentsOf: dotGit, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            contents.hasPrefix("gitdir:")
        else {
            return nil
        }
        let path = contents.dropFirst("gitdir:".count).trimmingCharacters(
            in: .whitespacesAndNewlines)
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return repositoryRoot.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}

public struct FileIndexCacheKey: Equatable, Sendable {
    public let value: String
    public let rootPath: String
    public let gitIdentity: String
    public let ignoreRulesFingerprint: String
    public let schemaVersion: Int

    public init(
        root: URL,
        ignoreRules: [String],
        gitIdentityResolver: any FileIndexGitIdentityResolving = FileIndexGitIdentityResolver(),
        schemaVersion: Int = FileIndexMetadata.currentSchemaVersion
    ) {
        self.rootPath = root.standardizedFileURL.path
        self.gitIdentity = gitIdentityResolver.gitIdentity(for: root).cacheComponent
        self.ignoreRulesFingerprint = Self.fingerprint(ignoreRules: ignoreRules)
        self.schemaVersion = schemaVersion
        let digest = Self.fingerprint(parts: [
            rootPath,
            gitIdentity,
            ignoreRulesFingerprint,
            "\(schemaVersion)",
        ])
        self.value = "file-index:v\(schemaVersion):\(digest)"
    }

    public static func fingerprint(ignoreRules: [String]) -> String {
        fingerprint(
            parts: ignoreRules.map(FilePathNormalizer.normalizedRule).filter { !$0.isEmpty }
                .sorted())
    }

    private static func fingerprint(parts: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for scalar in parts.joined(separator: "\u{1f}").unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public struct CachedFileIndex: Equatable, Sendable {
    public var metadata: FileIndexMetadata
    public var entries: [FileBrowserEntry]

    public init(metadata: FileIndexMetadata, entries: [FileBrowserEntry]) {
        self.metadata = metadata
        self.entries = entries
    }

    public func forThread(_ threadID: UUID) -> CachedFileIndex {
        CachedFileIndex(metadata: metadata.forThread(threadID), entries: entries)
    }
}

public final class FileIndexCacheCoordinator: @unchecked Sendable {
    private let store: YAAWStore
    private let fileIndexer: FileIndexing
    private let gitIdentityResolver: any FileIndexGitIdentityResolving
    private let lock = NSLock()
    private var inFlightByCacheKey: [String: [PendingFileIndexConsumer]] = [:]

    public init(
        store: YAAWStore,
        fileIndexer: FileIndexing,
        gitIdentityResolver: any FileIndexGitIdentityResolving = FileIndexGitIdentityResolver()
    ) {
        self.store = store
        self.fileIndexer = fileIndexer
        self.gitIdentityResolver = gitIdentityResolver
    }

    public func cacheKey(root: URL, ignoreRules: [String]) -> FileIndexCacheKey {
        FileIndexCacheKey(
            root: root, ignoreRules: ignoreRules, gitIdentityResolver: gitIdentityResolver)
    }

    public func cachedIndex(threadID: UUID, key: FileIndexCacheKey) -> FileIndexResult? {
        store.cachedFileIndex(cacheKey: key.value).map { cached in
            FileIndexResult(entries: cached.entries, metadata: cached.metadata.forThread(threadID))
        }
    }

    public func refreshIndex(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        key: FileIndexCacheKey,
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        let consumer = PendingFileIndexConsumer(threadID: threadID, completion: completion)
        lock.lock()
        if inFlightByCacheKey[key.value] != nil {
            inFlightByCacheKey[key.value, default: []].append(consumer)
            lock.unlock()
            return
        }
        inFlightByCacheKey[key.value] = [consumer]
        lock.unlock()

        fileIndexer.indexFiles(threadID: threadID, root: root, ignoreRules: ignoreRules) {
            [weak self] result in
            self?.finishRefresh(result: result, key: key)
        }
    }

    private func finishRefresh(result: Result<FileIndexResult, Error>, key: FileIndexCacheKey) {
        lock.lock()
        let consumers = inFlightByCacheKey.removeValue(forKey: key.value) ?? []
        lock.unlock()

        switch result {
        case .success(let result):
            var metadata = result.metadata
            metadata.cacheKey = key.value
            metadata.rootPath = key.rootPath
            metadata.gitIdentity = key.gitIdentity
            metadata.ignoreRulesFingerprint = key.ignoreRulesFingerprint
            metadata.schemaVersion = key.schemaVersion
            let cached = CachedFileIndex(metadata: metadata, entries: result.entries)
            store.upsertCachedFileIndex(cached)
            for consumer in consumers {
                consumer.completion(
                    .success(
                        FileIndexResult(
                            entries: result.entries,
                            metadata: metadata.forThread(consumer.threadID)
                        )))
            }
        case .failure(let error):
            for consumer in consumers {
                consumer.completion(.failure(error))
            }
        }
    }
}

private struct PendingFileIndexConsumer {
    let threadID: UUID
    let completion: @Sendable (Result<FileIndexResult, Error>) -> Void
}
