import Foundation

/// Whether a project's root directory currently exists on disk, carrying its path.
public enum ProjectDirectoryState: Equatable, Sendable {
    /// The directory exists at the given path.
    case available(path: String)
    /// The directory is missing from the given path.
    case missing(path: String)

    /// The directory path, regardless of availability.
    public var path: String {
        switch self {
        case .available(let path), .missing(let path):
            return path
        }
    }

    /// Whether the directory is missing from disk.
    public var isMissing: Bool {
        if case .missing = self {
            return true
        }
        return false
    }
}
