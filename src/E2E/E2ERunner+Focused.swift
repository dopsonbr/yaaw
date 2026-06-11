import Foundation
import YAAWKit

extension E2ERunner {
    /// The full no-mock journey over the five stores. Returns the IDs the
    /// launched-app states + manifest reference. Split into focused helpers so
    /// each stays within the body-length budget.
    func runFocusedBehaviorAssertions() async throws -> FocusedBehaviorResult {
        let databasePath = paths.stateDirectory.appendingPathComponent("focused-behavior.sqlite")
        let stores = try await makeStores(databasePath: databasePath)

        try assertSettingsYAMLAndExternalOpen(stores: stores)
        try assertInitialSandboxSelection(stores: stores)
        try createProjectAndThreads(stores: stores)
        try assertCatalogRefreshAndConfiguredDefault(stores: stores)
        let codexThreadID = try await assertCodexMetadataAndRename(stores: stores)
        let claudeThreadID = try await assertRemainingAgentMetadata(stores: stores)
        try assertThemeAndFontReloads(stores: stores, codexThreadID: codexThreadID)
        try await assertFileBrowserAndBrowserTabs(
            stores: stores, codexThreadID: codexThreadID, claudeThreadID: claudeThreadID)
        try await assertToolFallbacksAndRecovery(stores: stores, codexThreadID: codexThreadID)
        try assertLayoutAndArchive(stores: stores, claudeThreadID: claudeThreadID)
        try await assertAgentCLIMetadataCapture()
        // Drain every enqueued durable write before reopening the database, so the
        // reload observes the full focused-behavior state (the async persistence
        // queue is FIFO; flushing the four mutating stores covers it).
        await fixtures.flush(stores)
        try await assertReloadResumesSession(
            databasePath: databasePath, codexThreadID: codexThreadID)

        return FocusedBehaviorResult(
            databasePath: databasePath,
            codexThreadID: codexThreadID,
            claudeThreadID: claudeThreadID
        )
    }

    // MARK: - Settings YAML / external-open

    private func assertSettingsYAMLAndExternalOpen(stores: AppStores) throws {
        let settingsText = try String(contentsOf: paths.configPath, encoding: .utf8)
        try e2eAssert(settingsText.contains("externalOpen:"), "settings YAML exposes externalOpen")
        try e2eAssert(
            settingsText.contains("default: zed"),
            "settings YAML exposes the default external-open destination")
        try e2eAssert(settingsText.contains("fonts:"), "settings YAML exposes font settings")
        try e2eAssert(
            settingsText.contains("interfaceFamily: system"),
            "settings YAML exposes the interface font family")
        try e2eAssert(
            settingsText.contains("editorFamily: \"JetBrains Mono\""),
            "settings YAML exposes the editor font family")
        try e2eAssert(
            settingsText.contains("terminalFamily: \"JetBrains Mono\""),
            "settings YAML exposes the default terminal font family")
        let detectedExternalTools: Set<ExternalOpenToolID> = [.vscode, .finder]
        try e2eAssert(
            ExternalOpenToolResolver.defaultTool(
                settings: stores.settings.configuration.tools.externalOpen,
                detectedTools: detectedExternalTools
            ) == .vscode,
            "external-open default falls back to first detected preferred destination")
    }

    private func assertInitialSandboxSelection(stores: AppStores) throws {
        let workspace = stores.workspace
        try e2eAssert(
            workspace.selectedProject?.displayName == "E2E Sandbox",
            "initial launch selected the seeded sandbox project")
        try e2eAssert(
            workspace.selectedProject?.rootDirectory == paths.workspaceDirectory,
            "initial launch used an E2E sandbox root")
        try e2eAssert(
            workspace.selectedExternalOpenDirectoryTarget
                == ExternalOpenTarget(url: paths.workspaceDirectory, kind: .directory),
            "external-open target falls back to selected project when no thread is selected")
    }

    // MARK: - Project + thread creation, naming, pinning

