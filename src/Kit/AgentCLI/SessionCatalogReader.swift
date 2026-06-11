import Foundation

/// Manifest-driven reader that scans a CLI's on-disk catalog and produces the
/// session-link candidates for a working directory.
///
/// The reader is a pure value: it interprets a ``CLIManifest`` and reads files,
/// holding no mutable state, so it is trivially `Sendable` and the actor can
/// call it freely. File-layout differences between families are expressed by the
/// shape of each ``CatalogLocation`` pattern.
struct SessionCatalogReader: Sendable {
    let manifest: CLIManifest

    /// All candidate sessions whose recorded directory matches `workingDirectory`
    /// (subject to the manifest's strict-matching policy), merged by identity.
    func candidates(workingDirectory: URL, homeDirectory: URL) -> [SessionLinkCandidate] {
        var collected: [SessionLinkCandidate] = []
        var seenIdentities = Set<String>()
        for location in manifest.catalogLocations {
            let found = candidates(
                in: location,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                excludingIdentities: seenIdentities
            )
            for candidate in found {
                seenIdentities.insert(candidate.identity)
            }
            collected.append(contentsOf: found)
        }
        return Self.merged(collected)
    }

    /// A signature fingerprinting all catalog files for change detection.
    func signature(workingDirectory: URL, homeDirectory: URL) -> String {
        let parts = manifest.catalogLocations.flatMap { location -> [String] in
            let urls = matchedURLs(
                for: location,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                includeContainers: true
            )
            return urls.map(CatalogSignature.fileSignature(for:))
        }
        return CatalogSignature.combined(parts)
    }

    // MARK: - Per-location candidate extraction

    private func candidates(
        in location: CatalogLocation,
        workingDirectory: URL,
        homeDirectory: URL,
        excludingIdentities: Set<String>
    ) -> [SessionLinkCandidate] {
        let urls = matchedURLs(
            for: location,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory,
            includeContainers: false
        )
        // Copilot: one session per *directory* (metadata + events merged).
        if location.pattern.hasPrefix("*/") {
            return copilotCandidates(
                metadataOrEventURLs: urls,
                location: location,
                workingDirectory: workingDirectory
            )
        }
        switch location.fileFormat {
        case .jsonl:
            return urls.flatMap { url in
                jsonlCandidates(
                    url: url,
                    location: location,
                    workingDirectory: workingDirectory,
                    excludingIdentities: excludingIdentities
                )
            }
        case .json:
            return urls.compactMap { url in
                jsonFileCandidate(url: url, workingDirectory: workingDirectory)
            }
        }
    }

    /// JSONL where the title may be type-dependent (claude) or the whole file is
    /// a flat session index/history (codex).
    private func jsonlCandidates(
        url: URL,
        location: CatalogLocation,
        workingDirectory: URL,
        excludingIdentities: Set<String>
    ) -> [SessionLinkCandidate] {
        if manifest.catalogMetadataRules != nil {
            return aggregatedFileCandidate(url: url, workingDirectory: workingDirectory).map {
                [$0]
            }
                ?? []
        }
        let source = sourceLabel(for: location)
        return CatalogJSON.objects(fromJSONL: url).compactMap { object in
            perLineCandidate(
                object: object,
                workingDirectory: workingDirectory,
                source: source,
                excludingIdentities: excludingIdentities
            )
        }
    }

    /// One candidate per JSONL line (codex index / history).
    private func perLineCandidate(
        object: Any,
        workingDirectory: URL,
        source: String,
        excludingIdentities: Set<String>
    ) -> SessionLinkCandidate? {
        guard
            let identity = CatalogJSON.firstString(in: object, keys: manifest.sessionIdentityKeys),
            !excludingIdentities.contains(identity)
        else { return nil }
        let directory = CatalogJSON.firstURL(in: object, keys: manifest.workingDirectoryKeys)
        guard matches(workingDirectory: workingDirectory, candidateDirectory: directory) else {
            return nil
        }
        let name = CatalogJSON.firstString(in: object, keys: manifest.displayNameKeys) ?? identity
        return SessionLinkCandidate(
            identity: identity,
            displayName: name,
            agentCLI: manifest.kind,
            workingDirectory: directory,
            updatedAt: CatalogJSON.firstDate(in: object, keys: manifest.timestampKeys),
            source: source
        )
    }

