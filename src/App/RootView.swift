// swiftlint:disable file_length
import AppKit
import SwiftUI
import YAAWKit

enum FileBrowserCopyPathStyle {
    case relative
    case full
}

struct RootView: View {
    @ObservedObject var model: AppModel
    let externalOpenWorkspace: ExternalOpenWorkspace
    let onInstallLatestRelease: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var isShowingUpdateConfirmation = false
    // Shared across all terminal panes and stable for the app's lifetime, so
    // isolated-terminal helpers persist while their thread is live even as panes
    // mount/unmount on thread switches.
    @StateObject private var terminalRuntime = IsolatedToolRuntime()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    AppChromeHeader(
                        title: model.windowTitle,
                        isSidebarCollapsed: model.layoutState.isSidebarCollapsed,
                        isRightPanelCollapsed: model.layoutState.isRightPanelCollapsed,
                        isWorkspaceSwapped: model.layoutState.isWorkspaceSwapped,
                        onToggleSidebar: model.toggleSidebarCollapsed,
                        onToggleRightPanel: model.toggleRightPanelCollapsed,
                        onToggleWorkspaceSwap: model.toggleWorkspaceSwap,
                        onNavigateBack: model.navigateBack,
                        onNavigateForward: model.navigateForward,
                        fonts: model.configuration.fonts,
                        externalOpenTools: availableExternalOpenTools,
                        defaultExternalOpenTool: defaultExternalOpenTool,
                        externalOpenIcon: externalOpenWorkspace.icon(for:),
                        onOpenDefaultExternal: openSelectedDirectoryWithDefaultExternalTool,
                        onOpenExternalTool: openSelectedDirectoryExternally,
                        onInstallLatestRelease: { isShowingUpdateConfirmation = true },
                        onOpenSettings: { openWindow(id: YAAWApp.settingsWindowID) }
                    )
                }
                .frame(height: 44)
                .background(dracula(.background))

                Divider()
                    .overlay(dracula(.currentLine))

                workspaceContent()
            }
        }
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
        .font(model.configuration.fonts.interfaceFont())
        .environment(\.fontSettings, model.configuration.fonts)
        .environment(\.appTheme, model.configuration.resolvedTheme)
        .environment(\.colorScheme, model.configuration.resolvedTheme.swiftUIColorScheme)
        .environmentObject(terminalRuntime)
        .onAppear {
            // Tearing down a terminal kills only its isolated helper — never the
            // app or sibling terminals (the user's "kill one thread" capability).
            model.onTerminalTerminated = { [terminalRuntime] role in
                terminalRuntime.terminalShutdown(instanceID: role.isolatedInstanceID)
            }
            terminalRuntime.onKeyboardShortcut = { key, modifiers in
                handleForwardedTerminalShortcut(key: key, modifierRawValues: modifiers)
            }
        }
        .background(WindowTitleUpdater(title: model.windowTitle).frame(width: 0, height: 0))
        .confirmationDialog(
            "Install the latest release?",
            isPresented: $isShowingUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Install Latest Release", role: .destructive) {
                onInstallLatestRelease()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The app will open Terminal to run the release installer, then quit so the installed app can be replaced."
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            terminalRuntime.shutdownAllHosts()
        }
    }

    private var selectedBottomTerminalRequest: TerminalLaunchRequest? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        return model.terminalLaunchRequest(for: .bottom(threadID: selectedThreadID))
    }

    private var terminalAppShortcutSignatures: [String] {
        var signatures = KeyboardShortcutAction.allCases.compactMap { action -> String? in
            guard action.scope != .settings,
                model.isKeyboardShortcutEnabled(for: action)
            else { return nil }
            return model.keyboardShortcutDefinition(for: action).signature
        }
        signatures.append("command+q")
        return Array(Set(signatures)).sorted()
    }

    private var availableExternalOpenTools: [ExternalOpenToolID] {
        externalOpenWorkspace.availableTools(settings: model.configuration.tools.externalOpen)
    }

    private var defaultExternalOpenTool: ExternalOpenToolID? {
        externalOpenWorkspace.defaultTool(settings: model.configuration.tools.externalOpen)
    }

    private var defaultExternalEditorTool: ExternalOpenToolID? {
        externalOpenWorkspace.defaultEditorTool(settings: model.configuration.tools.externalOpen)
    }

    private func openSelectedDirectoryWithDefaultExternalTool() {
        guard let tool = defaultExternalOpenTool else { return }
        openSelectedDirectoryExternally(tool)
    }

    private func openSelectedDirectoryExternally(_ tool: ExternalOpenToolID) {
        guard let target = model.selectedExternalOpenDirectoryTarget else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private func openFileExternally(_ entry: FileBrowserEntry, tool: ExternalOpenToolID) {
        guard
            let target = model.fileBrowserExternalOpenTarget(
                relativePath: entry.relativePath,
                isDirectory: entry.isDirectory
            )
        else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private func copyFileBrowserPath(_ entry: FileBrowserEntry, style: FileBrowserCopyPathStyle) {
        let value: String?
        switch style {
        case .relative:
            value = entry.relativePath
        case .full:
            value = model.fileBrowserURL(relativePath: entry.relativePath)?.path
        }
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func workspaceContent() -> some View {
        WorkspaceSplitView(
            layoutState: model.layoutState,
            isSidebarCollapsed: model.layoutState.isSidebarCollapsed,
            isRightPanelCollapsed: model.layoutState.isRightPanelCollapsed,
            isBottomTerminalExpanded: model.isBottomTerminalExpanded,
            theme: model.configuration.resolvedTheme,
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
                isExpanded: model.isBottomTerminalExpanded,
                request: selectedBottomTerminalRequest,
                fonts: model.configuration.fonts,
                appShortcutSignatures: terminalAppShortcutSignatures,
                onToggle: model.toggleBottomTerminal,
                onAppearExpanded: {
                    model.activateSelectedBottomTerminal()
                }
            )
        }
    }

    @ViewBuilder
    private var mainWorkspaceRegion: some View {
        if model.layoutState.isWorkspaceSwapped {
            rightToolPanelRegion
        } else {
            agentCLIRegion
        }
    }

    @ViewBuilder
    private var agentCLIRegion: some View {
        MainWorkspaceView(model: model, appShortcutSignatures: terminalAppShortcutSignatures)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var rightSideRegion: some View {
        if model.layoutState.isRightPanelCollapsed {
            CollapsedPanelRail(
                systemImage: IconRole.rightSidebar.icon.systemSymbolName,
                accessibilityLabel: "Expand right-side area",
                action: model.toggleRightPanelCollapsed
            )
            .frame(width: 44)
        } else if model.layoutState.isWorkspaceSwapped {
            agentCLIRegion
        } else {
            rightToolPanelRegion
        }
    }

    @ViewBuilder
    private var sidebarRegion: some View {
        if model.layoutState.isSidebarCollapsed {
            CollapsedPanelRail(
                systemImage: IconRole.sidebar.icon.systemSymbolName,
                accessibilityLabel: "Expand sidebar",
                action: model.toggleSidebarCollapsed
            )
            .frame(width: 44)
        } else {
            SidebarView(model: model)
        }
    }

    @ViewBuilder
    private var rightToolPanelRegion: some View {
        RightPanelView(
            model: model,
            defaultExternalEditorTool: defaultExternalEditorTool,
            appShortcutSignatures: terminalAppShortcutSignatures,
            onOpenFileExternally: openFileExternally,
            onCopyPath: copyFileBrowserPath
        )
    }

    private func updateLayoutFromSplitView(
        _ layout: WorkspaceSplitLayout, phase: WorkspaceSplitResizePhase
    ) {
        let shouldPersist = phase == .ended
        model.setSidebarWidth(layout.sidebarWidth, persist: false)
        model.setRightPanelWidth(layout.rightPanelWidth, persist: false)
        model.setGlobalTerminalHeight(
            layout.globalTerminalHeight,
            availableWindowHeight: layout.availableWindowHeight,
            persist: false
        )
        if shouldPersist {
            model.commitLayoutResize()
        }
    }

    private func resetSplitDivider(_ divider: WorkspaceSplitDivider) {
        switch divider {
        case .sidebar:
            model.resetSidebarWidth()
        case .rightPanel:
            model.resetRightPanelWidth()
        case .bottomTerminal:
            model.resetGlobalTerminalHeight()
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
                    model.isKeyboardShortcutEnabled(for: action)
                else { return false }
                return model.keyboardShortcutDefinition(for: action).signature == signature
            })
        else { return }

        performForwardedTerminalShortcut(action)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func performForwardedTerminalShortcut(_ action: KeyboardShortcutAction) {
        switch action {
        case .openSettings:
            openWindow(id: YAAWApp.settingsWindowID)
        case .newThread:
            _ = try? model.createThread(agentCLI: nil)
        case .toggleSelectedProjectPinned:
            model.toggleSelectedProjectPinned()
        case .moveSelectedProjectUp:
            model.moveSelectedProject(direction: .up)
        case .moveSelectedProjectDown:
            model.moveSelectedProject(direction: .down)
        case .toggleSelectedProjectExpanded:
            model.toggleSelectedProjectExpanded()
        case .toggleSelectedProjectArchiveExpanded:
            model.toggleSelectedProjectArchiveExpanded()
        case .toggleSelectedThreadPinned:
            model.toggleSelectedThreadPinned()
        case .archiveSelectedThread:
            model.archiveSelectedThread()
        case .unarchiveSelectedThread:
            model.unarchiveSelectedThread()
        case .toggleBottomTerminal:
            model.toggleBottomTerminal()
        case .navigateBack:
            model.navigateBack()
        case .navigateForward:
            model.navigateForward()
        case .previousRightPanelMode:
            model.cycleRightPanelModeBackward()
        case .nextRightPanelMode:
            model.cycleRightPanelModeForward()
        case .selectFilesRightPanelMode:
            model.selectRightPanelMode(.files)
        case .selectGitRightPanelMode:
            model.selectRightPanelMode(.git)
        case .selectNvimRightPanelMode:
            model.selectRightPanelMode(.nvim)
        case .toggleSidebar:
            model.toggleSidebarCollapsed()
        case .toggleRightPanel:
            model.toggleRightPanelCollapsed()
        case .swapMainAndRightPanels:
            model.toggleWorkspaceSwap()
        case .refreshFiles:
            model.refreshSelectedFileBrowser()
        case .openSelectedFileInNvim:
            model.openSelectedFileInNvim()
        case .newProject, .openNvimFilePicker, .openSelectedDirectoryExternalDefault,
            .openSelectedDirectoryInVSCode, .openSelectedDirectoryInVSCodeInsiders,
            .openSelectedDirectoryInSublimeText, .openSelectedDirectoryInZed,
            .openSelectedDirectoryInFinder, .openSelectedDirectoryInTerminal,
            .openSelectedDirectoryInGhostty, .openSelectedDirectoryInXcode,
            .openSelectedDirectoryInWebStorm, .openSelectedFileExternalDefault,
            .openSelectedFileInVSCode, .openSelectedFileInVSCodeInsiders,
            .openSelectedFileInSublimeText, .openSelectedFileInZed,
            .openSelectedFileInFinder, .openSelectedFileInTerminal,
            .openSelectedFileInGhostty, .openSelectedFileInXcode,
            .openSelectedFileInWebStorm, .saveSettings, .reloadSettings,
            .revertSettings, .openSettingsExternal:
            break
        }
    }
}

private struct AppChromeHeader: View {
    let title: String
    let isSidebarCollapsed: Bool
    let isRightPanelCollapsed: Bool
    let isWorkspaceSwapped: Bool
    let onToggleSidebar: () -> Void
    let onToggleRightPanel: () -> Void
    let onToggleWorkspaceSwap: () -> Void
    let onNavigateBack: () -> Void
    let onNavigateForward: () -> Void
    let fonts: FontSettings
    let externalOpenTools: [ExternalOpenToolID]
    let defaultExternalOpenTool: ExternalOpenToolID?
    let externalOpenIcon: (ExternalOpenToolID) -> NSImage?
    let onOpenDefaultExternal: () -> Void
    let onOpenExternalTool: (ExternalOpenToolID) -> Void
    let onInstallLatestRelease: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Leading group: sidebar toggle + navigation.
            HStack(spacing: 2) {
                ChromeIconButton(
                    systemImage: IconRole.sidebar.icon.systemSymbolName,
                    help: isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar",
                    action: onToggleSidebar
                )

                ChromeIconButton(
                    systemImage: IconRole.navigateBack.icon.systemSymbolName,
                    tint: dracula(.comment),
                    help: "Back",
                    action: onNavigateBack
                )

                ChromeIconButton(
                    systemImage: IconRole.navigateForward.icon.systemSymbolName,
                    tint: dracula(.comment),
                    help: "Forward",
                    action: onNavigateForward
                )
            }

            Divider()
                .overlay(dracula(.currentLine))
                .frame(height: 24)

            Text(title)
                .font(fonts.interfaceFont(sizeOffset: 2, weight: .semibold))
                .foregroundStyle(dracula(.foreground))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Trailing group: tools + window controls.
            HStack(spacing: 2) {
                ExternalOpenSplitButton(
                    tools: externalOpenTools,
                    defaultTool: defaultExternalOpenTool,
                    icon: externalOpenIcon,
                    onOpenDefault: onOpenDefaultExternal,
                    onOpenTool: onOpenExternalTool
                )

                ChromeIconButton(
                    systemImage: IconRole.installUpdate.icon.systemSymbolName,
                    help: "Install latest release",
                    action: onInstallLatestRelease
                )
                .accessibilityIdentifier("install-latest-release-button")

                ChromeIconButton(
                    systemImage: IconRole.settings.icon.systemSymbolName,
                    help: "Settings",
                    action: onOpenSettings
                )
                .accessibilityIdentifier("open-settings-button")

                ChromeIconButton(
                    systemImage: IconRole.workspaceSwap.icon.systemSymbolName,
                    tint: isWorkspaceSwapped ? dracula(.pink) : dracula(.foreground),
                    help: "Swap main and right panels",
                    action: onToggleWorkspaceSwap
                )
                .accessibilityIdentifier("swap-main-and-right-panels-button")

                ChromeIconButton(
                    systemImage: IconRole.rightSidebar.icon.systemSymbolName,
                    help: isRightPanelCollapsed
                        ? "Expand right-side area" : "Collapse right-side area",
                    action: onToggleRightPanel
                )
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
    }
}

private struct ExternalOpenSplitButton: View {
    let tools: [ExternalOpenToolID]
    let defaultTool: ExternalOpenToolID?
    let icon: (ExternalOpenToolID) -> NSImage?
    let onOpenDefault: () -> Void
    let onOpenTool: (ExternalOpenToolID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpenDefault) {
                ExternalOpenToolIcon(tool: defaultTool, icon: defaultTool.flatMap(icon))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(defaultTool == nil)
            .help(
                defaultTool.map { "Open in \($0.displayName)" }
                    ?? "No external open destination available"
            )
            .accessibilityLabel(
                defaultTool.map { "Open in \($0.displayName)" }
                    ?? "No external open destination available"
            )
            .accessibilityIdentifier("external-open-default-button")

            Menu {
                ForEach(tools) { tool in
                    Button {
                        onOpenTool(tool)
                    } label: {
                        Label {
                            Text(tool.displayName)
                        } icon: {
                            ExternalOpenToolIcon(tool: tool, icon: icon(tool))
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: ChromeMetrics.glyphWeight))
                    .frame(width: 26, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(tools.isEmpty)
            .help("Choose external open destination")
            .accessibilityLabel("Choose external open destination")
            .accessibilityIdentifier("external-open-menu-button")
        }
        .background(dracula(.currentLine).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .stroke(dracula(.comment).opacity(0.22), lineWidth: 1)
        )
    }
}

private struct ExternalOpenToolIcon: View {
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

struct AgentCLIIcon: View {
    let agentCLI: AgentCLIKind

    var body: some View {
        if let image = bundledImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: agentCLI.fallbackSystemSymbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dracula(.cyan))
        }
    }

    private var bundledImage: NSImage? {
        for fileExtension in agentCLI.brandIconResourceExtensions {
            for bundle in Self.resourceBundles {
                if let image = image(
                    in: bundle,
                    fileExtension: fileExtension,
                    subdirectory: nil
                ) {
                    return image
                }

                if let image = image(
                    in: bundle,
                    fileExtension: fileExtension,
                    subdirectory: "AgentIcons"
                ) {
                    return image
                }
            }
        }
        return nil
    }

    private static var resourceBundles: [Bundle] {
        var bundles = [Bundle.main]
        if let resourcesURL = Bundle.main.resourceURL {
            let swiftPMBundleURL = resourcesURL.appendingPathComponent(
                "YAAW_YAAW.bundle",
                isDirectory: true
            )
            if let bundle = Bundle(url: swiftPMBundleURL) {
                bundles.append(bundle)
            }
        }
        return bundles
    }

    private func image(
        in bundle: Bundle,
        fileExtension: String,
        subdirectory: String?
    ) -> NSImage? {
        guard
            let url = bundle.url(
                forResource: agentCLI.brandIconResourceName,
                withExtension: fileExtension,
                subdirectory: subdirectory
            )
        else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var isProjectSheetPresented = false
    @State private var threadSheetProject: Project?
    @State private var renameThread: AgentThread?
    @State private var isArchiveExpanded = false
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: "Projects",
                    actionTitle: "New",
                    systemImage: IconRole.newProject.icon.systemSymbolName
                ) {
                    isProjectSheetPresented = true
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.activeProjects) { project in
                            ProjectSidebarSection(
                                model: model,
                                project: project,
                                onNewThread: {
                                    threadSheetProject = project
                                },
                                onRenameThread: { thread in
                                    renameThread = thread
                                }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
            }

            Spacer(minLength: 0)

            GlobalArchivedThreadsSection(
                model: model,
                isExpanded: $isArchiveExpanded,
                onRenameThread: { thread in
                    renameThread = thread
                }
            )

            Button {
                model.toggleSidebarCollapsed()
            } label: {
                Label("Collapse Sidebar", systemImage: IconRole.sidebar.icon.systemSymbolName)
                    .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.comment))
        }
        .padding(18)
        .background(dracula(.background))
        .sheet(isPresented: $isProjectSheetPresented) {
            ProjectCreationSheet(model: model)
        }
        .sheet(item: $threadSheetProject) { project in
            ThreadChoiceSheet(model: model, project: project)
        }
        .sheet(item: $renameThread) { thread in
            ThreadRenameSheet(model: model, thread: thread)
        }
    }
}

private struct ProjectSidebarSection: View {
    @ObservedObject var model: AppModel
    let project: Project
    let onNewThread: () -> Void
    let onRenameThread: (AgentThread) -> Void
    @Environment(\.fontSettings) private var fonts
    @State private var hovering = false

    var body: some View {
        let isSelected = model.selectedProjectID == project.id
        let showActions = hovering || isSelected
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SidebarIconButton(
                    systemImage: (model.isProjectExpanded(project.id)
                        ? IconRole.disclosureExpanded : IconRole.disclosureCollapsed).icon
                        .systemSymbolName,
                    help: model.isProjectExpanded(project.id)
                        ? "Collapse project" : "Expand project",
                    weight: .regular
                ) {
                    model.setProjectExpanded(
                        project.id, isExpanded: !model.isProjectExpanded(project.id))
                }

                Button {
                    model.selectProject(id: project.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if project.isPinned {
                                Image(systemName: IconRole.pinned.icon.systemSymbolName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(dracula(.pink))
                            }

                            Text(project.displayName)
                                .font(fonts.interfaceFont(sizeOffset: 1, weight: .semibold))
                                .lineLimit(1)
                        }

                        Text(project.rootDirectory.path)
                            .font(fonts.interfaceFont(sizeOffset: -1))
                            .foregroundStyle(dracula(.comment))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project \(project.displayName)")

                SidebarIconButton(
                    systemImage: IconRole.newThread.icon.systemSymbolName, help: "New thread"
                ) {
                    onNewThread()
                }
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)

                SidebarActionsMenu(help: "Project actions") {
                    Button(project.isPinned ? "Unpin Project" : "Pin Project") {
                        model.toggleProjectPinned(id: project.id)
                    }

                    if model.canArchiveProject(id: project.id) {
                        Button("Archive Project") {
                            model.archiveProject(id: project.id)
                        }
                    }
                }
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                    .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: hovering))
            )
            .padding(.horizontal, ChromeMetrics.rowHInset)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .draggable(project.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let rawID = items.first,
                    let draggedProjectID = UUID(uuidString: rawID)
                else {
                    return false
                }
                model.reorderProject(id: draggedProjectID, before: project.id)
                return true
            }

            if model.isProjectExpanded(project.id) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.activeThreads(for: project.id)) { thread in
                        ActiveThreadRow(
                            model: model,
                            thread: thread,
                            onRenameThread: onRenameThread
                        )
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}