    private func createProjectAndThreads(stores: AppStores) throws {
        let workspace = stores.workspace
        try workspace.createProject(
            displayName: "E2E Project", rootDirectory: paths.projectDirectory)
        try e2eAssert(
            workspace.selectedProject?.rootDirectory == paths.projectDirectory,
            "project creation selected the fixture project")
        try e2eAssert(
            workspace.selectedExternalOpenDirectoryTarget
                == ExternalOpenTarget(url: paths.projectDirectory, kind: .directory),
            "external-open target follows the selected project before thread creation")
        let e2eProjectID = try e2eUnwrap(workspace.selectedProject?.id, "fixture project id exists")
        let sandboxProjectID = try e2eUnwrap(
            workspace.projects.first { $0.displayName == "E2E Sandbox" }?.id,
            "sandbox project id exists")

        let sandboxThreadID = try workspace.createThread(
            projectID: sandboxProjectID, agentCLI: .codex,
            displayName: "  Sandbox Named Thread  ")
        try e2eAssert(
            workspace.selectedProjectID == sandboxProjectID,
            "project-row thread creation selected the target project")
        try e2eAssert(
            workspace.selectedThread?.displayName == "Sandbox Named Thread",
            "project-row thread creation accepted optional name")
        try e2eAssert(
            workspace.activeThreads(for: sandboxProjectID).contains { $0.id == sandboxThreadID },
            "targeted thread appeared under its project")
        try e2eAssert(
            workspace.isProjectExpanded(sandboxProjectID),
            "targeted project expanded after creating a thread")

        workspace.toggleProjectPinned(id: e2eProjectID)
        try e2eAssert(workspace.projects.first?.id == e2eProjectID, "pinned project sorted first")
        workspace.toggleThreadPinned(id: sandboxThreadID)
        try e2eAssert(
            workspace.activeThreads(for: sandboxProjectID).first?.id == sandboxThreadID,
            "pinned thread sorted first")
        workspace.selectProject(id: e2eProjectID)
    }

    // MARK: - Catalog refresh / configured-default thread

    private func assertCatalogRefreshAndConfiguredDefault(stores: AppStores) throws {
        let refreshedCatalog = stores.settings.refreshAgentCLIOptionCatalog()
        try e2eAssert(
            refreshedCatalog.permissionPresets(for: .codex).contains { $0.id == "codex-bypass" },
            "CLI option refresh captured codex bypass preset")
        try e2eAssert(
            refreshedCatalog.permissionPresets(for: .copilot).contains { $0.id == "copilot-yolo" },
            "CLI option refresh captured copilot yolo preset")

        stores.settings.reloadConfiguration(
            YAAWConfiguration(
                agent: AgentSettings(
                    default: .copilot,
                    launchDefaults: AgentLaunchDefaultsSettings(
                        copilot: AgentLaunchDefaultSettings(
                            permissionModeID: "copilot-yolo",
                            additionalArguments: ["--model", "gpt-5"]))),
                tools: ToolSettings(agents: AgentToolSettings(copilot: "copilot"))))
        try e2eAssert(
            stores.settings.defaultAgentCLI == .copilot,
            "settings default agent drives the new-thread picker default badge source")
        try e2eAssert(
            stores.settings.configuredLaunchOptions(for: .copilot).permissionModeID
                == "copilot-yolo",
            "new-thread picker summary reads configured copilot permission default")

        let configuredDefaultThreadID = try stores.workspace.createThread(
            agentCLI: nil, displayName: "Configured Default")
        let configuredDefaultThread = try e2eUnwrap(
            stores.workspace.threads.first { $0.id == configuredDefaultThreadID },
            "configured default thread")
        try e2eAssert(
            configuredDefaultThread.agentCLI == .copilot,
            "new-thread default agent created a copilot-backed thread")
        try e2eAssert(
            configuredDefaultThread.launchOptions.permissionModeID == "copilot-yolo",
            "new-thread creation captured configured permission default")
        try e2eAssert(
            configuredDefaultThread.launchOptions.additionalArguments == ["--model", "gpt-5"],
            "new-thread creation captured configured extra args")
    }
}
