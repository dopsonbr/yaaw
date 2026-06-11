import Foundation

/// Resolves an executable name to an absolute path.
public protocol AgentCLIExecutableResolving: Sendable {
    /// Resolves `executableName` against `environment`, returning its absolute
    /// path, or `nil` if it cannot be found.
    func executablePath(named executableName: String, environment: [String: String]) -> String?
}

/// Resolves executables by searching the `PATH` env var, then a fixed list of
/// fallback directories (Homebrew + the standard system bins).
public struct PATHAgentCLIExecutableResolver: AgentCLIExecutableResolving {
    /// Directories searched after the process `PATH`, in order.
    public static let defaultFallbackSearchPaths = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private let fallbackSearchPaths: [String]

    /// Creates a resolver with the given fallback search paths.
    public init(fallbackSearchPaths: [String] = Self.defaultFallbackSearchPaths) {
        self.fallbackSearchPaths = fallbackSearchPaths
    }

    /// Searches `PATH` then the fallback directories for `executableName`. An
    /// absolute, executable path is returned as-is.
    public func executablePath(named executableName: String, environment: [String: String])
        -> String?
    {
        if executableName.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: executableName)
        {
            return executableName
        }

        let pathValue = environment["PATH"] ?? ""
        var searchedDirectories = Set<String>()
        let searchPaths = pathValue.split(separator: ":").map(String.init) + fallbackSearchPaths
        for directory in searchPaths where searchedDirectories.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
