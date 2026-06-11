import Foundation

extension ActivityStore {
    // MARK: - Terminal lifecycle recorders

    /// Applies inferred activity from raw terminal output and extracts any session
    /// metadata. Async because metadata parsing goes through the binding actor.
    public func recordAgentCLIOutput(threadID: UUID, output: String, terminalTitle: String? = nil)
        async
    {
        guard let index = workspace.threadIndexByID[threadID] else { return }
        applyInferredTerminalOutputActivity(threadID: threadID, output: output)
        let kind = workspace.threads[index].agentCLI
        guard
            var metadata = await environment.sessionBindingActor.metadata(
                for: kind, output: output, terminalTitle: terminalTitle)
        else { return }
        if metadata.reportedName == nil, metadata.title == nil,
            let pendingTitle = pendingTerminalTitlesByThreadID[threadID]
        {
            metadata.title = pendingTitle
        }
        guard let resolvedIndex = workspace.threadIndexByID[threadID] else { return }
        workspace.applyAgentCLIMetadata(
            metadata,
            toThreadAt: resolvedIndex,
            usesTitleAsName: WorkspaceStore.titleUsageByKind[kind] ?? true,
            pendingTerminalTitle: pendingTerminalTitlesByThreadID[threadID]
        )
        pendingTerminalTitlesByThreadID.removeValue(forKey: threadID)
    }

    /// Records a terminal title. For CLIs whose title is transient tool activity
    /// (Claude shows "Bash"/"Read"), surfaces it as the activity subtitle and keeps
    /// the thread name stable; for title-as-name CLIs, applies it as metadata.
    public func recordAgentCLITerminalTitle(threadID: UUID, title: String) async {
        guard let index = workspace.threadIndexByID[threadID] else { return }
        pendingTerminalTitlesByThreadID[threadID] = title
        let kind = workspace.threads[index].agentCLI
        let usesTitleAsName = await environment.sessionBindingActor.usesTerminalTitleAsSessionName(
            for: kind)
        guard let resolvedIndex = workspace.threadIndexByID[threadID] else { return }
        if !usesTitleAsName {
            let normalizedTitle = ThreadActivityText.sanitized(title)
            let isRedundant =
                normalizedTitle == workspace.threads[resolvedIndex].displayName
                || normalizedTitle == workspace.threads[resolvedIndex].canonicalSessionName
            applyThreadActivity(
                ThreadActivityEvent(
                    threadID: threadID,
                    status: nil,
                    title: isRedundant ? nil : title,
                    body: nil,
                    source: .terminalLifecycle
                ),
                isUnread: false,
                shouldNotify: false
            )
            return
        }
        guard let identity = workspace.threads[resolvedIndex].sessionIdentity,
            workspace.threads[resolvedIndex].canonicalSessionName == nil
                || workspace.threads[resolvedIndex].canonicalSessionName == identity
        else { return }
        let metadata = await environment.sessionBindingActor.metadata(
            fromExistingIdentity: identity, terminalTitle: title)
        guard let applyIndex = workspace.threadIndexByID[threadID] else { return }
        workspace.applyAgentCLIMetadata(
            metadata,
            toThreadAt: applyIndex,
            usesTitleAsName: usesTitleAsName,
            pendingTerminalTitle: pendingTerminalTitlesByThreadID[threadID]
        )
        pendingTerminalTitlesByThreadID.removeValue(forKey: threadID)
    }

    public func recordAgentTerminalFocus(threadID: UUID, focused: Bool) {
        if focused {
            focusedProjectTerminalThreadID = threadID
            markThreadActivityRead(threadID: threadID)
        } else if focusedProjectTerminalThreadID == threadID {
            focusedProjectTerminalThreadID = nil
        }
    }

    public func recordAgentTerminalNotification(threadID: UUID, title: String, body: String) {
        let status = ThreadActivityText.inferredStatus(title: title, body: body)
        applyThreadActivity(
            ThreadActivityEvent(
                threadID: threadID, status: status, title: title, body: body,
                source: .terminalNotification),
            isUnread: true,
            shouldNotify: true
        )
    }

    public func recordAgentTerminalClosed(threadID: UUID) {
        activityReadOffsetsByThreadID.removeValue(forKey: threadID)
        activityPartialLinesByThreadID.removeValue(forKey: threadID)
        invalidatePolling(threadID: threadID)
        applyThreadActivity(
            ThreadActivityEvent(
                threadID: threadID, status: .inactive, title: "Terminal closed", body: nil,
                source: .terminalLifecycle),
            isUnread: false,
            shouldNotify: false
        )
        if focusedProjectTerminalThreadID == threadID { focusedProjectTerminalThreadID = nil }
    }

    public func recordAgentCommandFinished(threadID: UUID, exitCode: Int?) {
        let body = exitCode.map { "Command exited with status \($0)" } ?? "Command finished"
        applyThreadActivity(
            ThreadActivityEvent(
                threadID: threadID, status: .complete, title: "Command finished", body: body,
                source: .terminalLifecycle),
            isUnread: false,
            shouldNotify: false
        )
    }

    private func applyInferredTerminalOutputActivity(threadID: UUID, output: String) {
        guard let status = ThreadActivityText.inferredStatus(fromTerminalOutput: output) else {
            return
        }
        applyThreadActivity(
            ThreadActivityEvent(
                threadID: threadID, status: status, title: nil, body: nil,
                source: .terminalLifecycle),
            isUnread: false,
            shouldNotify: false
        )
    }

    /// Cancels (and clears) any in-flight polling/index work for a thread —
    /// replacing the pre-rewrite generation-counter bump on close/link/relaunch.
    func invalidatePolling(threadID: UUID) {
        fileIndexTasksByThreadID[threadID]?.cancel()
        fileIndexTasksByThreadID.removeValue(forKey: threadID)
    }
}
