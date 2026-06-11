import Foundation

/// Resolves the git identity (branch / detached commit / not-a-repo) for a
/// directory by reading `.git/HEAD`. Pure I/O; the per-session caching lives in
/// `FileIndexActor`.
public protocol FileIndexGitIdentityResolving: Sendable {
    /// Resolves the git identity for the working tree containing `root`.
    func gitIdentity(for root: URL) -> FileIndexGitIdentity
}

/// Default resolver: walks up from `root` to find `.git` (handling git-worktree
/// `gitdir:` references) and parses `HEAD`.
public struct FileIndexGitIdentityResolver: FileIndexGitIdentityResolving {
    /// Creates a resolver.
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

/// The durable file-index cache key: root path + git identity + ignore-rule
/// fingerprint + schema version, hashed into a stable string. The cache is
/// invalidated whenever any component changes.
public struct FileIndexCacheKey: Equatable, Sendable {
    /// The full hashed key string used to look up / store the cached index.
    public let value: String
    /// The standardized root directory path.
    public let rootPath: String
    /// The git identity cache component (e.g. `branch:refs/heads/main`).
    public let gitIdentity: String
    /// The FNV-1a fingerprint of the (normalized, sorted) ignore rules.
    public let ignoreRulesFingerprint: String
    /// The cache schema version this key was built against.
    public let schemaVersion: Int

    /// Builds a cache key, resolving the git identity via `gitIdentityResolver`
    /// (a fresh `.git/HEAD` read each time). Use ``init(root:ignoreRules:gitIdentity:schemaVersion:)``
    /// to supply a pre-resolved (session-cached) identity instead.
    public init(
        root: URL,
        ignoreRules: [String],
        gitIdentityResolver: any FileIndexGitIdentityResolving = FileIndexGitIdentityResolver(),
        schemaVersion: Int = FileIndexMetadata.currentSchemaVersion
    ) {
        self.init(
            root: root,
            ignoreRules: ignoreRules,
            gitIdentity: gitIdentityResolver.gitIdentity(for: root),
            schemaVersion: schemaVersion)
    }

    /// Builds a cache key from an already-resolved git identity, avoiding a
    /// redundant `.git/HEAD` read. `FileIndexActor` uses this with its session
    /// cache.
    public init(
        root: URL,
        ignoreRules: [String],
        gitIdentity: FileIndexGitIdentity,
        schemaVersion: Int = FileIndexMetadata.currentSchemaVersion
    ) {
        self.rootPath = root.standardizedFileURL.path
        self.gitIdentity = gitIdentity.cacheComponent
        self.ignoreRulesFingerprint = Self.fingerprint(ignoreRules: ignoreRules)
        self.schemaVersion = schemaVersion
        let digest = Self.fingerprint(parts: [
            rootPath,
            self.gitIdentity,
            ignoreRulesFingerprint,
            "\(schemaVersion)",
        ])
        self.value = "file-index:v\(schemaVersion):\(digest)"
    }

    /// The FNV-1a fingerprint of the normalized, sorted, non-empty ignore rules.
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
