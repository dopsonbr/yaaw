import Foundation

/// Git identity component of a file-index cache key: the cache is invalidated
/// when the checked-out branch/commit changes.
///
/// Extracted from the file-index cache so domain types (`FileIndexMetadata`) can
/// reference it without pulling in the cache itself. The resolver that reads
/// `.git/HEAD` (and the session-caching of that read) lives in the
/// `FileIndexActor` (Chunk B).
public enum FileIndexGitIdentity: Equatable, Sendable {
    /// On a named branch (`ref: refs/heads/<name>` in HEAD).
    case branch(String)
    /// Detached HEAD pointing directly at a commit.
    case detached(String)
    /// Root is not inside a git working tree.
    case notRepository

    /// Stable string used as the git component of a file-index cache key.
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
