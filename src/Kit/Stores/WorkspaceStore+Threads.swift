import Foundation

extension WorkspaceStore {
    // MARK: - Thread creation

    @discardableResult
    public func createThread(
        projectID: UUID? = nil,
        agentCLI: AgentCLIKind?,
        displayName: String? = nil,
        launchOptions: AgentLaunchOptions = AgentLaunchOptions(),
        workingDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> UUID {
        let agentCLI = agentCLI ?? settings.configuration.defaultAgentCLI
        let resolvedLaunchOptions = resolvedLaunchOptions(
            launchOptions: launchOptions, agentCLI: agentCLI)
        let isImplicitProjectSelection = projectID == nil
        let resolvedProjectID = projectID ?? selectedProjectID
        guard let project = projects.first(where: { $0.id == resolvedProjectID }) else {
            throw WorkspaceStoreError.selectedProjectMissing
        }
        if isImplicitProjectSelection, isGlobalProject(project) {
            throw WorkspaceStoreError.projectRequiredForThreadCreation
        }
        if isGlobalProject(project) { ensureGlobalChatsDirectoryExists() }
        let resolvedWorkingDirectory =
            workingDirectory
            ?? (isGlobalProject(project) ? globalChatsDirectory : project.rootDirectory)
        guard isExistingDirectory(resolvedWorkingDirectory) else {
            throw WorkspaceStoreError.missingProjectDirectory(resolvedWorkingDirectory.path)
        }

        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName =
            trimmedDisplayName?.isEmpty == false
            ? trimmedDisplayName ?? "" : "Starting \(agentCLI.displayName)..."
        let canApplyNameOnLaunch = canApplySessionNameOnLaunch(for: agentCLI)
        let pendingSessionRename =
            trimmedDisplayName?.isEmpty == false && canApplyNameOnLaunch ? trimmedDisplayName : nil
        let thread = AgentThread(
            displayName: resolvedDisplayName,
            projectID: project.id,
            workingDirectory: resolvedWorkingDirectory,
            agentCLI: agentCLI,
            launchOptions: resolvedLaunchOptions,
            pendingSessionRename: pendingSessionRename,
            createdAt: now,
            lastOpenedAt: now
        )
        mutateThreads { $0.append(thread) }
        markProjectOpened(project.id, now: now)
        selectedThreadID = thread.id
        selectedProjectID = project.id
        expandedProjectIDs.insert(project.id)
        rightPanel?.seedDefaultState(forThreadID: thread.id)
        afterSelectionChanged()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Threads",
            name: "thread_created",
            metadata: [
                "thread_id": thread.id.uuidString,
                "agent_cli": thread.agentCLI.rawValue,
                "custom_launch_options": thread.launchOptions.isEmpty ? "false" : "true",
            ]
        )
        persistThread(thread)
        if let updatedProject = projects.first(where: { $0.id == project.id }) {
            persistProject(updatedProject)
        }
        persistProjectExpanded(projectID: project.id)
        persistSelection()
        _ = activateTerminal(role: .project(threadID: thread.id))
        return thread.id
    }

    /// Resolves the effective launch options for a new thread: explicit options if
    /// given, else the configured defaults, with the executable-name fallback.
    private func resolvedLaunchOptions(launchOptions: AgentLaunchOptions, agentCLI: AgentCLIKind)
        -> AgentLaunchOptions
    {
        var candidate =
            launchOptions.isEmpty ? settings.configuredLaunchOptions(for: agentCLI) : launchOptions
        if candidate.executableName == nil {
            candidate.executableName = settings.configuration.agentExecutableName(for: agentCLI)
        }
        return candidate.validated(
            for: agentCLI, permissionModes: settings.permissionModes(for: agentCLI))
    }

    public func changeAgentCLI(for threadID: UUID, to agentCLI: AgentCLIKind) throws {
        guard threadIndexByID[threadID] != nil else { throw WorkspaceStoreError.threadNotFound }
        throw WorkspaceStoreError.agentCLIChangeNotAllowed
    }

