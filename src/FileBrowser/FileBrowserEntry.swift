import Foundation

public struct FileBrowserEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let isDirectory: Bool

    public init(relativePath: String, isDirectory: Bool) {
        self.id = relativePath
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }
}

public struct FileIndexMetadata: Equatable, Sendable {
    public static let currentSchemaVersion = 1

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
    public var entries: [FileBrowserEntry]
    public var visibleEntries: [FileBrowserEntry]
    public var isIndexing: Bool
    public var metadata: FileIndexMetadata?
    public var errorMessage: String?

    public init(
        rootPath: String? = nil,
        searchQuery: String = "",
        entries: [FileBrowserEntry] = [],
        visibleEntries: [FileBrowserEntry] = [],
        isIndexing: Bool = false,
        metadata: FileIndexMetadata? = nil,
        errorMessage: String? = nil
    ) {
        self.rootPath = rootPath
        self.searchQuery = searchQuery
        self.entries = entries
        self.visibleEntries = visibleEntries
        self.isIndexing = isIndexing
        self.metadata = metadata
        self.errorMessage = errorMessage
    }
}
