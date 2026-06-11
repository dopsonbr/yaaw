import AppKit
import SwiftUI
import YAAWKit
import YAAWRenderProtocol

/// Root composition: the chrome toolbar + the `WorkspaceSplitView` regions
/// (sidebar / main / right / bottom). A thin consumer of the Chunk E stores —
/// it dispatches to `WorkspaceStore`/`LayoutStore`/`RightPanelStore` rather than
/// the old god `AppModel`. The render surfaces composite via `RenderHostClient`
/// (held as a `@StateObject` so helpers persist for the app's lifetime).
struct RootView: View {
    let stores: AppStores
    @ObservedObject var renderHostClient: RenderHostClient
    let externalOpenWorkspace: ExternalOpenWorkspace
    let onInstallLatestRelease: () -> Void
    let onOpenSettings: () -> Void

    @State private var isShowingUpdateConfirmation = false

    private var workspace: WorkspaceStore { stores.workspace }
    private var layout: LayoutStore { stores.layout }
    private var settings: SettingsStore { stores.settings }

    var body: some View {
        workspaceContent
            .toolbar { chromeToolbar }
            .background(dracula(.background))
            .foregroundStyle(dracula(.foreground))
            .font(settings.configuration.fonts.interfaceFont())
            .environment(\.fontSettings, settings.configuration.fonts)
            .environment(\.appTheme, settings.resolvedTheme)
            .environment(\.colorScheme, settings.resolvedTheme.swiftUIColorScheme)
            .onAppear {
                renderHostClient.rendering = terminalRendering
                renderHostClient.onKeyboardShortcut = { key, modifiers in
                    handleForwardedTerminalShortcut(key: key, modifierRawValues: modifiers)
                }
                renderHostClient.onSurfaceEvent = handleSurfaceEvent(role:event:)
            }
            .onChange(of: settings.resolvedTheme.id) {
                renderHostClient.applyRenderingToAll(terminalRendering)
            }
            .background(WindowTitleUpdater(title: workspace.windowTitle).frame(width: 0, height: 0))
            .confirmationDialog(
                "Install the latest release?",
                isPresented: $isShowingUpdateConfirmation,
                titleVisibility: .visible
            ) {
                Button("Install Latest Release", role: .destructive, action: onInstallLatestRelease)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "The app will open Terminal to run the release installer, then quit so the installed app can be replaced."
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            ) { _ in
                renderHostClient.shutdownAll()
            }
    }

    // MARK: - Chrome toolbar

