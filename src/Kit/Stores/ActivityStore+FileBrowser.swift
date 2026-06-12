import Foundation

extension ActivityStore {
    private enum FileBrowserLimits {
        static let maxSearchResults = 1_000
        static let maxBrowseEntries = 10_000
    }

    // MARK: - Refresh

    public func refreshSelectedFileBrowser() {
        guard let thread = workspace.selectedThread else {
            fileBrowserState = FileBrowserState()
            rightPanel.setSelectedFile(nil)
            return
        }
        refreshFileBrowser(for: thread)
    }

    /// Resets the published browser state for the newly selected thread, restoring
    /// remembered entries/selection before any reindex. Cancels the prior thread's
    /// in-flight index Task.
    func resetFileBrowserForSelectedThread(selectedThread: AgentThread?) {
        guard let selectedThread else {
            fileBrowserState = FileBrowserState()
            return
        }
        let entries: [FileBrowserEntry]
        let metadata: FileIndexMetadata?
        if let remembered = fileBrowserEntriesByThreadID[selectedThread.id] {
            entries = remembered
            metadata = fileIndexMetadataByThreadID[selectedThread.id]
        } else if let shared = sharedFileBrowserSnapshot(for: selectedThread) {
            entries = shared.entries
            metadata = shared.metadata
        } else {
            entries = []
            metadata =
                isExistingDirectory(selectedThread.workingDirectory)
                ? fileIndexMetadataByThreadID[selectedThread.id] : nil
        }
        publishFileBrowserState(
            for: selectedThread, entries: entries, metadata: metadata, searchQuery: "",
            isIndexing: false)
    }

    /// Refreshes the file index for a thread via the `FileIndexActor`, publishing a
    /// cached snapshot first (when requested) and the fresh result when it lands.
    /// The in-flight read is a per-thread `Task`; reselect/reindex cancels it
    /// (replacing the pre-rewrite request-ID generation guard).
    func refreshFileBrowser(
        for thread: AgentThread,
        publishCachedSnapshot: Bool = true,
        forceReindex: Bool = true
    ) {
        let threadID = thread.id
        fileIndexTasksByThreadID[threadID]?.cancel()
        guard isExistingDirectory(thread.workingDirectory) else {
            if workspace.selectedThreadID == threadID {
                rightPanel.setSelectedFile(nil)
                fileBrowserState = FileBrowserState(
                    rootPath: thread.workingDirectory.path,
                    searchQuery: fileBrowserState.searchQuery,
                    metadata: fileIndexMetadataByThreadID[threadID],
                    errorMessage: "Missing working directory: \(thread.workingDirectory.path)"
                )
            }
            recordDiagnostic(
                category: "Indexing", name: "file_index_failed",
                metadata: ["thread_id": threadID.uuidString, "reason": "missing_root"])
            return
        }
        let ignoreRules = settings.configuration.ignoreRules
        let indexActor = environment.fileIndexActor
        let task = Task { [weak self] in
            guard let self else { return }
            let key = await indexActor.cacheKey(
                root: thread.workingDirectory, ignoreRules: ignoreRules)
            let cached = await indexActor.cachedIndex(threadID: threadID, key: key)
            if !forceReindex, cached != nil { return }
            if publishCachedSnapshot, !Task.isCancelled {
                let entries = cached?.entries ?? self.fileBrowserEntriesByThreadID[threadID] ?? []
                self.publishFileBrowserState(
                    for: thread, entries: entries, metadata: cached?.metadata,
                    searchQuery: self.fileBrowserState.searchQuery, isIndexing: true)
            } else if self.workspace.selectedThreadID == threadID {
                self.fileBrowserState.isIndexing = true
                self.fileBrowserState.errorMessage = nil
            }
            do {
                let result = try await indexActor.refreshIndex(
                    threadID: threadID, root: thread.workingDirectory, ignoreRules: ignoreRules,
                    key: key)
                guard !Task.isCancelled else { return }
                self.finishFileBrowserRefresh(threadID: threadID, result: .success(result))
            } catch {
                guard !Task.isCancelled else { return }
                self.finishFileBrowserRefresh(threadID: threadID, result: .failure(error))
            }
        }
        fileIndexTasksByThreadID[threadID] = task
    }

    private func finishFileBrowserRefresh(
        threadID: UUID, result: Result<FileIndexResult, Error>
    ) {
        fileIndexTasksByThreadID.removeValue(forKey: threadID)
        switch result {
        case .success(let result):
            fileIndexMetadataByThreadID[threadID] = result.metadata
            if result.isTruncated {
                recordDiagnostic(
                    category: "Indexing", name: "file_index_truncated",
                    metadata: [
                        "thread_id": threadID.uuidString,
                        "indexed_entry_count": "\(result.entries.count)",
                        "root": result.metadata.rootPath,
                    ])
            }
            if workspace.selectedThreadID == threadID,
                let thread = workspace.thread(withID: threadID)
            {
                publishFileBrowserState(
                    for: thread, entries: result.entries, metadata: result.metadata,
                    searchQuery: fileBrowserState.searchQuery, isIndexing: false,
                    isIndexTruncated: result.isTruncated)
            } else {
                fileBrowserEntriesByThreadID[threadID] = result.entries
            }
            persistFileIndexMetadata(result.metadata)
        case .failure(let error):
            if workspace.selectedThreadID == threadID {
                fileBrowserState.isIndexing = false
                fileBrowserState.errorMessage = String(describing: error)
            }
            recordDiagnostic(
                category: "Indexing", name: "file_index_failed",
                metadata: [
                    "thread_id": threadID.uuidString, "error": String(describing: error),
                ])
        }
    }