private struct ActiveThreadRow: View {
    @ObservedObject var model: AppModel
    let thread: AgentThread
    let onRenameThread: (AgentThread) -> Void
    @Environment(\.fontSettings) private var fonts
    @State private var hovering = false

    var body: some View {
        let activity = model.threadActivity(for: thread.id)
        let isSelected = model.selectedThreadID == thread.id
        let showActions = hovering || isSelected
        return HStack(spacing: 6) {
            Button {
                model.selectThread(id: thread.id)
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if thread.isPinned {
                                Image(systemName: IconRole.pinned.icon.systemSymbolName)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(dracula(.pink))
                            }

                            Text(thread.displayName)
                                .font(
                                    fonts.interfaceFont(
                                        weight: activity.isUnread ? .semibold : .regular)
                                )
                                .lineLimit(1)
                        }

                        if let preview = activity.preview {
                            Text(preview)
                                .font(fonts.interfaceFont(sizeOffset: -2))
                                .foregroundStyle(
                                    activity.isUnread ? dracula(.yellow) : dracula(.comment)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer()

                    if activity.status == .inactive {
                        ThreadIdleAgeLabel(date: model.lastInteractionDate(for: thread))
                            .frame(minWidth: 32, alignment: .trailing)
                    } else {
                        ThreadActivityIndicator(activity: activity)
                            .frame(width: 16, height: 16)
                    }

                    AgentCLIIcon(agentCLI: thread.agentCLI)
                        .frame(width: 18, height: 18)
                        .help(thread.agentCLI.displayName)
                        .accessibilityLabel(thread.agentCLI.displayName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Thread \(thread.displayName), \(thread.agentCLI.displayName), \(activity.status.rawValue)"
            )

            SidebarActionsMenu(help: "Thread actions") {
                Button("Rename Thread...") {
                    onRenameThread(thread)
                }
                .disabled(!model.canRequestThreadRename(id: thread.id))

                Button(thread.isPinned ? "Unpin Thread" : "Pin Thread") {
                    model.toggleThreadPinned(id: thread.id)
                }

                Button("Archive Thread") {
                    model.archiveThread(id: thread.id)
                }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
        .font(fonts.interfaceFont())
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: hovering))
        )
        .padding(.horizontal, ChromeMetrics.rowHInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ThreadIdleAgeLabel: View {
    let date: Date
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let elapsed = ThreadRelativeTimeFormatter.shortElapsed(since: date, now: context.date)
            Text(elapsed)
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(dracula(.comment))
                .lineLimit(1)
                .help("Inactive for \(elapsed)")
                .accessibilityLabel("Inactive for \(elapsed)")
        }
    }
}

private struct ThreadActivityIndicator: View {
    let activity: ThreadActivityState

    var body: some View {
        switch activity.status {
        case .working:
            ProgressView()
                .controlSize(.small)
                .tint(dracula(.cyan))
                .help("Working")
        case .needsInput:
            Image(
                systemName: activity.isUnread
                    ? "exclamationmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.system(size: ChromeMetrics.statusGlyph, weight: ChromeMetrics.glyphWeight))
            .foregroundStyle(dracula(.yellow))
            .help("Needs input")
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: ChromeMetrics.statusGlyph, weight: ChromeMetrics.glyphWeight))
                .foregroundStyle(dracula(.green))
                .help("Complete")
        case .inactive:
            Image(systemName: "circle")
                .font(.system(size: ChromeMetrics.statusGlyph, weight: ChromeMetrics.glyphWeight))
                .foregroundStyle(dracula(.comment))
                .help("Inactive")
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let actionTitle: String
    let systemImage: String
    let action: () -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        HStack {
            Text(title)
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                .foregroundStyle(dracula(.comment))

            Spacer()

            Button(action: action) {
                Label(actionTitle, systemImage: systemImage)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
            .foregroundStyle(dracula(.cyan))
            .help(actionTitle)
            .accessibilityLabel("\(actionTitle) \(title)")
        }
    }
}

private struct SidebarIconButton: View {
    let systemImage: String
    let help: String
    var weight: Font.Weight = ChromeMetrics.glyphWeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: ChromeMetrics.sidebarButton, height: ChromeMetrics.sidebarButton)
        }
        .buttonStyle(.plain)
        .font(.system(size: ChromeMetrics.sidebarGlyph, weight: weight))
        .foregroundStyle(dracula(.cyan))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SidebarActionsMenu<Content: View>: View {
    let help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: IconRole.moreActions.icon.systemSymbolName)
                .frame(width: ChromeMetrics.sidebarButton, height: ChromeMetrics.sidebarButton)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .font(.system(size: ChromeMetrics.sidebarGlyph, weight: ChromeMetrics.glyphWeight))
        .foregroundStyle(dracula(.cyan))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct GlobalArchivedThreadsSection: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool
    let onRenameThread: (AgentThread) -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: (isExpanded
                            ? IconRole.disclosureExpanded : IconRole.disclosureCollapsed).icon
                            .systemSymbolName
                    )
                    .frame(width: 12)

