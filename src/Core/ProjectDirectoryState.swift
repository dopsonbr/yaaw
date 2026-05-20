import Foundation

public enum ProjectDirectoryState: Equatable, Sendable {
    case available(path: String)
    case missing(path: String)

    public var path: String {
        switch self {
        case .available(let path), .missing(let path):
            return path
        }
    }

    public var isMissing: Bool {
        if case .missing = self {
            return true
        }
        return false
    }
}
