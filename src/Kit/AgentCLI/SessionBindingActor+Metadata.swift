import Foundation

extension SessionBindingActor {
    /// Parses session metadata from live CLI `output`, optionally seeding the
    /// title from the terminal title. Returns `nil` when no identity is present.
    public func metadata(
        for kind: AgentCLIKind,
        output: String,
        terminalTitle: String? = nil
    ) -> AgentCLISessionMetadata? {
        guard let manifest = manifestsByKind[kind] else { return nil }
        return AgentCLIOutputMetadataParser(manifest: manifest)
            .metadata(from: output, terminalTitle: terminalTitle)
    }

    /// Builds metadata from an already-known identity plus a terminal title.
    public func metadata(
        fromExistingIdentity identity: String,
        terminalTitle: String
    ) -> AgentCLISessionMetadata {
        AgentCLISessionMetadata(identity: identity, title: terminalTitle)
    }

    /// The catalog metadata for a thread's stored session, if found; `nil` when
    /// the thread has no identity or no matching candidate exists. Prefer
    /// ``catalogMetadataResult(for:)`` to distinguish absence from drift.
    public func catalogMetadata(for thread: AgentThread) -> AgentCLISessionMetadata? {
        guard case .found(let metadata) = catalogMetadataResult(for: thread) else { return nil }
        return metadata
    }

    /// The catalog metadata outcome for a thread, distinguishing a clean match
    /// (`.found`) from a present-but-unparseable record (`.driftDetected`) and a
    /// genuine miss (`.absent`). Drift is also recorded as a diagnostic so the
    /// failure is loud; Chunk E surfaces `.driftDetected` as a thread state.
    public func catalogMetadataResult(for thread: AgentThread) -> CatalogMetadataResult {
        guard let sessionIdentity = thread.sessionIdentity else { return .absent }
        guard let manifest = manifestsByKind[thread.agentCLI] else { return .absent }
        if let match = sessionLinkCandidates(for: thread)
            .first(where: { $0.identity == sessionIdentity })
        {
            return .found(AgentCLISessionMetadata(from: match))
        }

        let reader = SessionCatalogReader(manifest: manifest)
        let probe = reader.driftProbe(
            identity: sessionIdentity,
            workingDirectory: thread.workingDirectory,
            homeDirectory: homeDirectory
        )
        switch probe {
        case .absent:
            return .absent
        case .referencesIdentity, .unparseableRecords:
            let reason = Self.driftReason(probe: probe, identity: sessionIdentity)
            recordDrift(thread: thread, identity: sessionIdentity, reason: reason)
            return .driftDetected(reason: reason)
        }
    }

    private static func driftReason(
        probe: SessionCatalogReader.DriftProbe,
        identity: String
    ) -> String {
        switch probe {
        case .referencesIdentity:
            return "Unable to parse session metadata for \(identity) (catalog format changed)"
        case .unparseableRecords:
            return
                "Unable to parse session metadata for \(identity) "
                + "(session identity field changed)"
        case .absent:
            return "Unable to parse session metadata for \(identity)"
        }
    }

    private func recordDrift(thread: AgentThread, identity: String, reason: String) {
        diagnosticRecorder.record(
            DiagnosticEvent(
                category: "AgentCLI",
                name: "session_catalog_drift",
                metadata: [
                    "agent_cli": thread.agentCLI.rawValue,
                    "session_identity": identity,
                    "thread_id": thread.id.uuidString,
                    "reason": reason,
                ]
            )
        )
    }

    // MARK: - Captured output / activity events

    /// Reads capture-log bytes appended after `offset`, recovering from rotation
    /// (offset beyond file → 0) and clamping a stale window to the last
    /// ``captureLogStaleWindow`` bytes.
    public func capturedOutput(
        for thread: AgentThread,
        after offset: UInt64,
        maxBytes: Int = 64 * 1024
    ) -> AgentCLICapturedOutput? {
        guard let url = captureLogURL(for: thread) else { return nil }
        return Self.capturedOutput(from: url, after: offset, maxBytes: maxBytes)
    }

    /// Reads activity-log (NDJSON) bytes appended after `offset`, with the same
    /// rotation/stale-window handling as ``capturedOutput(for:after:maxBytes:)``.
    public func capturedActivityEvents(
        for thread: AgentThread,
        after offset: UInt64,
        maxBytes: Int = 64 * 1024
    ) -> AgentCLICapturedOutput? {
        guard let url = activityLogURL(for: thread) else { return nil }
        return Self.capturedOutput(from: url, after: offset, maxBytes: maxBytes)
    }

    static func capturedOutput(
        from url: URL,
        after offset: UInt64,
        maxBytes: Int
    ) -> AgentCLICapturedOutput? {
        guard maxBytes > 0 else { return nil }
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }
        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        guard fileSize > 0 else { return nil }

        let requestedOffset = offset > fileSize ? 0 : offset
        guard fileSize > requestedOffset else { return nil }
        let effectiveOffset: UInt64
        if fileSize - requestedOffset > captureLogStaleWindow {
            let maxReadBytes = UInt64(maxBytes)
            effectiveOffset = fileSize > maxReadBytes ? fileSize - maxReadBytes : 0
        } else {
            effectiveOffset = requestedOffset
        }

        try? fileHandle.seek(toOffset: effectiveOffset)
        guard let data = try? fileHandle.read(upToCount: maxBytes), !data.isEmpty else {
            return nil
        }
        return AgentCLICapturedOutput(
            output: String(decoding: data, as: UTF8.self),
            nextOffset: effectiveOffset + UInt64(data.count),
            startOffset: effectiveOffset
        )
    }

    // MARK: - Capture by running the CLI

    /// Runs the CLI (optionally resuming `resumeIdentity`) and parses the session
    /// metadata from its output. Throws when the executable is missing, launch
    /// fails, or no metadata can be parsed.
    public func captureMetadataByRunningCLI(
        kind: AgentCLIKind,
        resumeIdentity: String? = nil,
        workingDirectory: URL,
        environment overrideEnvironment: [String: String]? = nil
    ) throws -> AgentCLISessionMetadata {
        guard let manifest = manifestsByKind[kind] else {
            throw AgentCLISessionBindingError.missingManifest(kind)
        }
        let processEnvironment = overrideEnvironment ?? environment
        guard
            let executablePath = resolver.executablePath(
                named: manifest.executableName, environment: processEnvironment)
        else {
            throw AgentCLISessionBindingError.missingExecutable(manifest.executableName)
        }

        let arguments = manifest.invocationArguments(
            sessionIdentity: resumeIdentity, requestedName: nil)
        let output = try Self.runCapturing(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: processEnvironment
        )
        guard
            let metadata = AgentCLIOutputMetadataParser(manifest: manifest)
                .metadata(from: output, terminalTitle: nil)
        else {
            throw AgentCLISessionBindingError.metadataNotFound(output)
        }
        return metadata
    }

    private static func runCapturing(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AgentCLISessionBindingError.launchFailed(String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
