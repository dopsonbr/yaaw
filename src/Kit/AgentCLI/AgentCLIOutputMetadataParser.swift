import Foundation

/// Manifest-driven parser that scrapes session metadata from a CLI's terminal
/// output using the manifest's ``OutputMetadataPattern`` line prefixes.
struct AgentCLIOutputMetadataParser: Sendable {
    let manifest: CLIManifest

    /// Parses metadata from `output`, seeding the title with `terminalTitle`.
    /// Returns `nil` if no session identity could be found (identity is required).
    func metadata(from output: String, terminalTitle: String?) -> AgentCLISessionMetadata? {
        var identity: String?
        var reportedName: String?
        var title = terminalTitle?.agentCLINilIfBlank

        let identityPrefixes = prefixes(for: .sessionIdentity)
        let namePrefixes = prefixes(for: .displayName)
        let titlePrefixes = prefixes(for: .title)

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).removingTerminalControls
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = line.lowercased()
            identity =
                identity ?? Self.value(in: line, lowercased: lowercased, prefixes: identityPrefixes)
            reportedName =
                reportedName
                ?? Self.value(in: line, lowercased: lowercased, prefixes: namePrefixes)
            title = title ?? Self.value(in: line, lowercased: lowercased, prefixes: titlePrefixes)
        }

        guard let identity = identity?.agentCLINilIfBlank else { return nil }
        return AgentCLISessionMetadata(
            identity: identity,
            reportedName: reportedName,
            title: title
        )
    }

    private func prefixes(for field: OutputMetadataField) -> [String] {
        manifest.outputMetadataPatterns
            .filter { $0.field == field }
            .flatMap(\.prefixes)
            .map { $0.lowercased() }
    }

    private static func value(
        in line: String,
        lowercased: String,
        prefixes: [String]
    ) -> String? {
        for prefix in prefixes where lowercased.hasPrefix(prefix) {
            let index = line.index(line.startIndex, offsetBy: prefix.count)
            return String(line[index...]).cleanedSessionField.agentCLINilIfBlank
        }
        return nil
    }
}

extension String {
    /// The value with a single layer of matching surrounding quotes removed.
    fileprivate var cleanedSessionField: String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    /// The string with control characters (e.g. stray terminal escapes) removed.
    fileprivate var removingTerminalControls: String {
        String(
            unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            })
    }
}
