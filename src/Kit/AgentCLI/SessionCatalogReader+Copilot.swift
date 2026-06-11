import Foundation

extension SessionCatalogReader {
    /// Builds copilot candidates from `*/leaf` URLs by grouping on the parent
    /// session directory and merging the per-session `vscode.metadata.json` and
    /// `events.jsonl` (events override metadata, matching the legacy reader).
    func copilotCandidates(
        metadataOrEventURLs urls: [URL],
        location: CatalogLocation,
        workingDirectory: URL
    ) -> [SessionLinkCandidate] {
        let sessionDirectories = orderedUniqueParents(of: urls)
        return sessionDirectories.compactMap { sessionDirectory in
            copilotCandidate(from: sessionDirectory, workingDirectory: workingDirectory)
        }
    }

    private func orderedUniqueParents(of urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var parents: [URL] = []
        for url in urls {
            let parent = url.deletingLastPathComponent()
            if seen.insert(parent.standardizedFileURL.path).inserted {
                parents.append(parent)
            }
        }
        return parents
    }

    private func copilotCandidate(
        from sessionDirectory: URL,
        workingDirectory: URL
    ) -> SessionLinkCandidate? {
        let metadataURL = sessionDirectory.appendingPathComponent("vscode.metadata.json")
        let metadataObject = CatalogJSON.object(from: metadataURL)
        var identity =
            metadataObject.flatMap {
                CatalogJSON.firstString(in: $0, keys: manifest.sessionIdentityKeys)
            } ?? sessionDirectory.lastPathComponent.agentCLINilIfBlank
        var name = metadataObject.flatMap {
            CatalogJSON.firstString(in: $0, keys: manifest.displayNameKeys)
        }
        var directory = metadataObject.flatMap {
            CatalogJSON.firstURL(in: $0, keys: manifest.workingDirectoryKeys)
        }
        var updatedAt =
            metadataObject.flatMap {
                CatalogJSON.firstDate(in: $0, keys: manifest.timestampKeys)
            } ?? CatalogJSON.modificationDate(for: metadataURL)

        let eventsURL = sessionDirectory.appendingPathComponent("events.jsonl")
        for object in CatalogJSON.objects(fromJSONL: eventsURL) {
            identity =
                CatalogJSON.firstString(in: object, keys: manifest.sessionIdentityKeys) ?? identity
            directory =
                CatalogJSON.firstURL(in: object, keys: manifest.workingDirectoryKeys) ?? directory
            name = CatalogJSON.firstString(in: object, keys: manifest.displayNameKeys) ?? name
            updatedAt =
                CatalogJSON.firstDate(in: object, keys: manifest.timestampKeys) ?? updatedAt
        }

        guard let identity else { return nil }
        guard copilotMatches(workingDirectory: workingDirectory, candidateDirectory: directory)
        else { return nil }
        return SessionLinkCandidate(
            identity: identity,
            displayName: name ?? identity,
            agentCLI: manifest.kind,
            workingDirectory: directory,
            updatedAt: updatedAt,
            source: "~/.copilot/session-state"
        )
    }

    private func copilotMatches(workingDirectory: URL, candidateDirectory: URL?) -> Bool {
        guard let candidateDirectory else { return !manifest.directoryMatchingStrict }
        return candidateDirectory.standardizedFileURL.path
            == workingDirectory.standardizedFileURL.path
    }
}

/// Accumulates the display name from a claude-style catalog using
/// ``CatalogMetadataRules``: each line's top-level type key selects a candidate
/// field; the highest-precedence match wins, read only from the line's top level
/// (never recursively, so embedded tool-use `name`s are ignored).
struct TypeDependentNameExtractor {
    private let rules: CatalogMetadataRules?
    private var bestPrecedence = Int.max
    private var bestName: String?

    init(rules: CatalogMetadataRules?) {
        self.rules = rules
    }

    mutating func ingest(object: Any) {
        guard let rules,
            let type = CatalogJSON.topLevelString(in: object, key: rules.typeKey)
        else { return }
        for rule in rules.typeDependentFields where rule.whenType == type {
            guard rule.precedence <= bestPrecedence else { continue }
            if let value = CatalogJSON.topLevelString(in: object, key: rule.field) {
                // A higher-precedence (lower number) rule always overrides; equal
                // precedence keeps the first non-nil (custom title wins on ties).
                if rule.precedence < bestPrecedence || bestName == nil {
                    bestPrecedence = rule.precedence
                    bestName = value
                }
            }
        }
    }

    var resolvedName: String? { bestName }
}