    /// A single candidate aggregated across all lines of a claude session file,
    /// honoring the type-dependent name precedence and ignoring nested keys.
    private func aggregatedFileCandidate(
        url: URL,
        workingDirectory: URL
    ) -> SessionLinkCandidate? {
        var identity = url.deletingPathExtension().lastPathComponent.agentCLINilIfBlank
        var directory: URL? = workingDirectory
        var updatedAt = CatalogJSON.modificationDate(for: url)
        var nameExtractor = TypeDependentNameExtractor(rules: manifest.catalogMetadataRules)
        for object in CatalogJSON.objects(fromJSONL: url) {
            identity =
                CatalogJSON.firstString(in: object, keys: manifest.sessionIdentityKeys) ?? identity
            nameExtractor.ingest(object: object)
            directory =
                CatalogJSON.firstURL(in: object, keys: manifest.workingDirectoryKeys) ?? directory
            updatedAt =
                CatalogJSON.firstDate(in: object, keys: manifest.timestampKeys) ?? updatedAt
        }
        guard let identity else { return nil }
        guard matches(workingDirectory: workingDirectory, candidateDirectory: directory) else {
            return nil
        }
        return SessionLinkCandidate(
            identity: identity,
            displayName: nameExtractor.resolvedName ?? identity,
            agentCLI: manifest.kind,
            workingDirectory: directory,
            updatedAt: updatedAt,
            source: manifest.catalogLocations.first.map { "~/" + relativeBase($0.basePath) } ?? ""
        )
    }

    /// A single-JSON-document candidate (opencode).
    private func jsonFileCandidate(
        url: URL,
        workingDirectory: URL
    ) -> SessionLinkCandidate? {
        guard let object = CatalogJSON.object(from: url) else { return nil }
        let directory = CatalogJSON.firstURL(in: object, keys: manifest.workingDirectoryKeys)
        guard matches(workingDirectory: workingDirectory, candidateDirectory: directory) else {
            return nil
        }
        guard
            let identity = CatalogJSON.firstString(in: object, keys: manifest.sessionIdentityKeys)
                ?? url.deletingPathExtension().lastPathComponent.agentCLINilIfBlank
        else { return nil }
        let name = CatalogJSON.firstString(in: object, keys: manifest.displayNameKeys) ?? identity
        return SessionLinkCandidate(
            identity: identity,
            displayName: name,
            agentCLI: manifest.kind,
            workingDirectory: directory,
            updatedAt: CatalogJSON.firstDate(in: object, keys: manifest.timestampKeys)
                ?? CatalogJSON.modificationDate(for: url),
            source: sourceLabel(for: manifest.catalogLocations.first)
        )
    }

    private func matches(workingDirectory: URL, candidateDirectory: URL?) -> Bool {
        guard let candidateDirectory else { return !manifest.directoryMatchingStrict }
        return candidateDirectory.standardizedFileURL.path
            == workingDirectory.standardizedFileURL.path
    }

    // MARK: - Merge

    static func merged(_ candidates: [SessionLinkCandidate]) -> [SessionLinkCandidate] {
        var byIdentity: [String: SessionLinkCandidate] = [:]
        for candidate in candidates {
            guard !candidate.identity.isEmpty else { continue }
            guard let existing = byIdentity[candidate.identity] else {
                byIdentity[candidate.identity] = candidate
                continue
            }
            let candidateIsNewer =
                (candidate.updatedAt ?? .distantPast) > (existing.updatedAt ?? .distantPast)
            let existingUsesIdentity = existing.displayName == existing.identity
            if candidateIsNewer || existingUsesIdentity {
                byIdentity[candidate.identity] = candidate
            }
        }
        return byIdentity.values.sorted(by: Self.recencyThenName)
    }

    static func recencyThenName(_ lhs: SessionLinkCandidate, _ rhs: SessionLinkCandidate) -> Bool {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case (let lhsDate?, let rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - Source labels

    private func sourceLabel(for location: CatalogLocation?) -> String {
        guard let location else { return "" }
        let base = relativeBase(location.basePath)
        let file = location.pattern
        if file.contains("*") || file.contains("{") {
            return "~/\(base)"
        }
        return "~/\(base)/\(file)"
    }

    private func relativeBase(_ basePath: String) -> String {
        basePath.hasPrefix("~/") ? String(basePath.dropFirst(2)) : basePath
    }
}