    // MARK: - Thread pin / rename

    public func toggleThreadPinned(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThread(at: index) { $0.isPinned.toggle() }
        persistThread(threads[index])
    }

    public func toggleSelectedThreadPinned() {
        guard let selectedThreadID else { return }
        toggleThreadPinned(id: selectedThreadID)
    }

    public func canRequestThreadRename(id threadID: UUID) async -> Bool {
        guard let thread = thread(withID: threadID) else { return false }
        return await environment.sessionBindingActor.supportsSessionRename(for: thread.agentCLI)
    }

    public func requestThreadRename(id threadID: UUID, to rawName: String) async throws {
        guard let index = threadIndexByID[threadID] else {
            throw WorkspaceStoreError.threadNotFound
        }
        guard
            await environment.sessionBindingActor.supportsSessionRename(
                for: threads[index].agentCLI)
        else { throw WorkspaceStoreError.sessionRenameNotSupported }
        guard let name = Self.normalizedThreadName(rawName) else {
            throw WorkspaceStoreError.emptyThreadName
        }
        let hadStoredIdentity = threads[index].sessionIdentity != nil
        let wasArchived = threads[index].isArchived
        mutateThread(at: index) { $0.pendingSessionRename = name }
        persistThread(threads[index])
        activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
        captureReadOffsetsByThreadID.removeValue(forKey: threadID)
        activity?.invalidatePolling(threadID: threadID)
        recordDiagnostic(
            category: "AgentCLI",
            name: "thread_rename_requested",
            metadata: [
                "thread_id": threadID.uuidString,
                "agent_cli": threads[index].agentCLI.rawValue,
            ]
        )
        guard selectedThreadID == threadID, !wasArchived, hadStoredIdentity,
            !sessionLinkRequiredThreadIDs.contains(threadID)
        else { return }
        environment.renderSurfaceManager.shutdown(role: .project(threadID: threadID))
        _ = activateTerminal(role: .project(threadID: threadID))
    }

    private func canApplySessionNameOnLaunch(for agentCLI: AgentCLIKind) -> Bool {
        // CLIs that accept a name at launch (start-name) or rename. Codex/Claude
        // support naming; opencode/copilot do not. Mirrors the manifest capability
        // the SessionBindingActor exposes, computed synchronously here for thread
        // creation. The manifest is the source of truth (Chunk C).
        switch agentCLI {
        case .codex, .claude:
            return true
        case .opencode, .copilot:
            return false
        }
    }

    // MARK: - Thread archive

    public func archiveThread(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        let projectID = threads[index].projectID
        mutateThread(at: index) { $0.isArchived = true }
        if selectedThreadID == threadID {
            selectedThreadID = firstActiveThreadID(forProject: projectID)
            afterSelectionChanged()
        }
        pushCurrentSelection()
        persistThread(threads[index])
        persistSelection()
    }

    public func archiveSelectedThread() {
        guard let selectedThreadID else { return }
        archiveThread(id: selectedThreadID)
    }

    public func unarchiveThread(id threadID: UUID) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThread(at: index) {
            $0.isArchived = false
            $0.lastOpenedAt = Date()
        }
        selectThread(id: threadID)
    }

    public func unarchiveSelectedThread() {
        guard let selectedThreadID else { return }
        unarchiveThread(id: selectedThreadID)
    }

    func markThreadOpened(_ threadID: UUID, now: Date = Date()) {
        guard let index = threadIndexByID[threadID] else { return }
        mutateThread(at: index) { $0.lastOpenedAt = now }
    }

    /// Advances a thread's `lastOpenedAt` and persists it. Called by ActivityStore
    /// when newer activity arrives, so the thread floats up the sorted cache.
    func touchThreadLastOpened(at index: Int, to date: Date) {
        let threadID = threads[index].id
        mutateThread(at: index) { $0.lastOpenedAt = date }
        if let updatedIndex = threadIndexByID[threadID] { persistThread(threads[updatedIndex]) }
    }
}
