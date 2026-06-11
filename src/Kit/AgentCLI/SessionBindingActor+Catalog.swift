import Foundation

extension SessionBindingActor {
    /// The ranked session-link candidates for a thread, read from the CLI's
    /// catalog (directory matches first, then recency, then name). Results are
    /// cached per `(family, working directory)` and reused while the catalog's
    /// signature is unchanged.
    public func sessionLinkCandidates(for thread: AgentThread) -> [SessionLinkCandidate] {
        guard let manifest = manifestsByKind[thread.agentCLI] else { return [] }
        let reader = SessionCatalogReader(manifest: manifest)
        let key = SessionCatalogCacheKey(
            kind: thread.agentCLI,
            workingDirectoryPath: thread.workingDirectory.standardizedFileURL.path
        )
        let signature = reader.signature(
            workingDirectory: thread.workingDirectory,
            homeDirectory: homeDirectory
        )
        if let cached = catalogCacheByKey[key], cached.signature == signature {
            return cached.candidates
        }

        let candidates = reader.candidates(
            workingDirectory: thread.workingDirectory,
            homeDirectory: homeDirectory
        )
        let sorted = Self.sortedSessionLinkCandidates(
            candidates,
            workingDirectory: thread.workingDirectory
        )
        store(
            entry: SessionCatalogCacheEntry(signature: signature, candidates: sorted), forKey: key)
        return sorted
    }

    private func store(entry: SessionCatalogCacheEntry, forKey key: SessionCatalogCacheKey) {
        if catalogCacheByKey[key] == nil {
            catalogCacheInsertionOrder.append(key)
            if catalogCacheInsertionOrder.count > Self.catalogCacheLimit {
                let evicted = catalogCacheInsertionOrder.removeFirst()
                catalogCacheByKey.removeValue(forKey: evicted)
            }
        }
        catalogCacheByKey[key] = entry
    }

    /// The single unambiguous candidate a fresh thread can auto-link to, matched
    /// by normalized display name *and* working directory. Returns `nil` when the
    /// thread already has an identity, no name matches, or the match is ambiguous.
    public func exactSessionLinkCandidate(for thread: AgentThread) -> SessionLinkCandidate? {
        guard thread.sessionIdentity == nil else { return nil }
        let matchNames = Self.sessionLinkMatchNames(for: thread)
        guard !matchNames.isEmpty else { return nil }
        let matchingCandidates = sessionLinkCandidates(for: thread).filter { candidate in
            guard let candidateName = Self.normalizedSessionLinkName(candidate.displayName) else {
                return false
            }
            return matchNames.contains(candidateName)
        }
        guard !matchingCandidates.isEmpty else { return nil }

        let directoryMatches = matchingCandidates.filter { candidate in
            guard let directory = candidate.workingDirectory else { return false }
            return Self.sameDirectory(directory, thread.workingDirectory)
        }
        guard !directoryMatches.isEmpty else { return nil }
        let identities = Set(directoryMatches.map(\.id))
        guard identities.count == 1 else { return nil }
        return directoryMatches.first
    }

    // MARK: - Ranking & name normalization

    static func sortedSessionLinkCandidates(
        _ candidates: [SessionLinkCandidate],
        workingDirectory: URL
    ) -> [SessionLinkCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsMatches =
                lhs.workingDirectory.map { sameDirectory($0, workingDirectory) } ?? false
            let rhsMatches =
                rhs.workingDirectory.map { sameDirectory($0, workingDirectory) } ?? false
            if lhsMatches != rhsMatches {
                return lhsMatches
            }
            return SessionCatalogReader.recencyThenName(lhs, rhs)
        }
    }

    static func sessionLinkMatchNames(for thread: AgentThread) -> Set<String> {
        let names = [
            thread.pendingSessionRename,
            thread.canonicalSessionName,
            thread.displayName,
        ].compactMap { $0 }
        return Set(names.compactMap(normalizedSessionLinkName))
    }

    static func normalizedSessionLinkName(_ name: String?) -> String? {
        let collapsed =
            name?
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed?.agentCLINilIfBlank
    }

    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
