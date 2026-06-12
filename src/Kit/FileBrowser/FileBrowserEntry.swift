import Foundation

/// A single file or directory in the file-browser tree, identified by its path
/// relative to the indexed root.
public struct FileBrowserEntry: Identifiable, Equatable, Sendable {
    /// Stable identity for the entry; equals ``relativePath``.
    public let id: String
    /// Path of the entry relative to the indexed root directory.
    public let relativePath: String
    /// Whether this entry is a directory rather than a file.
    public let isDirectory: Bool
    /// A directory that matched an ignore rule: it is shown in the tree (collapsed)
    /// but its descendants are not eagerly indexed. Expanding it indexes the subtree
    /// on demand. `false` for everything else, including directories whose contents
    /// have already been loaded.
    public let isPruned: Bool

    /// Creates an entry for the file or directory at the given relative path.
    public init(relativePath: String, isDirectory: Bool, isPruned: Bool = false) {
        self.id = relativePath
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isPruned = isPruned
    }
}

/// Metadata describing a persisted file index: its identity, the inputs that
/// validate its cache, and summary counts from the indexing walk.
public struct FileIndexMetadata: Equatable, Sendable {
    /// The current on-disk index schema version; older caches are rebuilt.
    public static let currentSchemaVersion = 3

    /// The thread whose file index this metadata belongs to.
    public var threadID: UUID
    /// Shared-cache key derived from the directory and git identity, when cached.
    public var cacheKey: String?
    /// Absolute path of the indexed root directory.
    public var rootPath: String
    /// Git identity component (e.g. HEAD/commit) used to validate the cache.
    public var gitIdentity: String
    /// Fingerprint of the ignore rules in effect when the index was built.
    public var ignoreRulesFingerprint: String
    /// Schema version of the persisted index.
    public var schemaVersion: Int
    /// When the index was last built.
    public var indexedAt: Date
    /// Number of files recorded in the index.
    public var fileCount: Int
    /// Number of ignored directories that were pruned during indexing.
    public var ignoredDirectoryCount: Int

    /// Creates index metadata, defaulting schema and git identity to current values.
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

    /// Returns a copy of this metadata re-homed to the given thread.
    public func forThread(_ threadID: UUID) -> FileIndexMetadata {
        var metadata = self
        metadata.threadID = threadID
        return metadata
    }
}

/// Snapshot of the file browser's rendered state: the indexed root, the current
/// search query, the entries and which are visible, indexing status, and any error.
public struct FileBrowserState: Equatable, Sendable {
    /// Absolute path of the indexed root, or `nil` when nothing is indexed.
    public var rootPath: String?
    /// The active fuzzy-search query; empty when browsing the tree.
    public var searchQuery: String
    /// Total number of entries recorded in the index.
    public var indexedEntryCount: Int
    /// All entries currently loaded into the browser.
    public var entries: [FileBrowserEntry]
    /// The entries to render given the current query/expansion and limits.
    public var visibleEntries: [FileBrowserEntry]
    /// Whether the browse-mode entry cap truncated ``entries``.
    public var isBrowseEntryLimitApplied: Bool
    /// Whether the visible-entry cap truncated ``visibleEntries``.
    public var isVisibleEntryLimitApplied: Bool
    /// Whether an indexing walk is currently in progress.
    public var isIndexing: Bool
    /// Metadata for the current index, when one exists.
    public var metadata: FileIndexMetadata?
    /// A user-facing error message from the last indexing attempt, if any.
    public var errorMessage: String?
    /// Whether the eager index walk stopped early at its entry cap / time budget
    /// (the project is larger than was indexed). The browser shows the indexed
    /// subset; deeper folders remain lazily expandable and fuzzy search runs over
    /// what was indexed.
    public var isIndexTruncated: Bool

    /// Creates a file-browser state; every field defaults to empty/inactive.
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
        errorMessage: String? = nil,
        isIndexTruncated: Bool = false
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
        self.isIndexTruncated = isIndexTruncated
    }
}
