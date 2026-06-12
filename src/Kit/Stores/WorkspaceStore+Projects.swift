import Foundation

extension WorkspaceStore {
    // MARK: - Project CRUD

    /// Creates a project for the given directory, selects it, persists it, and
    /// returns its identifier. Falls back to the directory name when the supplied
    /// display name is blank. Throws if the directory is missing or the resolved
    /// name is empty.
    @discardableResult
    public func createProject(displayName: String, rootDirectory: URL, now: Date = Date()) throws
        -> UUID
    {
        guard isExistingDirectory(rootDirectory) else {
            throw WorkspaceStoreError.missingProjectDirectory(rootDirectory.path)
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = rootDirectory.standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? directoryName : trimmedName
        guard !resolvedName.isEmpty else { throw WorkspaceStoreError.emptyProjectName }

        let project = Project(
            displayName: resolvedName,
            rootDirectory: rootDirectory,
            createdAt: now,
            lastOpenedAt: now,
            sortOrder: nextProjectSortOrder(isPinned: false)
        )
        projects.append(project)
        projects = Self.sortedProjects(projects)
        selectedProjectID = project.id
        selectedThreadID = nil
        expandedProjectIDs.insert(project.id)
        afterSelectionChanged()
        pushCurrentSelection()
        recordDiagnostic(
            category: "Projects", name: "project_created",
            metadata: ["project_id": project.id.uuidString])
        persistProject(project)
        persistProjectExpanded(projectID: project.id)
        persistSelection()
        return project.id
    }

    /// Toggles the given project's pinned state, re-sorts it within its pin group,
    /// and persists the change.
    public func toggleProjectPinned(id projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].isPinned.toggle()
        projects[index].sortOrder = nextProjectSortOrder(isPinned: projects[index].isPinned)
        normalizeProjectSortOrders()
        if let pinned = projects.first(where: { $0.id == projectID }) { persistProject(pinned) }
    }

    /// Toggles the pinned state of the currently selected project.
    public func toggleSelectedProjectPinned() { toggleProjectPinned(id: selectedProjectID) }

    /// Moves the given project one position up or down within its pin group.
    public func moveProject(id projectID: UUID, direction: ProjectMoveDirection) {
        projects = Self.sortedProjects(projects)
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let candidateIndex = direction == .up ? index - 1 : index + 1
        guard projects.indices.contains(candidateIndex),
            projects[index].isPinned == projects[candidateIndex].isPinned
        else { return }
        projects.swapAt(index, candidateIndex)
        normalizeProjectSortOrders(preservingCurrentOrder: true)
    }

    /// Reorders the given project to sit immediately before the target project,
    /// when both share the same pin group.
    public func reorderProject(id projectID: UUID, before targetProjectID: UUID) {
        guard projectID != targetProjectID else { return }
        projects = Self.sortedProjects(projects)
        guard let sourceIndex = projects.firstIndex(where: { $0.id == projectID }),
            let targetIndex = projects.firstIndex(where: { $0.id == targetProjectID }),
            projects[sourceIndex].isPinned == projects[targetIndex].isPinned
        else { return }
        let project = projects.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        projects.insert(project, at: insertionIndex)
        normalizeProjectSortOrders(preservingCurrentOrder: true)
    }

    /// Moves the currently selected project one position up or down.
    public func moveSelectedProject(direction: ProjectMoveDirection) {
        moveProject(id: selectedProjectID, direction: direction)
    }

    /// Expands or collapses the given project's active-thread list and persists it.
    public func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if isExpanded {
            expandedProjectIDs.insert(projectID)
        } else {
            expandedProjectIDs.remove(projectID)
        }
        persistProjectExpanded(projectID: projectID)
    }

    /// Toggles whether the selected project's active-thread list is expanded.
    public func toggleSelectedProjectExpanded() {
        setProjectExpanded(selectedProjectID, isExpanded: !isProjectExpanded(selectedProjectID))
    }

    /// Expands or collapses the given project's archived-thread list and persists it.
    public func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if isExpanded {
            expandedArchivedProjectIDs.insert(projectID)
        } else {
            expandedArchivedProjectIDs.remove(projectID)
        }
        persistProjectArchiveExpanded(projectID: projectID)
    }

    /// Toggles whether the selected project's archived-thread list is expanded.
    public func toggleSelectedProjectArchiveExpanded() {
        setProjectArchiveExpanded(
            selectedProjectID, isExpanded: !isProjectArchiveExpanded(selectedProjectID))
    }

    // MARK: - Project archive

    /// Whether the given project may be archived (the Global project may not).
    public func canArchiveProject(id projectID: UUID) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }) else { return false }
        return !isGlobalProject(project)
    }

    /// Archives the given project (never the Global project), selecting a fallback
    /// active project if the archived one was selected, and persists the change.
    public func archiveProject(id projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }),
            !isGlobalProject(projects[index])
        else { return }
        projects[index].isArchived = true
        let archivedProject = projects[index]
        if selectedProjectID == projectID {
            let fallback =
                activeProjects.first { !isGlobalProject($0) }?.id ?? activeProjects.first?.id
            if let fallback { selectProject(id: fallback) }
        }
        persistProject(archivedProject)
    }

    /// Archives the currently selected project.
    public func archiveSelectedProject() { archiveProject(id: selectedProjectID) }

    /// Unarchives the given project, marks it opened, selects it, and persists it.
    public func unarchiveProject(id projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].isArchived = false
        projects[index].lastOpenedAt = Date()
        persistProject(projects[index])
        selectProject(id: projectID)
    }

    // MARK: - Sort-order maintenance

    func nextProjectSortOrder(isPinned: Bool) -> Int {
        (projects.filter { $0.isPinned == isPinned }.map(\.sortOrder).max() ?? -1) + 1
    }

    func normalizeProjectSortOrders(preservingCurrentOrder: Bool = false) {
        if !preservingCurrentOrder { projects = Self.sortedProjects(projects) }
        var pinnedOrder = 0
        var unpinnedOrder = 0
        for index in projects.indices {
            if projects[index].isPinned {
                projects[index].sortOrder = pinnedOrder
                pinnedOrder += 1
            } else {
                projects[index].sortOrder = unpinnedOrder
                unpinnedOrder += 1
            }
            persistProject(projects[index])
        }
        projects = Self.sortedProjects(projects)
    }

    func markProjectOpened(_ projectID: UUID, now: Date = Date()) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].lastOpenedAt = now
    }
}