    private func sharedFileBrowserSnapshot(for thread: AgentThread)
        -> (entries: [FileBrowserEntry], metadata: FileIndexMetadata)?
    {
        let rootPath = thread.workingDirectory.standardizedFileURL.path
        for candidate in workspace.threads
        where candidate.id != thread.id
            && candidate.workingDirectory.standardizedFileURL.path == rootPath
        {
            guard let entries = fileBrowserEntriesByThreadID[candidate.id],
                let metadata = fileIndexMetadataByThreadID[candidate.id]
            else { continue }
            return (entries, metadata.forThread(thread.id))
        }
        return nil
    }

    // MARK: - Publish

    private func publishFileBrowserState(
        for thread: AgentThread,
        entries: [FileBrowserEntry],
        metadata: FileIndexMetadata?,
        searchQuery: String,
        isIndexing: Bool,
        isIndexTruncated: Bool = false
    ) {
        fileBrowserEntriesByThreadID[thread.id] = entries
        if let metadata { fileIndexMetadataByThreadID[thread.id] = metadata }
        let browseEntries = entries.sorted(by: FileBrowserTreeBuilder.sortEntriesForTree)
        let visible = Self.visibleEntries(
            browseEntries: browseEntries, originalEntries: entries, query: searchQuery)
        fileBrowserState = FileBrowserState(
            rootPath: thread.workingDirectory.path,
            searchQuery: searchQuery,
            indexedEntryCount: entries.count,
            entries: browseEntries,
            visibleEntries: visible.entries,
            isBrowseEntryLimitApplied: browseEntries.count < entries.count,
            isVisibleEntryLimitApplied: visible.isLimitApplied,
            isIndexing: isIndexing,
            metadata: metadata,
            errorMessage: nil,
            isIndexTruncated: isIndexTruncated
        )
        updateSelectedFileAfterVisibleEntriesChanged()
    }

    private static func visibleEntries(
        browseEntries: [FileBrowserEntry], originalEntries: [FileBrowserEntry], query: String
    ) -> FuzzyFileMatcher.Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return FuzzyFileMatcher.Result(
                entries: browseEntries, totalMatches: originalEntries.count,
                isLimitApplied: browseEntries.count < originalEntries.count)
        }
        return FuzzyFileMatcher.rankedResult(
            originalEntries, query: query, limit: FileBrowserLimits.maxSearchResults)
    }

    // MARK: - Search / selection

    public func updateFileSearchQuery(_ query: String) {
        let fullEntries =
            workspace.selectedThreadID.flatMap { fileBrowserEntriesByThreadID[$0] } ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: FuzzyFileMatcher.Result
        if trimmed.isEmpty {
            result = FuzzyFileMatcher.Result(
                entries: fileBrowserState.entries, totalMatches: fullEntries.count,
                isLimitApplied: fileBrowserState.isBrowseEntryLimitApplied)
        } else {
            result = FuzzyFileMatcher.rankedResult(
                fullEntries, query: query, limit: FileBrowserLimits.maxSearchResults)
        }
        fileBrowserState.searchQuery = query
        fileBrowserState.visibleEntries = result.entries
        fileBrowserState.isVisibleEntryLimitApplied = result.isLimitApplied
        updateSelectedFileAfterVisibleEntriesChanged()
    }

    public func selectFile(relativePath: String?) {
        guard let relativePath else {
            rightPanel.setSelectedFile(nil)
            return
        }
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        let fullEntries =
            workspace.selectedThreadID.flatMap { fileBrowserEntriesByThreadID[$0] } ?? []
        guard fullEntries.contains(where: { $0.relativePath == normalizedPath }) else { return }
        rightPanel.setSelectedFile(normalizedPath)
    }

    public func selectAdjacentFile(direction: ProjectMoveDirection) {
        let entries = fileBrowserState.visibleEntries.filter { !$0.isDirectory }
        guard !entries.isEmpty else {
            rightPanel.setSelectedFile(nil)
            return
        }
        let currentIndex =
            rightPanel.selectedFileRelativePath.flatMap { selectedPath in
                entries.firstIndex { $0.relativePath == selectedPath }
            } ?? -1
        let nextIndex =
            direction == .up ? max(0, currentIndex - 1) : min(entries.count - 1, currentIndex + 1)
        rightPanel.setSelectedFile(entries[nextIndex].relativePath)
    }

    private func updateSelectedFileAfterVisibleEntriesChanged() {
        let fileEntries = fileBrowserState.visibleEntries.filter { !$0.isDirectory }
        guard !fileEntries.isEmpty else {
            rightPanel.clearPublishedSelectedFile()
            return
        }
        if let selected = rightPanel.selectedFileRelativePath,
            fileEntries.contains(where: { $0.relativePath == selected })
        {
            return
        }
        if let selectedThreadID = workspace.selectedThreadID,
            let remembered = rightPanel.rememberedSelectedFile(forThreadID: selectedThreadID)
        {
            rightPanel.setPublishedSelectedFileOnly(remembered)
            return
        }
        rightPanel.setSelectedFile(fileEntries.first?.relativePath)
    }

    func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
