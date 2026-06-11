import Foundation

extension WorkspaceStore {
    // MARK: - Project CRUD

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

    public func toggleProjectPinned(id projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].isPinned.toggle()
        projects[index].sortOrder = nextProjectSortOrder(isPinned: projects[index].isPinned)
        normalizeProjectSortOrders()
        if let pinned = projects.first(where: { $0.id == projectID }) { persistProject(pinned) }
    }

    public func toggleSelectedProjectPinned() { toggleProjectPinned(id: selectedProjectID) }

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

    public func moveSelectedProject(direction: ProjectMoveDirection) {
        moveProject(id: selectedProjectID, direction: direction)
    }

    public func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if isExpanded {
            expandedProjectIDs.insert(projectID)
        } else {
            expandedProjectIDs.remove(projectID)
        }
        persistProjectExpanded(projectID: projectID)
    }

    public func toggleSelectedProjectExpanded() {
        setProjectExpanded(selectedProjectID, isExpanded: !isProjectExpanded(selectedProjectID))
    }

    public func setProjectArchiveExpanded(_ projectID: UUID, isExpanded: Bool) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if isExpanded {
            expandedArchivedProjectIDs.insert(projectID)
        } else {
            expandedArchivedProjectIDs.remove(projectID)
        }
        persistProjectArchiveExpanded(projectID: projectID)
    }

    public func toggleSelectedProjectArchiveExpanded() {
        setProjectArchiveExpanded(
            selectedProjectID, isExpanded: !isProjectArchiveExpanded(selectedProjectID))
    }

    // MARK: - Project archive

    public func canArchiveProject(id projectID: UUID) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }) else { return false }
        return !isGlobalProject(project)
    }

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

    public func archiveSelectedProject() { archiveProject(id: selectedProjectID) }

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
