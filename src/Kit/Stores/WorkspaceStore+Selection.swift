import Foundation

extension WorkspaceStore {
    // MARK: - Selection

    /// Selects the project, expands it, selects its first active thread (or none for the
    /// global project), records the change in navigation history, and persists it.
    public func selectProject(id projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        guard selectedProjectID != projectID else { return }
        markProjectOpened(projectID)
        selectedProjectID = projectID
        selectedThreadID =
            isGlobalProject(project) ? nil : firstActiveThreadID(forProject: projectID)
        expandedProjectIDs.insert(projectID)
        afterSelectionChanged()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Projects", name: "project_selected",
            metadata: ["project_id": projectID.uuidString])
        persistSelectionChange(
            touchedProject: projects.first { $0.id == projectID }, expandedProjectID: projectID)
    }

    /// Selects the thread and its owning project, marks both opened, records the change
    /// in navigation history, and persists it.
    public func selectThread(id threadID: UUID) {
        guard let thread = thread(withID: threadID) else { return }
        markProjectOpened(thread.projectID)
        markThreadOpened(threadID)
        selectedProjectID = thread.projectID
        selectedThreadID = thread.id
        expandedProjectIDs.insert(thread.projectID)
        afterSelectionChanged()
        recordDiagnostic(
            category: "Threads",
            name: "thread_selected",
            metadata: [
                "thread_id": thread.id.uuidString,
                "agent_cli": thread.agentCLI.rawValue,
            ]
        )
        pushCurrentSelection()
        persistSelectionChange(
            touchedProject: projects.first { $0.id == thread.projectID },
            touchedThread: threadIndexByID[threadID].map { threads[$0] },
            expandedProjectID: thread.projectID
        )
    }

    // MARK: - Navigation

    /// Moves to the previous selection in navigation history, if any, and persists it.
    public func navigateBack() {
        guard let selection = navigationHistory.goBack() else { return }
        apply(selection)
        persistSelectionChange(expandedProjectID: selection.projectID)
    }

    /// Moves to the next selection in navigation history, if any, and persists it.
    public func navigateForward() {
        guard let selection = navigationHistory.goForward() else { return }
        apply(selection)
        persistSelectionChange(expandedProjectID: selection.projectID)
    }

    func pushCurrentSelection() {
        navigationHistory.push(
            AppSelection(projectID: selectedProjectID, threadID: selectedThreadID))
    }

    private func apply(_ selection: AppSelection) {
        guard projects.contains(where: { $0.id == selection.projectID }) else { return }
        selectedProjectID = selection.projectID
        selectedThreadID = selection.threadID
        expandedProjectIDs.insert(selection.projectID)
        afterSelectionChanged()
    }

    /// Fans the new selection out to the sibling stores and refreshes the file
    /// browser for the newly selected thread. Single place selection effects live,
    /// so every selecting path (create/select/archive/navigate) is consistent.
    func afterSelectionChanged() {
        layout?.selectedThreadID = selectedThreadID
        rightPanel?.selectedThreadID = selectedThreadID
        rightPanel?.restoreSelectedFile(forThreadID: selectedThreadID)
        activity?.handleSelectionChanged(selectedThread: selectedThread)
    }

    // MARK: - Persistence

    func persistSelection() {
        let projectID = selectedProjectID
        let threadID = selectedThreadID
        persistence.enqueue {
            await $0.setSelectedProject(projectID)
            await $0.setSelectedThread(threadID)
        }
    }

    func persistSelectionChange(
        touchedProject: Project? = nil,
        touchedThread: AgentThread? = nil,
        expandedProjectID: UUID? = nil
    ) {
        let projectID = selectedProjectID
        let threadID = selectedThreadID
        persistence.enqueue {
            await $0.persistSelectionChange(
                selectedProjectID: projectID,
                selectedThreadID: threadID,
                touchedProject: touchedProject,
                touchedThread: touchedThread,
                expandedProjectID: expandedProjectID
            )
        }
    }

    func persistThread(_ thread: AgentThread) {
        persistence.enqueue { await $0.upsertThread(thread) }
    }

    func persistProject(_ project: Project) {
        persistence.enqueue { await $0.upsertProject(project) }
    }

    func persistProjectExpanded(projectID: UUID) {
        let isExpanded = expandedProjectIDs.contains(projectID)
        persistence.enqueue { await $0.setProjectExpanded(projectID, isExpanded: isExpanded) }
    }

    func persistProjectArchiveExpanded(projectID: UUID) {
        let isExpanded = expandedArchivedProjectIDs.contains(projectID)
        persistence.enqueue {
            await $0.setProjectArchiveExpanded(projectID, isExpanded: isExpanded)
        }
    }
}