    @ToolbarContentBuilder
    private var chromeToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: layout.toggleSidebarCollapsed) {
                Image(systemName: IconRole.sidebar.icon.systemSymbolName)
            }
            .help(layout.layoutState.isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            .accessibilityIdentifier("toggle-sidebar-button")

            Button(action: workspace.navigateBack) {
                Image(systemName: IconRole.navigateBack.icon.systemSymbolName)
            }
            .help("Back")
            .accessibilityIdentifier("navigate-back-button")

            Button(action: workspace.navigateForward) {
                Image(systemName: IconRole.navigateForward.icon.systemSymbolName)
            }
            .help("Forward")
            .accessibilityIdentifier("navigate-forward-button")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            externalOpenToolbarButton
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                isShowingUpdateConfirmation = true
            } label: {
                Image(systemName: IconRole.installUpdate.icon.systemSymbolName)
            }
            .help("Install latest release")
            .accessibilityIdentifier("install-latest-release-button")

            Button(action: layout.toggleWorkspaceSwap) {
                if layout.layoutState.isWorkspaceSwapped {
                    Image(systemName: IconRole.workspaceSwap.icon.systemSymbolName)
                        .foregroundStyle(dracula(.pink))
                } else {
                    Image(systemName: IconRole.workspaceSwap.icon.systemSymbolName)
                }
            }
            .help("Swap main and right panels")
            .accessibilityIdentifier("swap-main-and-right-panels-button")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: layout.toggleRightPanelCollapsed) {
                Image(systemName: IconRole.rightSidebar.icon.systemSymbolName)
            }
            .help(
                layout.layoutState.isRightPanelCollapsed
                    ? "Expand right-side area" : "Collapse right-side area"
            )
            .accessibilityIdentifier("toggle-right-panel-button")

            Button(action: onOpenSettings) {
                Image(systemName: IconRole.settings.icon.systemSymbolName)
            }
            .help("Settings")
            .accessibilityIdentifier("open-settings-button")
        }
    }

    /// Native split button: the label is the primary action, the chevron opens
    /// the per-tool menu.
    private var externalOpenToolbarButton: some View {
        Menu {
            ForEach(availableExternalOpenTools) { tool in
                Button {
                    openSelectedDirectoryExternally(tool)
                } label: {
                    Label {
                        Text(tool.displayName)
                    } icon: {
                        ExternalOpenToolIcon(
                            tool: tool, icon: externalOpenWorkspace.icon(for: tool))
                    }
                }
            }
        } label: {
            ExternalOpenToolIcon(
                tool: defaultExternalOpenTool,
                icon: defaultExternalOpenTool.flatMap(externalOpenWorkspace.icon(for:))
            )
        } primaryAction: {
            openSelectedDirectoryWithDefaultExternalTool()
        }
        .disabled(availableExternalOpenTools.isEmpty)
        .help(
            defaultExternalOpenTool.map { "Open in \($0.displayName)" }
                ?? "No external open destination available"
        )
        .accessibilityLabel(
            defaultExternalOpenTool.map { "Open in \($0.displayName)" }
                ?? "No external open destination available"
        )
        .accessibilityIdentifier("external-open-menu-button")
    }

    // MARK: - Regions

    private var workspaceContent: some View {
        WorkspaceSplitView(
            layoutState: layout.layoutState,
            isSidebarCollapsed: layout.layoutState.isSidebarCollapsed,
            isRightPanelCollapsed: layout.layoutState.isRightPanelCollapsed,
            isBottomTerminalExpanded: layout.isBottomTerminalExpanded,
            theme: settings.resolvedTheme,
            onResize: updateLayoutFromSplitView,
            onReset: resetSplitDivider
        ) {
            sidebarRegion
        } main: {
            mainWorkspaceRegion
        } right: {
            rightSideRegion
        } bottom: {
            BottomTerminalBar(
                client: renderHostClient,
                isExpanded: layout.isBottomTerminalExpanded,
                role: workspace.selectedThreadID.map { .bottom(threadID: $0) },
                fonts: settings.configuration.fonts,
                onToggle: layout.toggleBottomTerminal,
                onAppearExpanded: {
                    if let id = workspace.selectedThreadID {
                        workspace.activateTerminal(role: .bottom(threadID: id))
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var mainWorkspaceRegion: some View {
        if layout.layoutState.isWorkspaceSwapped {
            rightToolPanelRegion
        } else {
            agentCLIRegion
        }
    }

    private var agentCLIRegion: some View {
        MainWorkspaceView(
            workspace: workspace,
            activity: stores.activity,
            renderHostClient: renderHostClient,
            fonts: settings.configuration.fonts
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var rightSideRegion: some View {
        if layout.layoutState.isRightPanelCollapsed {
            CollapsedPanelRail(
                systemImage: IconRole.rightSidebar.icon.systemSymbolName,
                accessibilityLabel: "Expand right-side area",
                action: layout.toggleRightPanelCollapsed
            )
            .frame(width: 44)
        } else if layout.layoutState.isWorkspaceSwapped {
            agentCLIRegion
        } else {
            rightToolPanelRegion
        }
    }

    @ViewBuilder
    private var sidebarRegion: some View {
        if layout.layoutState.isSidebarCollapsed {
            CollapsedPanelRail(
                systemImage: IconRole.sidebar.icon.systemSymbolName,
                accessibilityLabel: "Expand sidebar",
                action: layout.toggleSidebarCollapsed
            )
            .frame(width: 44)
        } else {
            SidebarView(
                workspace: workspace,
                activity: stores.activity,
                layout: layout,
                settings: settings
            )
        }
    }

    private var rightToolPanelRegion: some View {
        RightPanelView(
            workspace: workspace,
            activity: stores.activity,
            rightPanel: stores.rightPanel,
            renderHostClient: renderHostClient,
            settings: settings,
            defaultExternalEditorTool: defaultExternalEditorTool,
            onOpenFileExternally: openFileExternally,
            onCopyPath: copyFileBrowserPath
        )
    }

    // MARK: - Layout resize

    private func updateLayoutFromSplitView(
        _ splitLayout: WorkspaceSplitLayout, phase: WorkspaceSplitResizePhase
    ) {
        layout.setSidebarWidth(splitLayout.sidebarWidth, persist: false)
        layout.setRightPanelWidth(splitLayout.rightPanelWidth, persist: false)
        layout.setGlobalTerminalHeight(
            splitLayout.globalTerminalHeight,
            availableWindowHeight: splitLayout.availableWindowHeight,
            persist: false
        )
        if phase == .ended {
            layout.commitLayoutResize()
        }
    }

    private func resetSplitDivider(_ divider: WorkspaceSplitDivider) {
        switch divider {
        case .sidebar:
            layout.resetSidebarWidth()
        case .rightPanel:
            layout.resetRightPanelWidth()
        case .bottomTerminal:
            layout.resetGlobalTerminalHeight()
        }
    }

    // MARK: - External open

    private var availableExternalOpenTools: [ExternalOpenToolID] {
        externalOpenWorkspace.availableTools(settings: settings.configuration.tools.externalOpen)
    }

    private var defaultExternalOpenTool: ExternalOpenToolID? {
        externalOpenWorkspace.defaultTool(settings: settings.configuration.tools.externalOpen)
    }

    private var defaultExternalEditorTool: ExternalOpenToolID? {
        externalOpenWorkspace.defaultEditorTool(settings: settings.configuration.tools.externalOpen)
    }

    private func openSelectedDirectoryWithDefaultExternalTool() {
        guard let tool = defaultExternalOpenTool else { return }
        openSelectedDirectoryExternally(tool)
    }

    private func openSelectedDirectoryExternally(_ tool: ExternalOpenToolID) {
        guard let target = workspace.selectedExternalOpenDirectoryTarget else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private func openFileExternally(_ entry: FileBrowserEntry, tool: ExternalOpenToolID) {
        guard
            let target = stores.rightPanel.fileBrowserExternalOpenTarget(
                relativePath: entry.relativePath, isDirectory: entry.isDirectory)
        else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private func copyFileBrowserPath(_ entry: FileBrowserEntry, style: FileBrowserCopyPathStyle) {
        let value: String?
        switch style {
        case .relative:
            value = entry.relativePath
        case .full:
            value = stores.rightPanel.fileBrowserURL(relativePath: entry.relativePath)?.path
        }
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: - Render rendering config

    private var terminalRendering: IsolatedTerminalRendering {
        let fonts = settings.configuration.fonts
        return IsolatedTerminalRendering(
            themeID: settings.resolvedTheme.id,
            terminalFontFamily: fonts.terminalFamily,
            terminalFontSize: fonts.terminalSize,
            terminalFontLigatures: fonts.ligatures,
            appShortcutSignatures: terminalAppShortcutSignatures
        )
    }

    private var terminalAppShortcutSignatures: [String] {
        var signatures = KeyboardShortcutAction.allCases.compactMap { action -> String? in
            guard action.scope != .settings,
                settings.isKeyboardShortcutEnabled(for: action)
            else { return nil }
            return settings.keyboardShortcutDefinition(for: action).signature
        }
        signatures.append("command+q")
        return Array(Set(signatures)).sorted()
    }

    // MARK: - Surface events / forwarded shortcuts

    private func handleSurfaceEvent(role: RenderSurfaceRole, event: RenderEvent) {
        guard case .project(let threadID) = role else { return }
        let activity = stores.activity
        switch event {
        case .title(let title):
            Task { await activity.recordAgentCLITerminalTitle(threadID: threadID, title: title) }
        case .notification(let title, let body):
            activity.recordAgentTerminalNotification(threadID: threadID, title: title, body: body)
        case .exited:
            activity.recordAgentTerminalClosed(threadID: threadID)
        case .commandFinished(let exitCode, _):
            activity.recordAgentCommandFinished(threadID: threadID, exitCode: exitCode)
        default:
            break
        }
    }

    private func handleForwardedTerminalShortcut(key: String, modifierRawValues: [String]) {
        let modifiers = modifierRawValues.compactMap(KeyboardShortcutModifier.init(rawValue:))
        guard modifiers.count == modifierRawValues.count,
            let signature = KeyboardShortcutDefinition(key: key, modifiers: modifiers).signature
        else { return }

        if signature == "command+q" {
            NSApplication.shared.terminate(nil)
            return
        }

        guard
            let action = KeyboardShortcutAction.allCases.first(where: { action in
                guard action.scope != .settings,
                    settings.isKeyboardShortcutEnabled(for: action)
                else { return false }
                return settings.keyboardShortcutDefinition(for: action).signature == signature
            })
        else { return }

        performForwardedTerminalShortcut(action)
    }

    private func performForwardedTerminalShortcut(_ action: KeyboardShortcutAction) {
        AppCommands.perform(
            action,
            stores: stores,
            onOpenSettings: onOpenSettings
        )
    }
}

/// Toolbar leaf icon for an external-open tool (bundled app icon or SF Symbol).
struct ExternalOpenToolIcon: View {
    let tool: ExternalOpenToolID?
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else if let tool {
            Image(systemName: tool.systemSymbolName)
                .font(.system(size: 14, weight: ChromeMetrics.glyphWeight))
                .foregroundStyle(dracula(.cyan))
        } else {
            Image(systemName: IconRole.openDocument.icon.systemSymbolName)
                .font(.system(size: 14, weight: ChromeMetrics.glyphWeight))
                .foregroundStyle(dracula(.comment))
        }
    }
}