                    Label("Archived", systemImage: IconRole.archive.icon.systemSymbolName)
                        .labelStyle(.titleAndIcon)

                    Spacer()

                    Text("\(model.archivedProjects.count + model.archivedThreads.count)")
                        .font(fonts.interfaceFont(sizeOffset: -2))
                        .foregroundStyle(dracula(.comment))
                }
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                .foregroundStyle(dracula(.orange))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived")

            if isExpanded {
                if model.archivedProjects.isEmpty && model.archivedThreads.isEmpty {
                    Text("Nothing archived")
                        .font(fonts.interfaceFont(sizeOffset: -1))
                        .foregroundStyle(dracula(.comment))
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.archivedProjects) { project in
                                ArchivedProjectRow(model: model, project: project)
                            }

                            ForEach(model.archivedThreads) { thread in
                                ArchivedThreadRow(
                                    model: model,
                                    thread: thread,
                                    onRenameThread: onRenameThread
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .scrollIndicators(.hidden)
                }
            }
        }
    }
}

private struct ArchivedProjectRow: View {
    @ObservedObject var model: AppModel
    let project: Project
    @Environment(\.fontSettings) private var fonts
    @State private var hovering = false

    var body: some View {
        let isSelected = model.selectedProjectID == project.id
        let showActions = hovering || isSelected
        return HStack(spacing: 8) {
            Button {
                model.unarchiveProject(id: project.id)
            } label: {
                HStack(spacing: 6) {
                    if project.isPinned {
                        Image(systemName: IconRole.pinned.icon.systemSymbolName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(dracula(.pink))
                    }

                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dracula(.comment))

                    Text(project.displayName)
                        .lineLimit(1)

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived project \(project.displayName)")

            SidebarActionsMenu(help: "Archived project actions") {
                Button("Unarchive Project") {
                    model.unarchiveProject(id: project.id)
                }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
        .font(fonts.interfaceFont(sizeOffset: -1))
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: hovering))
        )
        .padding(.horizontal, ChromeMetrics.rowHInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(project.rootDirectory.path)
    }
}

private struct ArchivedThreadRow: View {
    @ObservedObject var model: AppModel
    let thread: AgentThread
    let onRenameThread: (AgentThread) -> Void
    @Environment(\.fontSettings) private var fonts
    @State private var hovering = false

    var body: some View {
        let isSelected = model.selectedThreadID == thread.id
        let showActions = hovering || isSelected
        return HStack(spacing: 8) {
            Button {
                model.selectThread(id: thread.id)
            } label: {
                HStack(spacing: 6) {
                    if thread.isPinned {
                        Image(systemName: IconRole.pinned.icon.systemSymbolName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(dracula(.pink))
                    }

                    Text(thread.displayName)
                        .lineLimit(1)

                    Spacer()

                    AgentCLIIcon(agentCLI: thread.agentCLI)
                        .frame(width: 16, height: 16)
                        .help(thread.agentCLI.displayName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived thread \(thread.displayName)")

            SidebarActionsMenu(help: "Archived thread actions") {
                Button("Rename Thread...") {
                    onRenameThread(thread)
                }
                .disabled(!model.canRequestThreadRename(id: thread.id))

                Button(thread.isPinned ? "Unpin Thread" : "Pin Thread") {
                    model.toggleThreadPinned(id: thread.id)
                }

                Button("Unarchive Thread") {
                    model.unarchiveThread(id: thread.id)
                }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
        .font(fonts.interfaceFont(sizeOffset: -1))
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: hovering))
        )
        .padding(.horizontal, ChromeMetrics.rowHInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(model.projectDisplayName(for: thread.projectID))
    }
}

private struct ProjectCreationSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var path = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Project")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(dracula(.purple))

            VStack(alignment: .leading, spacing: 8) {
                Text("Directory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dracula(.foreground))

                HStack(spacing: 10) {
                    Text(path.isEmpty ? "Select a project directory" : path)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(path.isEmpty ? dracula(.comment) : dracula(.foreground))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(dracula(.currentLine))

                    Button("Choose...") {
                        chooseDirectory()
                    }
                    .controlSize(.large)
                    .accessibilityLabel("Choose project directory")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Display name")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dracula(.foreground))

                TextField("Defaults to selected directory name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .accessibilityLabel("Project display name")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dracula(.red))
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Create") {
                    createProject()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(dracula(.background))
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL =
            path.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = url.lastPathComponent
            }
            errorMessage = nil
        }
    }

    private func createProject() {
        do {
            try model.createProject(
                displayName: displayName,
                rootDirectory: URL(fileURLWithPath: path, isDirectory: true)
            )
            dismiss()
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case AppModelError.emptyProjectName:
            return "Project name is required."
        case AppModelError.missingProjectDirectory(let path):
            return "Directory does not exist: \(path)"
        default:
            return "Project could not be created."
        }
    }
}

private struct ThreadRenameSheet: View {
    @ObservedObject var model: AppModel
    let thread: AgentThread
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var errorMessage: String?
    @Environment(\.fontSettings) private var fonts

    init(model: AppModel, thread: AgentThread) {
        self.model = model
        self.thread = thread
        _displayName = State(initialValue: thread.canonicalSessionName ?? thread.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Thread")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            Text(thread.agentCLI.displayName)
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))

            TextField("Thread name", text: $displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(dracula(.currentLine))
                .foregroundStyle(dracula(.foreground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Thread name")

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Rename") {
                    renameThread()
                }
                .keyboardShortcut(.defaultAction)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(dracula(.red))
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(dracula(.background))
    }

    private func renameThread() {
        do {
            try model.requestThreadRename(id: thread.id, to: displayName)
            dismiss()
        } catch AppModelError.sessionRenameNotSupported {
            errorMessage = "Rename is not available for \(thread.agentCLI.displayName)."
        } catch AppModelError.emptyThreadName {
            errorMessage = "Enter a thread name."
        } catch {
            errorMessage = "Thread could not be renamed."
        }
    }
}

private struct MainWorkspaceView: View {
    @ObservedObject var model: AppModel
    let appShortcutSignatures: [String]
    private let capturePoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var isSessionLinkSheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .missing(let path) = model.selectedThreadWorkingDirectoryState {
                MissingDirectoryBanner(
                    title: "Working directory is missing",
                    path: path,
                    message:
                        "Project tools are paused until this directory exists again or a new thread uses another path."
                )
            } else if case .missing(let path) = model.selectedProjectDirectoryState {
                MissingDirectoryBanner(
                    title: "Project directory is missing",
                    path: path,
                    message:
                        "Create a new project or restore the directory before creating more threads here."
                )
            }

            Group {
                if model.selectedThreadRequiresSessionLink {
                    SessionLinkRequiredView(
                        model: model,
                        onLink: { isSessionLinkSheetPresented = true },
                        onStartNew: startNewSelectedSession
                    )
                } else {
                    TerminalPlaceholderView(
                        request: selectedProjectTerminalRequest,
                        unavailableMessage: selectedProjectTerminalUnavailableMessage,
                        fonts: model.configuration.fonts,
                        appShortcutSignatures: appShortcutSignatures,
                        onTitleChange: { role, title in
                            if case .project(let threadID) = role {
                                model.recordAgentCLITerminalTitle(threadID: threadID, title: title)
                            }
                        },
                        onDesktopNotification: { role, title, body in
                            if case .project(let threadID) = role {
                                model.recordAgentTerminalNotification(
                                    threadID: threadID, title: title, body: body)
                            }
                        },
                        onFocusChange: { role, focused in
                            if case .project(let threadID) = role {
                                model.recordAgentTerminalFocus(threadID: threadID, focused: focused)
                            }
                        },
                        onClose: { role in
                            if case .project(let threadID) = role {
                                model.recordAgentTerminalClosed(threadID: threadID)
                            }
                        },
                        onCommandFinished: { role, exitCode in
                            if case .project(let threadID) = role {
                                model.recordAgentCommandFinished(
                                    threadID: threadID, exitCode: exitCode)
                            }
                        }
                    )
                    .id(model.selectedThreadID)
                    .onAppear {
                        model.activateSelectedProjectTerminal()
                    }
                }
            }
            .onReceive(capturePoll) { _ in
                model.pollAgentCLIStateInBackground()
            }
        }
        .padding(8)
        .background(dracula(.background))
        .sheet(isPresented: $isSessionLinkSheetPresented) {
            SessionLinkSheet(
                model: model,
                onResume: {
                    isSessionLinkSheetPresented = false
                    model.activateSelectedProjectTerminal()
                },
                onStartNew: {
                    isSessionLinkSheetPresented = false
                    startNewSelectedSession()
                }
            )
        }
    }

    private var selectedProjectTerminalRequest: TerminalLaunchRequest? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        return model.terminalLaunchRequest(for: .project(threadID: selectedThreadID))
    }

    private var selectedProjectTerminalUnavailableMessage: String {
        if case .missing(let path) = model.selectedThreadWorkingDirectoryState {
            return "Missing working directory: \(path)"
        }
        return model.projectTerminal.placeholderText
    }

    private func startNewSelectedSession() {
        guard let selectedThreadID = model.selectedThreadID else { return }
        model.startNewSessionForUnlinkedThread(threadID: selectedThreadID)
        model.activateSelectedProjectTerminal()
    }
}

private struct SessionLinkRequiredView: View {
    @ObservedObject var model: AppModel
    let onLink: () -> Void
    let onStartNew: () -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.selectedThread?.displayName ?? "Thread")
                .font(fonts.interfaceFont(sizeOffset: 5, weight: .semibold))
                .foregroundStyle(dracula(.foreground))
                .lineLimit(1)

            Text("Session link required")
                .font(fonts.interfaceFont(sizeOffset: 1, weight: .semibold))
                .foregroundStyle(dracula(.purple))

            HStack(spacing: 10) {
                Button("Link Session...") {
                    onLink()
                }
                .keyboardShortcut(.defaultAction)

                Button("Start New Session") {
                    onStartNew()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
    }
}

private struct SessionLinkSheet: View {
    @ObservedObject var model: AppModel
    let onResume: () -> Void
    let onStartNew: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link Session")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            if candidates.isEmpty {
                Text("No matching sessions found.")
                    .font(fonts.interfaceFont())
                    .foregroundStyle(dracula(.comment))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            HStack(spacing: 10) {
                Button("Start New Session") {
                    onStartNew()
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(dracula(.background))
    }

    private var candidates: [SessionLinkCandidate] {
        guard let selectedThreadID = model.selectedThreadID else { return [] }
        return model.sessionLinkCandidates(for: selectedThreadID)
    }

    private func candidateRow(_ candidate: SessionLinkCandidate) -> some View {
        Button {
            guard let selectedThreadID = model.selectedThreadID else { return }
            model.linkSession(threadID: selectedThreadID, candidate: candidate)
            onResume()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.displayName)
                        .font(fonts.interfaceFont(weight: .semibold))
                        .foregroundStyle(dracula(.foreground))
                        .lineLimit(1)

                    Text(candidate.identity)
                        .font(fonts.interfaceFont(sizeOffset: -2))
                        .foregroundStyle(dracula(.comment))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(candidate.updatedAt.map(Self.shortDate) ?? candidate.source)
                        .font(fonts.interfaceFont(sizeOffset: -2))
                        .foregroundStyle(dracula(.comment))
                        .lineLimit(1)
                }

                Spacer()

                Text("Link & Resume")
                    .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                    .foregroundStyle(dracula(.cyan))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dracula(.currentLine))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Link \(candidate.displayName)")
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct RightPanelView: View {
    @ObservedObject var model: AppModel
    let defaultExternalEditorTool: ExternalOpenToolID?
    let appShortcutSignatures: [String]
    let onOpenFileExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void
    @StateObject private var isolatedToolRuntime = IsolatedToolRuntime()
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.selectedRightPanelState.tabs) { tab in
                        rightPanelTabButton(tab)
                    }

                    Menu {
                        Button {
                            model.selectRightPanelTab(id: RightPanelTab.filesID)
                        } label: {
                            Label(
                                "Files",
                                systemImage: IconRole.rightPanelMode(.files).icon.systemSymbolName)
                        }

                        Button {
                            model.openBrowserTab()
                        } label: {
                            Label(
                                "Web Browser",
                                systemImage: IconRole.rightPanelMode(.browser).icon.systemSymbolName
                            )
                        }

                        Button {
                            chooseNvimFile()
                        } label: {
                            Label(
                                "nvim File...",
                                systemImage: IconRole.rightPanelMode(.nvim).icon.systemSymbolName)
                        }

                        Button {
                            model.selectRightPanelTab(id: RightPanelTab.gitID)
                        } label: {
                            Label(
                                "Git",
                                systemImage: IconRole.rightPanelMode(.git).icon.systemSymbolName)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: IconRole.add.icon.systemSymbolName)
                            Image(systemName: IconRole.disclosureExpanded.icon.systemSymbolName)
                                .font(.system(size: 9, weight: ChromeMetrics.glyphWeight))
                        }
                        .font(
                            .system(
                                size: ChromeMetrics.toolbarGlyph, weight: ChromeMetrics.glyphWeight)
                        )
                        .frame(width: 38, height: 32)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                    .foregroundStyle(dracula(.foreground))
                    .background(dracula(.background))
                    .help("Open a new right tool panel tab")
                    .accessibilityLabel("Open a new right tool panel tab")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }

            switch model.selectedRightPanelTab.kind {
            case .files:
                FileBrowserPanel(
                    state: model.fileBrowserState,
                    searchQuery: Binding(
                        get: { model.fileBrowserState.searchQuery },
                        set: { model.updateFileSearchQuery($0) }
                    ),
                    expandedFolders: Binding(
                        get: {
                            model.selectedThreadID.map { model.expandedFolders(forThreadID: $0) }
                                ?? []
                        },
                        set: { newValue in
                            if let id = model.selectedThreadID {
                                model.setExpandedFolders(newValue, forThreadID: id)
                            }
                        }
                    ),
                    selectedRelativePath: model.selectedFileRelativePath,
                    fileIconPack: model.configuration.fileIconPack,
                    onRefresh: model.refreshSelectedFileBrowser,
                    onSelectFile: { entry in
                        model.selectFile(relativePath: entry.relativePath)
                    },
                    onOpenFile: { entry in
                        model.openFileFromBrowserPrimary(relativePath: entry.relativePath)
                    },
                    onOpenInBrowser: { entry in
                        model.openFileInBrowser(relativePath: entry.relativePath)
                    },
                    defaultExternalEditorTool: defaultExternalEditorTool,
                    onOpenExternally: onOpenFileExternally,
                    onCopyPath: onCopyPath,
                    onExpandDirectory: { entry in
                        model.expandPrunedDirectory(relativePath: entry.relativePath)
                    },
                    onTreeBuilt: model.recordFileBrowserTreeBuilt(entryCount:rowCount:durationMS:)
                )
                .onAppear {
                    model.refreshSelectedFileBrowser()
                }

            case .browser:
                BrowserPanel(
                    tab: model.selectedRightPanelTab,
                    threadID: model.selectedThreadID,
                    runtime: isolatedToolRuntime,
                    unavailableMessage: model.selectedBrowserUnavailableMessage,
                    onNavigate: model.updateSelectedBrowserTab(urlString:),
                    onOpenNewWindow: { urlString in
                        model.openBrowserTab(urlString: urlString)
                    }
                )
                .id(
                    browserInstanceID(
                        threadID: model.selectedThreadID, tabID: model.selectedRightPanelTab.id))

            case .nvim:
                TerminalPlaceholderView(
                    request: selectedRightPanelRequest,
                    unavailableMessage: selectedRightPanelUnavailableMessage(tool: "nvim"),
                    fonts: model.configuration.fonts,
                    appShortcutSignatures: appShortcutSignatures
                )
                .id(
                    "\(model.selectedThreadID?.uuidString ?? "none")-\(model.selectedRightPanelTab.id)"
                )
                .onAppear {
                    model.activateSelectedRightPanelTerminal()
                }

            case .git:
                TerminalPlaceholderView(
                    request: selectedRightPanelRequest,
                    unavailableMessage: selectedRightPanelUnavailableMessage(tool: "lazygit"),
                    fonts: model.configuration.fonts,
                    appShortcutSignatures: appShortcutSignatures
                )
                .id(model.selectedThreadID)
                .onAppear {
                    model.activateSelectedRightPanelTerminal()
                }
            }
        }
        .background(dracula(.background))
        .onAppear {
            syncIsolatedToolVisibility()
        }
        .onChange(of: activeBrowserInstanceID) {
            syncIsolatedToolVisibility()
        }
        .onChange(of: model.selectedThreadID) {
            syncIsolatedToolVisibility()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) { _ in
            isolatedToolRuntime.hideAll()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            syncIsolatedToolVisibility()
        }
        .onDisappear {
            isolatedToolRuntime.shutdownAll()
        }
    }

    private var activeBrowserInstanceID: String? {
        guard model.selectedRightPanelTab.kind == .browser else { return nil }
        return browserInstanceID(
            threadID: model.selectedThreadID, tabID: model.selectedRightPanelTab.id)
    }

    private func browserInstanceID(threadID: UUID?, tabID: String) -> String {
        "\(threadID?.uuidString ?? "no-thread"):\(tabID)"
    }

    private func syncIsolatedToolVisibility() {
        guard let activeBrowserInstanceID else {
            isolatedToolRuntime.shutdownAll()
            return
        }
        isolatedToolRuntime.hideAll(except: activeBrowserInstanceID)
    }

    private func rightPanelTabButton(_ tab: RightPanelTab) -> some View {
        let isSelected = model.selectedRightPanelTab.id == tab.id
        let showsTitle = isSelected && shouldShowTabTitle(tab)
        return HStack(spacing: 4) {
            Button {
                model.selectRightPanelTab(id: tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: IconRole.rightPanelMode(mode(for: tab.kind)).icon
                            .systemSymbolName
                    )
                    .font(
                        .system(size: ChromeMetrics.toolbarGlyph, weight: ChromeMetrics.glyphWeight)
                    )
                    .frame(width: 22, height: 32)

                    if showsTitle {
                        Text(tab.title)
                            .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150, alignment: .leading)
                    }
                }
                .padding(.leading, showsTitle ? 8 : 6)
                .padding(.trailing, isSelected && tab.isClosable ? 0 : (showsTitle ? 8 : 6))
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected, tab.isClosable {
                Button {
                    model.closeRightPanelTab(id: tab.id)
                } label: {
                    Image(systemName: IconRole.close.icon.systemSymbolName)
                        .font(.system(size: 11, weight: ChromeMetrics.glyphWeight))
                        .frame(width: 18, height: 32)
                }
                .buttonStyle(.plain)
                .help("Close \(tab.title) tab")
                .accessibilityLabel("Close \(tab.title) tab")
            }
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: false))
        )
        .foregroundStyle(isSelected ? dracula(.pink) : dracula(.foreground))
        .help(tab.title)
        .accessibilityLabel("\(tab.title) right tool panel tab")
        .contextMenu {
            if tab.isClosable {
                Button("Close Tab") {
                    model.closeRightPanelTab(id: tab.id)
                }
            }
        }
    }

    private func shouldShowTabTitle(_ tab: RightPanelTab) -> Bool {
        switch tab.kind {
        case .browser:
            return tab.title != RightPanelTab.defaultBrowser.title
        case .nvim:
            return tab.title != RightPanelTab.defaultNvim.title
        case .files, .git:
            return false
        }
    }

    private var selectedRightPanelRequest: TerminalLaunchRequest? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        switch model.selectedRightPanelTab.kind {
        case .files, .browser:
            return nil
        case .git:
            return model.terminalLaunchRequest(for: .lazygit(threadID: selectedThreadID))
        case .nvim:
            return model.terminalLaunchRequest(
                for: .nvimTab(threadID: selectedThreadID, tabID: model.selectedRightPanelTab.id)
            )
        }
    }

    private func selectedRightPanelUnavailableMessage(tool: String) -> String {
        if case .missing(let path) = model.selectedThreadWorkingDirectoryState {
            return "Missing working directory for \(tool): \(path)"
        }
        return "Terminal unavailable for \(tool)"
    }

    private func mode(for kind: RightPanelTabKind) -> RightPanelMode {
        switch kind {
        case .files:
            .files
        case .browser:
            .browser
        case .git:
            .git
        case .nvim:
            .nvim
        }
    }

    private func chooseNvimFile() {
        guard let root = model.selectedThread?.workingDirectory else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url {
            let rootPath = root.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { return }
            model.openFileInNvim(relativePath: String(filePath.dropFirst(rootPath.count + 1)))
        }
    }
}

