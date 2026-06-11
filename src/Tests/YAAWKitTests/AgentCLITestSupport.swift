import XCTest

@testable import YAAWKit

/// Shared helpers for the AgentCLI / SessionBindingActor test suites (split
/// across several files to satisfy the tightened file-length limits).

/// Async-friendly unwrap: the actor returns optionals after `await`, so the
/// expression must be evaluated before being unwrapped (an `await` may not
/// appear inside `XCTUnwrap`'s autoclosure).
func unwrapAsync<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// A unique temporary directory for a test, created on disk.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes an executable script to `path`.
func writeExecutableFile(at path: URL, contents: String) throws {
    try contents.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
}

/// An executable resolver backed by a fixed name → path map.
struct StaticExecutableResolver: AgentCLIExecutableResolving {
    let paths: [String: String]

    func executablePath(named executableName: String, environment: [String: String]) -> String? {
        paths[executableName]
    }
}

extension FileHandle {
    /// Appends `text` at the end of the file, then closes the handle.
    func closeAfterAppending(_ text: String) throws {
        defer { try? close() }
        try seekToEnd()
        try write(contentsOf: Data(text.utf8))
    }
}
