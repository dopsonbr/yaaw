import Foundation

extension WorkspaceStore {
    // MARK: - Thread index + per-project caches

    /// Full rebuild from the threads array; used on bulk mutation (append, load).
    func rebuildThreadIndexes() {
        threadIndexByID.removeAll(keepingCapacity: true)
        cachedActiveThreadsByProject.removeAll(keepingCapacity: true)
        cachedArchivedThreadsByProject.removeAll(keepingCapacity: true)
        for (index, thread) in threads.enumerated() {
            threadIndexByID[thread.id] = index
            if thread.isArchived {
                cachedArchivedThreadsByProject[thread.projectID, default: []].append(thread)
            } else {
                cachedActiveThreadsByProject[thread.projectID, default: []].append(thread)
            }
        }
        for projectID in cachedActiveThreadsByProject.keys {
            cachedActiveThreadsByProject[projectID]?.sort(by: Self.threadPrecedes)
        }
        for projectID in cachedArchivedThreadsByProject.keys {
            cachedArchivedThreadsByProject[projectID]?.sort(by: Self.threadPrecedes)
        }
    }

    func mutateThreads(_ block: (inout [AgentThread]) -> Void) {
        block(&threads)
        rebuildThreadIndexes()
    }

    /// In-place single-thread mutation that patches the caches without a full
    /// rebuild (the O(1) maintenance path used on rename/pin/archive/touch).
    func mutateThread(at index: Int, _ block: (inout AgentThread) -> Void) {
        let previousThread = threads[index]
        block(&threads[index])
        let updatedThread = threads[index]
        if previousThread.id != updatedThread.id {
            threadIndexByID.removeValue(forKey: previousThread.id)
        }
        threadIndexByID[updatedThread.id] = index
        updateCachedThread(previousThread: previousThread, updatedThread: updatedThread)
    }

    private func updateCachedThread(previousThread: AgentThread, updatedThread: AgentThread) {
        if previousThread.projectID == updatedThread.projectID,
            previousThread.isArchived == updatedThread.isArchived
        {
            replaceCachedThread(updatedThread, matching: previousThread)
        } else {
            removeCachedThread(previousThread)
            insertCachedThread(updatedThread)
        }
    }

    private func replaceCachedThread(_ thread: AgentThread, matching previousThread: AgentThread) {
        if thread.isArchived {
            replaceCachedThread(
                thread, matching: previousThread, in: &cachedArchivedThreadsByProject)
        } else {
            replaceCachedThread(thread, matching: previousThread, in: &cachedActiveThreadsByProject)
        }
    }

    private func replaceCachedThread(
        _ thread: AgentThread,
        matching previousThread: AgentThread,
        in cache: inout [UUID: [AgentThread]]
    ) {
        let projectID = thread.projectID
        guard let currentIndex = cache[projectID]?.firstIndex(where: { $0.id == previousThread.id })
        else {
            insertCachedThread(thread, into: &cache)
            return
        }
        cache[projectID]?.remove(at: currentIndex)
        let insertionIndex =
            cache[projectID]?.firstIndex { Self.threadPrecedes(thread, $0) }
            ?? cache[projectID]?.endIndex ?? 0
        cache[projectID]?.insert(thread, at: insertionIndex)
    }

    private func removeCachedThread(_ thread: AgentThread) {
        if thread.isArchived {
            removeCachedThread(thread, from: &cachedArchivedThreadsByProject)
        } else {
            removeCachedThread(thread, from: &cachedActiveThreadsByProject)
        }
    }

    private func removeCachedThread(_ thread: AgentThread, from cache: inout [UUID: [AgentThread]])
    {
        guard var projectThreads = cache[thread.projectID] else { return }
        projectThreads.removeAll { $0.id == thread.id }
        if projectThreads.isEmpty {
            cache.removeValue(forKey: thread.projectID)
        } else {
            cache[thread.projectID] = projectThreads
        }
    }

