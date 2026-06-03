import Foundation

public struct FileBrowserEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let isDirectory: Bool
    /// A directory that matched an ignore rule: it is shown in the tree (collapsed)
    /// but its descendants are not eagerly indexed. Expanding it indexes the subtree
    /// on demand. `false` for everything else, including directories whose contents
    /// have already been loaded.
    public let isPruned: Bool

    public init(relativePath: String, isDirectory: Bool, isPruned: Bool = false) {
        self.id = relativePath
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isPruned = isPruned
    }
}

public struct FileIndexMetadata: Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var threadID: UUID
    public var cacheKey: String?
    public var rootPath: String
    public var gitIdentity: String
    public var ignoreRulesFingerprint: String
    public var schemaVersion: Int
    public var indexedAt: Date
    public var fileCount: Int
    public var ignoredDirectoryCount: Int

    public init(
        threadID: UUID,
        cacheKey: String? = nil,
        rootPath: String,
        gitIdentity: String = FileIndexGitIdentity.notRepository.cacheComponent,
        ignoreRulesFingerprint: String = "",
        schemaVersion: Int = FileIndexMetadata.currentSchemaVersion,
        indexedAt: Date,
        fileCount: Int,
        ignoredDirectoryCount: Int
    ) {
        self.threadID = threadID
        self.cacheKey = cacheKey
        self.rootPath = rootPath
        self.gitIdentity = gitIdentity
        self.ignoreRulesFingerprint = ignoreRulesFingerprint
        self.schemaVersion = schemaVersion
        self.indexedAt = indexedAt
        self.fileCount = fileCount
        self.ignoredDirectoryCount = ignoredDirectoryCount
    }

    public func forThread(_ threadID: UUID) -> FileIndexMetadata {
        var metadata = self
        metadata.threadID = threadID
        return metadata
    }
}

public struct FileBrowserState: Equatable, Sendable {
    public var rootPath: String?
    public var searchQuery: String
    public var indexedEntryCount: Int
    public var entries: [FileBrowserEntry]
    public var visibleEntries: [FileBrowserEntry]
    public var isBrowseEntryLimitApplied: Bool
    public var isVisibleEntryLimitApplied: Bool
    public var isIndexing: Bool
    public var metadata: FileIndexMetadata?
    public var errorMessage: String?

    public init(
        rootPath: String? = nil,
        searchQuery: String = "",
        indexedEntryCount: Int = 0,
        entries: [FileBrowserEntry] = [],
        visibleEntries: [FileBrowserEntry] = [],
        isBrowseEntryLimitApplied: Bool = false,
        isVisibleEntryLimitApplied: Bool = false,
        isIndexing: Bool = false,
        metadata: FileIndexMetadata? = nil,
        errorMessage: String? = nil
    ) {
        self.rootPath = rootPath
        self.searchQuery = searchQuery
        self.indexedEntryCount = indexedEntryCount
        self.entries = entries
        self.visibleEntries = visibleEntries
        self.isBrowseEntryLimitApplied = isBrowseEntryLimitApplied
        self.isVisibleEntryLimitApplied = isVisibleEntryLimitApplied
        self.isIndexing = isIndexing
        self.metadata = metadata
        self.errorMessage = errorMessage
    }
}
