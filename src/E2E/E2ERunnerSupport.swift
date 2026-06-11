import Foundation
import YAAWKit

/// Artifact directory layout shared by the runner and the launched-app states
/// (`scripts/test-e2e.sh` mirrors these paths). Re-homed verbatim from the
/// pre-rewrite `E2EPaths`.
struct E2EPaths {
    let root: URL

    var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
    var missingToolBinDirectory: URL {
        root.appendingPathComponent("bin-missing-lazygit", isDirectory: true)
    }
    var captureDirectory: URL { root.appendingPathComponent("captures", isDirectory: true) }
    var activityDirectory: URL { root.appendingPathComponent("activity", isDirectory: true) }
    var helperBinDirectory: URL { root.appendingPathComponent("helper-bin", isDirectory: true) }
    var configPath: URL { root.appendingPathComponent("config/settings.yaml") }
    var workspaceDirectory: URL {
        root.appendingPathComponent("sandbox-workspace", isDirectory: true)
    }
    var projectDirectory: URL { root.appendingPathComponent("fixture-project", isDirectory: true) }
    var missingDirectory: URL {
        root.appendingPathComponent("missing-directory-project", isDirectory: true)
    }
    var screenshotDirectory: URL { root.appendingPathComponent("screenshots", isDirectory: true) }
    var stateDirectory: URL { root.appendingPathComponent("states", isDirectory: true) }
}

/// The IDs the launched-app states + manifest reference after the headless
/// durable-state run.
struct FocusedBehaviorResult {
    var databasePath: URL
    var codexThreadID: UUID
    var claudeThreadID: UUID
}

/// The visual states the runner pre-builds SQLite databases for; the launched
/// app loads each and the script screenshots it. Mirrors the pre-rewrite enum.
enum VisualState: String, CaseIterable {
    case launch
    case projectCreation = "project-creation"
    case files
    case nvim
    case git
    case missingDirectory = "missing-directory"
    case missingTool = "missing-tool"
    case bottomTerminal = "bottom-terminal"
    case panelResize = "panel-resize"
    case panelCollapse = "panel-collapse"
    case keyboardInput = "keyboard-input"
}

/// A headless-runner assertion failure. The `description` is surfaced on stderr
/// and exits the runner non-zero.
struct E2EFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

struct E2EOptions {
    let artifactsDirectory: URL

    init(arguments: [String]) throws {
        guard let artifactsIndex = arguments.firstIndex(of: "--artifacts"),
            artifactsIndex + 1 < arguments.count
        else {
            throw E2EFailure("usage: YAAWE2E --artifacts <directory>")
        }
        artifactsDirectory = URL(fileURLWithPath: arguments[artifactsIndex + 1], isDirectory: true)
    }
}

// MARK: - Assertion macros (port as-is)

func e2eAssert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw E2EFailure("assertion failed: \(message)")
    }
}

func e2eUnwrap<T>(_ value: T?, _ description: String) throws -> T {
    guard let value else {
        throw E2EFailure("missing \(description)")
    }
    return value
}

/// Polls `condition` up to 5s (50 × 0.1s). The async variant lets MainActor
/// store work (e.g. an awaited file-index Task) drain between polls.
@MainActor
func e2eWaitUntil(_ description: String, condition: () -> Bool) async throws {
    for _ in 0..<50 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    throw E2EFailure("timed out waiting for \(description)")
}

/// A synchronous file indexer so a refresh completes within the awaited Task
/// (mirrors the pre-rewrite `ImmediateFileIndexer` and the store-test fake).
final class ImmediateE2EFileIndexer: FileIndexing, @unchecked Sendable {
    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        completion(
            Result {
                try BackgroundFileIndexer.buildIndex(
                    threadID: threadID, root: root, ignoreRules: ignoreRules)
            })
    }

    func indexSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    ) {
        completion(
            Result {
                try BackgroundFileIndexer.buildSubtreeIndex(
                    threadID: threadID, root: root, relativeSubpath: relativeSubpath,
                    ignoreRules: ignoreRules)
            })
    }
}

extension [String] {
    /// Whether `candidate` is, or sits under, one of the protected paths.
    func containsPath(_ candidate: String) -> Bool {
        let candidate = URL(fileURLWithPath: candidate).standardizedFileURL.path
        return contains { protected in
            candidate == protected || candidate.hasPrefix(protected + "/")
        }
    }
}
