import Foundation

extension ActivityStore {
    // MARK: - Capture / activity polling

    /// Reads the selected thread's capture log after the stored offset and applies
    /// the scraped session metadata + inferred activity. Async (the binding actor
    /// owns the read); a thread reselect/close cancels the owning Task.
    public func pollSelectedAgentCLICaptureLog() async {
        guard let thread = workspace.selectedThread else { return }
        let offset = workspace.captureReadOffsetForThread(thread.id)
        guard
            let captured = await environment.sessionBindingActor.capturedOutput(
                for: thread, after: offset)
        else { return }
        await applyAgentCLICaptureResult(threadID: thread.id, captured: captured)
    }

    /// Reads the activity (NDJSON) logs for every polled thread and applies the
    /// parsed events.
    public func pollAgentCLIActivityLogs() async {
        for threadID in threadIDsForAgentCLIActivityPolling() {
            guard let thread = workspace.activeThread(id: threadID) else { continue }
            let offset = activityReadOffsetsByThreadID[thread.id] ?? 0
            guard
                let captured = await environment.sessionBindingActor.capturedActivityEvents(
                    for: thread, after: offset)
            else { continue }
            applyAgentCLIActivityResult(threadID: thread.id, captured: captured)
        }
    }

    /// Background poll: capture + activity logs, then session-catalog sync. Mirrors
    /// the pre-rewrite `pollAgentCLIStateInBackground`, but coalescing is provided
    /// by structured concurrency rather than in-flight booleans + generations.
    public func pollAgentCLIStateInBackground() async {
        await pollSelectedAgentCLICaptureLog()
        await pollAgentCLIActivityLogs()
        await workspace.syncSelectedThreadSessionMetadata()
    }

    private func applyAgentCLICaptureResult(threadID: UUID, captured: AgentCLICapturedOutput) async
    {
        workspace.setCaptureReadOffset(captured.nextOffset, forThread: threadID)
        await recordAgentCLIOutput(threadID: threadID, output: captured.output)
    }

    private func applyAgentCLIActivityResult(threadID: UUID, captured: AgentCLICapturedOutput) {
        let previousOffset = activityReadOffsetsByThreadID[threadID] ?? 0
        if captured.startOffset != previousOffset {
            activityPartialLinesByThreadID.removeValue(forKey: threadID)
        }
        activityReadOffsetsByThreadID[threadID] = captured.nextOffset
        let completeOutput = completeActivityLogOutput(threadID: threadID, output: captured.output)
        for event in ThreadActivityEvent.helperEvents(from: completeOutput) {
            applyThreadActivity(
                event,
                isUnread: event.status != .working && event.status != .inactive,
                shouldNotify: true
            )
        }
    }

    func threadIDsForAgentCLIActivityPolling() -> [UUID] {
        var seen = Set<UUID>()
        var threadIDs: [UUID] = []
        func append(_ threadID: UUID?) {
            guard let threadID, seen.insert(threadID).inserted else { return }
            threadIDs.append(threadID)
        }
        append(workspace.selectedThreadID)
        append(focusedProjectTerminalThreadID)
        for threadID in workspace.activeProjectLaunchDescriptorThreadIDs {
            append(threadID)
        }
        return threadIDs
    }

    private func completeActivityLogOutput(threadID: UUID, output: String) -> String {
        let combinedOutput = (activityPartialLinesByThreadID[threadID] ?? "") + output
        guard let lastNewlineIndex = combinedOutput.lastIndex(where: \.isNewline) else {
            activityPartialLinesByThreadID[threadID] = combinedOutput
            return ""
        }
        let completeOutput = String(combinedOutput[...lastNewlineIndex])
        let tail = String(combinedOutput[combinedOutput.index(after: lastNewlineIndex)...])
        if tail.isEmpty {
            activityPartialLinesByThreadID.removeValue(forKey: threadID)
        } else {
            activityPartialLinesByThreadID[threadID] = tail
        }
        return completeOutput
    }
}