private struct BrowserPanel: View {
    let tab: RightPanelTab
    let threadID: UUID?
    @ObservedObject var runtime: IsolatedToolRuntime
    let unavailableMessage: String?
    let onNavigate: (String) -> Void
    let onOpenNewWindow: (String) -> Void
    @State private var addressText = ""
    @FocusState private var isAddressFocused: Bool
    @Environment(\.fontSettings) private var fonts

    private var instanceID: String {
        Self.instanceID(threadID: threadID, tabID: tab.id)
    }

    private static func instanceID(threadID: UUID?, tabID: String) -> String {
        "\(threadID?.uuidString ?? "no-thread"):\(tabID)"
    }

    private var snapshot: IsolatedToolRuntimeSnapshot {
        runtime.snapshot(for: instanceID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    runtime.browserBack(instanceID: instanceID)
                } label: {
                    Image(systemName: IconRole.navigateBack.icon.systemSymbolName)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.canGoBack)
                .help("Back")
                .accessibilityLabel("Browser back")

                Button {
                    runtime.browserForward(instanceID: instanceID)
                } label: {
                    Image(systemName: IconRole.navigateForward.icon.systemSymbolName)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.canGoForward)
                .help("Forward")
                .accessibilityLabel("Browser forward")

                Button {
                    if snapshot.isLoading {
                        runtime.browserStop(instanceID: instanceID)
                    } else {
                        runtime.browserReload(instanceID: instanceID, urlString: tab.urlString)
                    }
                } label: {
                    Image(
                        systemName: snapshot.isLoading
                            ? "xmark" : IconRole.reload.icon.systemSymbolName
                    )
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(snapshot.isLoading ? "Stop loading" : "Reload")
                .accessibilityLabel(snapshot.isLoading ? "Stop browser loading" : "Reload browser")

                TextField("Search or enter website", text: $addressText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dracula(.currentLine))
                    .foregroundStyle(dracula(.foreground))
                    .focused($isAddressFocused)
                    .onSubmit {
                        onNavigate(addressText)
                    }
                    .accessibilityLabel("Browser address")

                if !snapshot.title.isEmpty {
                    Text(snapshot.title)
                        .font(fonts.interfaceFont(sizeOffset: -1))
                        .foregroundStyle(dracula(.comment))
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .foregroundStyle(dracula(.foreground))

            Divider()
                .overlay(dracula(.currentLine))

            if let unavailableMessage {
                MissingDirectoryBanner(
                    title: "Browser preview unavailable",
                    path: tab.relativePath ?? tab.urlString ?? "Browser",
                    message: unavailableMessage
                )
                Spacer()
            } else if let urlString = tab.urlString, !urlString.isEmpty {
                ZStack(alignment: .top) {
                    Color.white

                    IsolatedToolViewportReporter { frame, visible, shouldFloatToolHost in
                        runtime.setViewport(
                            instanceID: instanceID,
                            frame: frame,
                            visible: visible,
                            shouldFloatToolHost: shouldFloatToolHost)
                    }
                    .allowsHitTesting(false)

                    if let errorMessage = snapshot.errorMessage {
                        isolatedToolMessage(
                            title: snapshot.phase == .crashed
                                ? "Browser renderer crashed" : "Browser unavailable",
                            message: errorMessage,
                            urlString: urlString
                        )
                    } else if snapshot.phase == .idle || snapshot.phase == .launching {
                        isolatedToolMessage(
                            title: "Starting browser renderer",
                            message: "The browser is running in an isolated helper process.",
                            urlString: urlString,
                            showActions: false
                        )
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: IconRole.rightPanelMode(.browser).icon.systemSymbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(dracula(.cyan))
                    Text("Enter a URL")
                        .font(fonts.interfaceFont(weight: .semibold))
                        .foregroundStyle(dracula(.foreground))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dracula(.background))
            }
        }
        .background(dracula(.background))
        .onAppear {
            syncAddressText()
            runtime.onNewSurfaceRequested = onOpenNewWindow
            if let urlString = tab.urlString, !urlString.isEmpty {
                runtime.loadBrowser(instanceID: instanceID, urlString: urlString)
            } else {
                runtime.shutdown(instanceID: instanceID)
            }
            if tab.urlString?.isEmpty ?? true {
                isAddressFocused = true
            }
        }
        .onDisappear {
            runtime.shutdown(instanceID: instanceID)
        }
        .onChange(of: tab.id) {
            syncAddressText()
        }
        .onChange(of: tab.urlString) {
            syncAddressText()
            if let urlString = tab.urlString, !urlString.isEmpty {
                runtime.loadBrowser(instanceID: instanceID, urlString: urlString)
            } else {
                runtime.shutdown(instanceID: instanceID)
            }
        }
    }

    private func syncAddressText() {
        addressText = tab.urlString ?? ""
    }

    private func isolatedToolMessage(
        title: String,
        message: String,
        urlString: String,
        showActions: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: IconRole.warning.icon.systemSymbolName)
                .font(fonts.interfaceFont(weight: .semibold))
                .foregroundStyle(dracula(.orange))
            Text(message)
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.foreground))
            if showActions {
                HStack {
                    Button("Reload") {
                        runtime.browserReload(instanceID: instanceID, urlString: urlString)
                    }
                    .buttonStyle(.bordered)

                    Button("Restart Tool") {
                        runtime.restart(kind: .browser, instanceID: instanceID)
                        runtime.loadBrowser(instanceID: instanceID, urlString: urlString)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dracula(.currentLine))
    }
}

private struct MissingDirectoryBanner: View {
    let title: String
    let path: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: IconRole.warning.icon.systemSymbolName)
                .font(.headline)
                .foregroundStyle(dracula(.orange))

            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(dracula(.cyan))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Text(message)
                .font(.caption)
                .foregroundStyle(dracula(.foreground))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dracula(.currentLine))
        .accessibilityLabel("\(title): \(path)")
    }
}

