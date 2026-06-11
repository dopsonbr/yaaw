import Foundation
import YAAWKit

extension E2ERunner {
    // MARK: - Codex metadata capture + rename relaunch

    func assertCodexMetadataAndRename(stores: AppStores) async throws -> UUID {
        let workspace = stores.workspace
        let codexThreadID = try workspace.createThread(agentCLI: .codex)
        try e2eAssert(
            workspace.selectedThread?.agentCLI == .codex,
            "codex choice created a codex-backed thread")
        try e2eAssert(
            workspace.selectedExternalOpenDirectoryTarget
                == ExternalOpenTarget(url: paths.projectDirectory, kind: .directory),
            "external-open target follows the selected thread working directory")

        await stores.activity.recordAgentCLIOutput(
            threadID: codexThreadID,
            output: "YAAW_SESSION_ID=codex-e2e-001\nYAAW_SESSION_NAME=Codex E2E Session\n")
        try e2eAssert(
            workspace.selectedThread?.displayName == "Codex E2E Session",
            "codex CLI metadata renamed the thread")

        try await workspace.requestThreadRename(id: codexThreadID, to: "Codex Renamed E2E")
        try e2eAssert(
            workspace.selectedThread?.displayName == "Codex E2E Session",
            "queued context-menu rename left the confirmed codex name visible")
        try e2eAssert(
            workspace.selectedThread?.pendingSessionRename == "Codex Renamed E2E",
            "queued context-menu rename persisted pending intent")

        try await assertRenameRelaunchQueuesSlashCommand(
            workspace: workspace, codexThreadID: codexThreadID)

        await stores.activity.recordAgentCLIOutput(
            threadID: codexThreadID,
            output: "YAAW_SESSION_ID=codex-e2e-001\nYAAW_SESSION_NAME=Codex Renamed E2E\n")
        try e2eAssert(
            workspace.selectedThread?.displayName == "Codex Renamed E2E",
            "manual slash rename metadata updated the project/thread row")
        try e2eAssert(
            workspace.selectedThread?.pendingSessionRename == nil,
            "confirmed slash rename cleared pending intent")

        try await assertCodexActivityChain(stores: stores, codexThreadID: codexThreadID)
        return codexThreadID
    }

    private func assertRenameRelaunchQueuesSlashCommand(
        workspace: WorkspaceStore, codexThreadID: UUID
    ) async throws {
        let renameLaunch = try e2eUnwrap(
            await workspace.surfaceLaunch(for: .project(threadID: codexThreadID)),
            "rename relaunch surface")
        let descriptor = try e2eUnwrap(
            renameLaunch.agentLaunchDescriptor, "rename relaunch agent descriptor")
        try e2eAssert(
            descriptor.startupInput == "/rename Codex Renamed E2E\n",
            "rename relaunch queued slash command startup input")
        try e2eAssert(
            descriptor.command.joined(separator: " ").contains("codex-e2e-001"),
            "rename relaunch resumed the stored codex session")
    }

    private func assertCodexActivityChain(stores: AppStores, codexThreadID: UUID) async throws {
        let activity = stores.activity
        try await runYAAWNotify(
            threadID: codexThreadID, status: "needs-input", title: "Approval needed",
            body: "Review fixture command")
        await activity.pollAgentCLIActivityLogs()
        try e2eAssert(
            activity.threadActivity(for: codexThreadID).status == .needsInput,
            "helper notification marked codex thread as needing input")
        try e2eAssert(
            activity.threadActivity(for: codexThreadID).preview == "Review fixture command",
            "helper notification preview was captured")
        try e2eAssert(
            activity.threadActivity(for: codexThreadID).isUnread,
            "helper notification marked codex thread unread")

        activity.recordAgentTerminalFocus(threadID: codexThreadID, focused: true)
        try e2eAssert(
            !activity.threadActivity(for: codexThreadID).isUnread,
            "focused codex terminal cleared unread notification")
        activity.recordAgentTerminalNotification(
            threadID: codexThreadID, title: "Task complete", body: "Fixture tests passed")
        try e2eAssert(
            activity.threadActivity(for: codexThreadID).status == .complete,
            "OSC-style terminal notification marked codex thread complete")
    }

    // MARK: - Remaining agents' metadata capture