    private func insertCachedThread(_ thread: AgentThread) {
        if thread.isArchived {
            insertCachedThread(thread, into: &cachedArchivedThreadsByProject)
        } else {
            insertCachedThread(thread, into: &cachedActiveThreadsByProject)
        }
    }

    private func insertCachedThread(_ thread: AgentThread, into cache: inout [UUID: [AgentThread]])
    {
        var projectThreads = cache[thread.projectID] ?? []
        projectThreads.removeAll { $0.id == thread.id }
        let insertionIndex =
            projectThreads.firstIndex { Self.threadPrecedes(thread, $0) } ?? projectThreads.endIndex
        projectThreads.insert(thread, at: insertionIndex)
        cache[thread.projectID] = projectThreads
    }

    // MARK: - Sort comparators

    static func threadPrecedes(_ lhs: AgentThread, _ rhs: AgentThread) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        if lhs.lastOpenedAt != rhs.lastOpenedAt { return lhs.lastOpenedAt > rhs.lastOpenedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    static func sortedProjects(_ projects: [Project]) -> [Project] {
        projects.sorted { lhs, rhs in
            let lhsIsGlobal = isGlobalProject(lhs)
            let rhsIsGlobal = isGlobalProject(rhs)
            if lhsIsGlobal != rhsIsGlobal { return !lhsIsGlobal && rhsIsGlobal }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func normalizedThreadName(_ name: String) -> String? {
        let normalized =
            name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    // MARK: - Global project

    static func isGlobalProject(_ project: Project) -> Bool { project.displayName == "Global" }
    func isGlobalProject(_ project: Project) -> Bool { Self.isGlobalProject(project) }

    static func globalChatsDirectory(for configuration: YAAWConfiguration, homeDirectory: URL)
        -> URL
    {
        configuration.projects.resolvedGlobalChatsDirectory(homeDirectory: homeDirectory)
    }

    var globalChatsDirectory: URL {
        Self.globalChatsDirectory(
            for: settings.configuration, homeDirectory: environment.homeDirectory)
    }

    static func ensureGlobalChatsDirectoryExists(
        _ directory: URL, diagnosticRecorder: any DiagnosticEventRecording
    ) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            diagnosticRecorder.record(
                DiagnosticEvent(
                    category: "Projects",
                    name: "global_chats_directory_create_failed",
                    metadata: ["path": directory.path, "error": String(describing: error)]
                ))
        }
    }

    func ensureGlobalChatsDirectoryExists() {
        Self.ensureGlobalChatsDirectoryExists(
            globalChatsDirectory, diagnosticRecorder: environment.diagnosticRecorder)
    }

    func reconcileGlobalProjectDirectory(previousGlobalChatsDirectory: URL? = nil) {
        let directory = globalChatsDirectory
        ensureGlobalChatsDirectoryExists()
        var didChange = false
        for index in projects.indices where isGlobalProject(projects[index]) {
            let previousPath = projects[index].rootDirectory.standardizedFileURL.path
            guard previousPath != directory.standardizedFileURL.path else { continue }
            projects[index].rootDirectory = directory
            persistProject(projects[index])
            didChange = true
        }
        guard didChange else { return }
        projects = Self.sortedProjects(projects)
        if let selectedProject, isGlobalProject(selectedProject) {
            selectedThreadID = nil
            persistSelection()
        }
        recordDiagnostic(
            category: "Projects",
            name: "global_chats_directory_updated",
            metadata: [
                "path": directory.path,
                "previous_path": previousGlobalChatsDirectory?.path ?? "",
            ]
        )
    }

    func handleConfigurationReload(_ configuration: YAAWConfiguration) {
        let previousGlobalChatsDirectory = globalChatsDirectory
        reconcileGlobalProjectDirectory(previousGlobalChatsDirectory: previousGlobalChatsDirectory)
        activeProjectLaunchDescriptorsByThreadID.removeAll()
        activity?.handleConfigurationReload()
    }
}
