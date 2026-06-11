import Foundation

extension SessionCatalogReader {
    /// Resolves the concrete file URLs a ``CatalogLocation`` pattern matches for
    /// the given working directory.
    ///
    /// Supported pattern shapes:
    /// - literal file (`session_index.jsonl`)
    /// - `*.ext` — every matching file directly under the base
    /// - `*/leaf` — `leaf` inside each subdirectory of the base (copilot)
    /// - `{encoded-workdir}/*.ext` — claude project dirs for the working dir
    ///
    /// When `includeContainers` is true, the base/parent directories themselves
    /// are included so the signature also reacts to additions/removals.
    func matchedURLs(
        for location: CatalogLocation,
        workingDirectory: URL,
        homeDirectory: URL,
        includeContainers: Bool
    ) -> [URL] {
        let base = expandedBase(location.basePath, homeDirectory: homeDirectory)
        if location.pattern.contains("{encoded-workdir}") {
            return claudeURLs(
                base: base,
                pattern: location.pattern,
                workingDirectory: workingDirectory,
                includeContainers: includeContainers
            )
        }
        if location.pattern.hasPrefix("*/") {
            return subdirectoryLeafURLs(
                base: base,
                leaf: String(location.pattern.dropFirst(2)),
                includeContainers: includeContainers
            )
        }
        if location.pattern.hasPrefix("*.") {
            let ext = String(location.pattern.dropFirst(2)).lowercased()
            let files = Self.enumeratedFiles(in: base, extensions: [ext])
            return includeContainers ? [base] + files : files
        }
        // Literal file name.
        let file = base.appendingPathComponent(location.pattern)
        return includeContainers ? [base, file] : [file]
    }

    private func claudeURLs(
        base: URL,
        pattern: String,
        workingDirectory: URL,
        includeContainers: Bool
    ) -> [URL] {
        let ext = pattern.split(separator: ".").last.map { String($0).lowercased() } ?? "jsonl"
        let directories = claudeProjectDirectories(root: base, workingDirectory: workingDirectory)
        let files = directories.flatMap { Self.enumeratedFiles(in: $0, extensions: [ext]) }
        if includeContainers {
            return [base] + directories + files
        }
        return files
    }

    /// Resolves the claude project directories for `workingDirectory`, matching
    /// both the new reversible encoding and the legacy lossy encoding, plus any
    /// on-disk directory that decodes (either scheme) to the working dir path.
    func claudeProjectDirectories(root: URL, workingDirectory: URL) -> [URL] {
        var directories: [URL] = []
        let names = [
            ClaudeProjectPathEncoding.encode(workingDirectory.path),
            ClaudeProjectPathEncoding.legacyEncode(workingDirectory.path),
        ]
        for name in names {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            if Self.isDirectory(candidate), !directories.contains(candidate) {
                directories.append(candidate)
            }
        }
        if let children = Self.directoryChildren(of: root) {
            for child in children where !directories.contains(child) {
                let decoded =
                    ClaudeProjectPathEncoding.decode(child.lastPathComponent)
                    ?? ClaudeProjectPathEncoding.legacyDecode(child.lastPathComponent)
                if decoded == workingDirectory.path {
                    directories.append(child)
                }
            }
        }
        return directories
    }

    private func subdirectoryLeafURLs(
        base: URL,
        leaf: String,
        includeContainers: Bool
    ) -> [URL] {
        guard let sessionDirectories = Self.directoryChildren(of: base) else {
            return includeContainers ? [base] : []
        }
        let leaves = sessionDirectories.map { $0.appendingPathComponent(leaf) }
        return includeContainers ? [base] + leaves : leaves
    }

    private func expandedBase(_ basePath: String, homeDirectory: URL) -> URL {
        guard basePath.hasPrefix("~/") else {
            return URL(fileURLWithPath: basePath, isDirectory: true)
        }
        var url = homeDirectory
        for component in basePath.dropFirst(2).split(separator: "/") {
            url = url.appendingPathComponent(String(component), isDirectory: true)
        }
        return url
    }

    // MARK: - FileManager primitives

    static func directoryChildren(of directory: URL) -> [URL]? {
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return nil }
        return children.filter { isDirectory($0) }
    }

    static func enumeratedFiles(in directory: URL, extensions: Set<String>) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }
        return files
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
