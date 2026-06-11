import Foundation

extension SessionCatalogReader {
    /// Outcome of probing the catalog for evidence of a session record that the
    /// normal parse could not turn into a candidate.
    enum DriftProbe: Equatable {
        /// The catalog plainly references the requested identity yet no candidate
        /// was produced for it — the format under that record drifted.
        case referencesIdentity
        /// The catalog has session-shaped records but none yields a parseable
        /// identity at all — the identity field itself drifted.
        case unparseableRecords
        /// No evidence of a record for the identity (genuinely absent).
        case absent
    }

    /// Probes whether the catalog appears to contain the requested `identity`
    /// even though parsing produced no matching candidate. Used to turn a silent
    /// `nil` into a loud `driftDetected` signal.
    func driftProbe(
        identity: String,
        workingDirectory: URL,
        homeDirectory: URL
    ) -> DriftProbe {
        var sawAnyRecord = false
        var sawAnyParseableIdentity = false
        for location in manifest.catalogLocations {
            let urls = matchedURLs(
                for: location,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory,
                includeContainers: false
            )
            for url in urls {
                let objects = decodedObjects(at: url, format: location.fileFormat)
                for object in objects {
                    sawAnyRecord = true
                    if let parsed = CatalogJSON.firstString(
                        in: object, keys: manifest.sessionIdentityKeys)
                    {
                        sawAnyParseableIdentity = true
                        if parsed == identity { return .absent }
                    }
                }
                if rawText(at: url)?.contains(identity) == true {
                    return .referencesIdentity
                }
            }
        }
        if sawAnyRecord, !sawAnyParseableIdentity {
            return .unparseableRecords
        }
        return .absent
    }

    private func decodedObjects(at url: URL, format: CatalogFileFormat) -> [Any] {
        switch format {
        case .jsonl:
            return CatalogJSON.objects(fromJSONL: url)
        case .json:
            return CatalogJSON.object(from: url).map { [$0] } ?? []
        }
    }

    private func rawText(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
