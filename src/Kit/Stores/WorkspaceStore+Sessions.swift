import Foundation

extension WorkspaceStore {
    // MARK: - Session-link candidates / manual link

    /// Returns the candidate existing CLI sessions a thread could be linked to, queried
    /// from the binding actor (empty when the thread is unknown).
    public func sessionLinkCandidates(for threadID: UUID) async -> [SessionLinkCandidate] {
        guard let thread = thread(withID: threadID) else { return [] }
        return await environment.sessionBindingActor.sessionLinkCandidates(for: thread)
    }

    /// Links a thread to the chosen existing session candidate, applying its identity
    /// and name (ignored when the candidate's CLI does not match the thread's).
    public func linkSession(threadID: UUID, candidate: SessionLinkCandidate) {
        guard let index = threadIndexByID[threadID],
            threads[index].agentCLI == candidate.agentCLI
        else { return }
        applySessionLink(candidate, toThreadAt: index)
        recordDiagnostic(
            category: "AgentCLI",
            name: "session_linked",
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": candidate.agentCLI.rawValue,
                "source": candidate.source,
            ]
        )
    }

    /// Clears any session identity for an unlinked thread and marks it as having
    /// deliberately skipped linking, so it launches a fresh session instead.
    public func startNewSessionForUnlinkedThread(threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThread(at: index) {
            $0.sessionIdentity = nil
            $0.canonicalSessionName = nil
        }
        sessionLinkRequiredThreadIDs.remove(threadID)
        sessionLinkSkippedThreadIDs.insert(threadID)
        activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
        captureReadOffsetsByThreadID.removeValue(forKey: threadID)
        activity?.invalidatePolling(threadID: threadID)
        persistThread(threads[index])
        recordDiagnostic(
            category: "AgentCLI",
            name: "session_link_skipped",
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": threads[index].agentCLI.rawValue,
            ]
        )
    }

    // MARK: - Auto-link on load

    func reconcileLoadedUnboundSessionLinks(requiresLinks: Bool) async {
        guard requiresLinks else { return }
        let threadIDs = threads.filter { $0.sessionIdentity == nil }.map(\.id)
        for threadID in threadIDs {
            if await autoLinkUnboundThreadIfExactMatch(
                threadID: threadID, diagnosticName: "session_auto_linked_on_load")
            {
                continue
            }
            sessionLinkRequiredThreadIDs.insert(threadID)
        }
    }

    @discardableResult
    func autoLinkUnboundThreadIfExactMatch(threadID: UUID, diagnosticName: String) async -> Bool {
        guard let index = threadIndexByID[threadID], threads[index].sessionIdentity == nil else {
            return false
        }
        guard
            let candidate = await environment.sessionBindingActor.exactSessionLinkCandidate(
                for: threads[index])
        else { return false }
        // Re-resolve the index in case the array mutated during the await.
        guard let resolvedIndex = threadIndexByID[threadID],
            threads[resolvedIndex].sessionIdentity == nil
        else { return false }
        applySessionLink(candidate, toThreadAt: resolvedIndex)
        recordDiagnostic(
            category: "AgentCLI",
            name: diagnosticName,
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": candidate.agentCLI.rawValue,
                "source": candidate.source,
            ]
        )
        return true
    }

    func applySessionLink(
        _ candidate: SessionLinkCandidate,
        toThreadAt index: Int,
        preserveRunningTerminal: Bool = false
    ) {
        let threadID = threads[index].id
        mutateThread(at: index) {
            $0.sessionIdentity = candidate.identity
            $0.canonicalSessionName = candidate.displayName
            $0.displayName = candidate.displayName
            $0.pendingSessionRename = nil
        }
        sessionLinkRequiredThreadIDs.remove(threadID)
        sessionLinkSkippedThreadIDs.remove(threadID)
        let hasRunningTerminal = activeProjectLaunchDescriptorsByThreadID[threadID] != nil
        if !(preserveRunningTerminal && hasRunningTerminal) {
            activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
            captureReadOffsetsByThreadID.removeValue(forKey: threadID)
            activity?.invalidatePolling(threadID: threadID)
        }
        persistThread(threads[index])
    }

    // MARK: - Session sync (replaces the catalog-sync poll)

    /// Synchronously-callable session sync (tests + the bottom of the activity
    /// poll). Reads the catalog/exact-link candidate from the binding actor and
    /// applies it, dropping stale results when the thread re-linked during the
    /// await window (preserving the pre-rewrite generation-guard behavior).
    public func syncSelectedThreadSessionMetadata() async {
        guard let selectedThreadID, let index = threadIndexByID[selectedThreadID] else { return }
        let thread = threads[index]
        if thread.sessionIdentity == nil, !sessionLinkSkippedThreadIDs.contains(selectedThreadID) {
            let candidate = await environment.sessionBindingActor.exactSessionLinkCandidate(
                for: thread)
            applyExactLink(threadID: selectedThreadID, candidate: candidate)
        } else if !sessionLinkRequiredThreadIDs.contains(selectedThreadID),
            thread.sessionIdentity != nil
        {
            let metadata = await environment.sessionBindingActor.catalogMetadata(for: thread)
            applyCatalogMetadata(threadID: selectedThreadID, metadata: metadata)
        }
    }

    private func applyExactLink(threadID: UUID, candidate: SessionLinkCandidate?) {
        guard selectedThreadID == threadID,
            let index = threadIndexByID[threadID],
            threads[index].sessionIdentity == nil,
            !sessionLinkSkippedThreadIDs.contains(threadID),
            let candidate
        else { return }
        applySessionLink(candidate, toThreadAt: index, preserveRunningTerminal: true)
        recordDiagnostic(
            category: "AgentCLI",
            name: "session_auto_linked_during_sync",
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": candidate.agentCLI.rawValue,
                "source": candidate.source,
            ]
        )
    }

    private func applyCatalogMetadata(threadID: UUID, metadata: AgentCLISessionMetadata?) {
        guard selectedThreadID == threadID,
            !sessionLinkRequiredThreadIDs.contains(threadID),
            let index = threadIndexByID[threadID],
            let metadata,
            threads[index].sessionIdentity == metadata.identity
        else { return }
        applyAgentCLIMetadata(metadata, toThreadAt: index)
    }

    /// Applies scraped/catalog session metadata to a thread, honoring the
    /// pending-rename gate, the authoritative-name rule, and the title-as-name
    /// policy. Re-homed from the pre-rewrite `AppModel.applyAgentCLIMetadata`;
    /// `usesTitleAsName` is supplied by the caller (resolved from the manifest).
    func applyAgentCLIMetadata(
        _ metadata: AgentCLISessionMetadata,
        toThreadAt index: Int,
        usesTitleAsName: Bool? = nil,
        pendingTerminalTitle: String? = nil
    ) {
        let threadID = threads[index].id
        let pendingRename = threads[index].pendingSessionRename
        let canonicalName = metadata.canonicalName
        let isPendingRenameConfirmed = pendingRename.map { $0 == canonicalName } ?? true
        let nameIsAuthoritative = metadata.reportedName != nil
        let established = threads[index].canonicalSessionName
        let hasEstablishedName = established != nil && established != metadata.identity
        let canApplyTitleName = usesTitleAsName ?? titleUsageByKind[threads[index].agentCLI] ?? true
        let mayApplyName =
            nameIsAuthoritative ? true : (hasEstablishedName ? false : canApplyTitleName)
        var updatedThread = threads[index]
        updatedThread.sessionIdentity = metadata.identity
        if isPendingRenameConfirmed && mayApplyName {
            updatedThread.canonicalSessionName = canonicalName
            updatedThread.displayName = canonicalName
            updatedThread.pendingSessionRename = nil
        }
        let threadChanged = updatedThread != threads[index]
        let linkStateChanged =
            sessionLinkRequiredThreadIDs.contains(threadID)
            || sessionLinkSkippedThreadIDs.contains(threadID)
            || pendingTerminalTitle != nil
        guard threadChanged || linkStateChanged else { return }
        if threadChanged { mutateThread(at: index) { $0 = updatedThread } }
        sessionLinkRequiredThreadIDs.remove(threadID)
        sessionLinkSkippedThreadIDs.remove(threadID)
        if threadChanged { persistThread(threads[index]) }
    }
}