func dracula(_ role: ThemeRole) -> AppThemeColor {
    AppThemeColor(role: role)
}

func themeUI(_ role: ThemeUIRole) -> AppThemeUIColor {
    AppThemeUIColor(role: role)
}

struct AppThemeColor: ShapeStyle {
    let role: ThemeRole

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(hex: environment.appTheme.hex(for: role)).resolve(in: environment)
    }
}

struct AppThemeUIColor: ShapeStyle {
    let role: ThemeUIRole

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(hex: environment.appTheme.uiHex(for: role)).resolve(in: environment)
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ThemeCatalog.defaultTheme
}

private struct FontSettingsEnvironmentKey: EnvironmentKey {
    static let defaultValue = FontSettings()
}

extension EnvironmentValues {
    var appTheme: ThemeDefinition {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }

    var fontSettings: FontSettings {
        get { self[FontSettingsEnvironmentKey.self] }
        set { self[FontSettingsEnvironmentKey.self] = newValue }
    }
}

extension ThemeDefinition {
    var swiftUIColorScheme: ColorScheme {
        switch preferredColorScheme {
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

extension FontSettings {
    func interfaceFont(sizeOffset: Double = 0, weight: Font.Weight = .regular) -> Font {
        swiftUIFont(
            family: interfaceFamily, size: interfaceSize + sizeOffset, weight: weight,
            design: .default)
    }

    func editorFont(sizeOffset: Double = 0, weight: Font.Weight = .regular) -> Font {
        swiftUIFont(
            family: editorFamily, size: editorSize + sizeOffset, weight: weight, design: .monospaced
        )
    }

    /// File browser list font. When `fileBrowserFamily` is `inherit` (the default),
    /// this resolves to the interface font/size so behavior matches the rest of the chrome.
    func fileBrowserFont(sizeOffset: Double = 0, weight: Font.Weight = .regular) -> Font {
        let normalized = fileBrowserFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let inherits = normalized.isEmpty || normalized == FontSettings.inheritFamily
        let family = inherits ? interfaceFamily : fileBrowserFamily
        let baseSize = fileBrowserSize > 0 ? fileBrowserSize : interfaceSize
        return swiftUIFont(
            family: family, size: baseSize + sizeOffset, weight: weight, design: .default)
    }

    private func swiftUIFont(
        family: String,
        size: Double,
        weight: Font.Weight,
        design: Font.Design
    ) -> Font {
        let pointSize = CGFloat(max(6, size))
        switch family.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "system":
            return .system(size: pointSize, weight: weight, design: .default)
        case "system-monospace", "monospace":
            return .system(size: pointSize, weight: weight, design: .monospaced)
        default:
            return .custom(family, size: pointSize).weight(weight)
        }
    }
}

extension Color {
    fileprivate init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        let scanner = Scanner(string: value)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)

        self.init(
            red: Double((rgb >> 16) & 0xff) / 255.0,
            green: Double((rgb >> 8) & 0xff) / 255.0,
            blue: Double(rgb & 0xff) / 255.0
        )
    }
}