    func assertRemainingAgentMetadata(stores: AppStores) async throws -> UUID {
        let workspace = stores.workspace
        let claudeThreadID = try workspace.createThread(agentCLI: .claude)
        await stores.activity.recordAgentCLIOutput(
            threadID: claudeThreadID,
            output: "YAAW_SESSION_ID=claude-e2e-001\nYAAW_SESSION_NAME=Claude E2E Session\n")
        try e2eAssert(
            workspace.selectedThread?.displayName == "Claude E2E Session",
            "claude CLI metadata renamed the thread")

        let opencodeThreadID = try workspace.createThread(agentCLI: .opencode)
        await stores.activity.recordAgentCLIOutput(
            threadID: opencodeThreadID,
            output: "YAAW_SESSION_ID=opencode-e2e-001\nYAAW_SESSION_NAME=OpenCode E2E Session\n")
        try e2eAssert(
            workspace.selectedThread?.displayName == "OpenCode E2E Session",
            "opencode CLI metadata renamed the thread")

        let copilotThreadID = try workspace.createThread(agentCLI: .copilot)
        await stores.activity.recordAgentCLIOutput(
            threadID: copilotThreadID,
            output: "YAAW_SESSION_ID=copilot-e2e-001\nYAAW_SESSION_NAME=Copilot E2E Session\n")
        try e2eAssert(
            workspace.selectedThread?.displayName == "Copilot E2E Session",
            "copilot CLI metadata renamed the thread")

        workspace.selectThread(id: claudeThreadID)
        // Reselect codex before the theme/font block so it stays the selection
        // anchor for the launched-app states (matching the pre-rewrite order).
        return claudeThreadID
    }

    // MARK: - Theme + font reloads

    func assertThemeAndFontReloads(stores: AppStores, codexThreadID: UUID) throws {
        let workspace = stores.workspace
        let settings = stores.settings
        workspace.selectThread(id: codexThreadID)

        settings.reloadConfiguration(highContrastFontConfiguration())
        try e2eAssert(
            settings.configuration.themeName == "light-high-contrast",
            "settings reload applied selected built-in theme")
        try e2eAssert(
            settings.resolvedTheme.group == .highContrast,
            "selected theme resolved to high contrast group")
        try e2eAssert(
            settings.resolvedTheme.id == "light-high-contrast",
            "fixed theme ignores the system appearance")

        try assertSystemThemePairings(settings: settings)

        settings.reloadConfiguration(highContrastFontConfiguration())
        try assertFontsApplied(settings: settings)
        try e2eAssert(
            workspace.selectedThread?.id == codexThreadID,
            "appearance settings reload preserved selected thread")
    }

    private func assertSystemThemePairings(settings: SettingsStore) throws {
        settings.reloadConfiguration(YAAWConfiguration(theme: ThemeSettings(active: "system")))
        settings.updateSystemAppearance(isDark: false)
        try e2eAssert(
            settings.resolvedTheme.id == "macos-light",
            "system mode resolved the light pairing in the light appearance")
        settings.updateSystemAppearance(isDark: true)
        try e2eAssert(
            settings.resolvedTheme.id == "macos-dark",
            "system mode resolved the dark pairing in the dark appearance")
        settings.reloadConfiguration(
            YAAWConfiguration(
                theme: ThemeSettings(active: "system", light: "solarized-light", dark: "dracula")))
        settings.updateSystemAppearance(isDark: false)
        try e2eAssert(
            settings.resolvedTheme.id == "solarized-light",
            "system mode honored a custom light pairing")
        settings.updateSystemAppearance(isDark: true)
        try e2eAssert(
            settings.resolvedTheme.id == "dracula", "system mode honored a custom dark pairing")
    }

    private func assertFontsApplied(settings: SettingsStore) throws {
        let fonts = settings.configuration.fonts
        try e2eAssert(
            fonts.interfaceFamily == "Avenir Next", "reload applied interface font family")
        try e2eAssert(fonts.interfaceSize == 14, "reload applied interface font size")
        try e2eAssert(fonts.editorFamily == "SF Mono", "reload applied editor font family")
        try e2eAssert(fonts.editorSize == 15, "reload applied editor font size")
        try e2eAssert(
            fonts.terminalFamily == "JetBrains Mono", "reload applied terminal font family")
        try e2eAssert(fonts.terminalSize == 16, "reload applied terminal font size")
    }

    private func highContrastFontConfiguration() -> YAAWConfiguration {
        YAAWConfiguration(
            theme: ThemeSettings(active: "light-high-contrast"),
            fonts: FontSettings(
                interfaceFamily: "Avenir Next", interfaceSize: 14, editorFamily: "SF Mono",
                editorSize: 15, terminalFamily: "JetBrains Mono", terminalSize: 16))
    }
}
