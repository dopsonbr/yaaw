import YAAWKit
import AppKit
import SwiftUI

private enum FileBrowserCopyPathStyle {
    case relative
    case full
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @Binding var isSettingsOpen: Bool
    let externalOpenWorkspace: ExternalOpenWorkspace
    let settingsPath: URL
    let onLoadSettingsText: () throws -> String
    let onValidateSettingsText: (String) throws -> YAAWConfiguration
    let onSaveSettingsText: (String) throws -> YAAWConfiguration
    let onOpenSettingsFile: () -> Void
    let onReloadSettings: () -> Void
    let onInstallLatestRelease: () -> Void
    @State private var isShowingUpdateConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    AppChromeHeader(
                        title: model.windowTitle,
                        isSidebarCollapsed: model.layoutState.isSidebarCollapsed,
                        isRightPanelCollapsed: model.layoutState.isRightPanelCollapsed,
                        onToggleSidebar: model.toggleSidebarCollapsed,
                        onToggleRightPanel: model.toggleRightPanelCollapsed,
                        onNavigateBack: model.navigateBack,
                        onNavigateForward: model.navigateForward,
                        fonts: model.configuration.fonts,
                        externalOpenTools: availableExternalOpenTools,
                        defaultExternalOpenTool: defaultExternalOpenTool,
                        externalOpenIcon: externalOpenWorkspace.icon(for:),
                        onOpenDefaultExternal: openSelectedDirectoryWithDefaultExternalTool,
                        onOpenExternalTool: openSelectedDirectoryExternally,
                        onInstallLatestRelease: { isShowingUpdateConfirmation = true },
                        onOpenSettings: { isSettingsOpen = true }
                    )
                }
                .frame(height: 44)
                .background(dracula(.background))

                Divider()
                    .overlay(dracula(.currentLine))

                if isSettingsOpen {
                    SettingsEditorView(
                        configuration: model.configuration,
                        fonts: model.configuration.fonts,
                        settingsPath: settingsPath,
                        onLoadText: onLoadSettingsText,
                        onValidateText: onValidateSettingsText,
                        onSaveText: onSaveSettingsText,
                        onOpenExternal: onOpenSettingsFile,
                        onReloadConfiguration: onReloadSettings,
                        onBack: { isSettingsOpen = false }
                    )
                } else {
                    workspaceContent()
                }
            }
        }
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
        .font(model.configuration.fonts.interfaceFont())
        .environment(\.fontSettings, model.configuration.fonts)
        .environment(\.appTheme, model.configuration.resolvedTheme)
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
            Text("The app will open Terminal to run the release installer, then quit so the installed app can be replaced.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            GhosttyTerminalRuntime.closeAll()
        }
    }

    private var selectedBottomTerminalRequest: TerminalLaunchRequest? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        return model.terminalLaunchRequest(for: .bottom(threadID: selectedThreadID))
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
        guard let target = model.fileBrowserExternalOpenTarget(
            relativePath: entry.relativePath,
            isDirectory: entry.isDirectory
        ) else { return }
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
            MainWorkspaceView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } right: {
            rightPanelRegion
        } bottom: {
            BottomTerminalBar(
                isExpanded: model.isBottomTerminalExpanded,
                request: selectedBottomTerminalRequest,
                fonts: model.configuration.fonts,
                onToggle: model.toggleBottomTerminal,
                onAppearExpanded: {
                    model.activateSelectedBottomTerminal()
                }
            )
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
    private var rightPanelRegion: some View {
        if model.layoutState.isRightPanelCollapsed {
            CollapsedPanelRail(
                systemImage: IconRole.rightSidebar.icon.systemSymbolName,
                accessibilityLabel: "Expand right panel",
                action: model.toggleRightPanelCollapsed
            )
            .frame(width: 44)
        } else {
            RightPanelView(
                model: model,
                defaultExternalEditorTool: defaultExternalEditorTool,
                onOpenFileExternally: openFileExternally,
                onCopyPath: copyFileBrowserPath
            )
        }
    }

    private func updateLayoutFromSplitView(_ layout: WorkspaceSplitLayout, phase: WorkspaceSplitResizePhase) {
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
}

private struct AppChromeHeader: View {
    let title: String
    let isSidebarCollapsed: Bool
    let isRightPanelCollapsed: Bool
    let onToggleSidebar: () -> Void
    let onToggleRightPanel: () -> Void
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
        HStack(spacing: 12) {
            Button(action: onToggleSidebar) {
                Image(systemName: IconRole.sidebar.icon.systemSymbolName)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.foreground))
            .help(isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            .accessibilityLabel(isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")

            Button(action: onNavigateBack) {
                Image(systemName: IconRole.navigateBack.icon.systemSymbolName)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.comment))
            .help("Back")
            .accessibilityLabel("Back")

            Button(action: onNavigateForward) {
                Image(systemName: IconRole.navigateForward.icon.systemSymbolName)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.comment))
            .help("Forward")
            .accessibilityLabel("Forward")

            Divider()
                .overlay(dracula(.currentLine))
                .frame(height: 28)

            Text(title)
                .font(fonts.interfaceFont(sizeOffset: 2, weight: .semibold))
                .foregroundStyle(dracula(.foreground))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            ExternalOpenSplitButton(
                tools: externalOpenTools,
                defaultTool: defaultExternalOpenTool,
                icon: externalOpenIcon,
                onOpenDefault: onOpenDefaultExternal,
                onOpenTool: onOpenExternalTool
            )

            Button(action: onInstallLatestRelease) {
                Image(systemName: IconRole.installUpdate.icon.systemSymbolName)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.foreground))
            .help("Install latest release")
            .accessibilityLabel("Install latest release")
            .accessibilityIdentifier("install-latest-release-button")

            Button(action: onOpenSettings) {
                Image(systemName: IconRole.settings.icon.systemSymbolName)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.foreground))
            .help("Settings")
            .accessibilityLabel("Open settings")
            .accessibilityIdentifier("open-settings-button")

            Button(action: onToggleRightPanel) {
                Image(systemName: IconRole.rightSidebar.icon.systemSymbolName)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.foreground))
            .help(isRightPanelCollapsed ? "Expand right panel" : "Collapse right panel")
            .accessibilityLabel(isRightPanelCollapsed ? "Expand right panel" : "Collapse right panel")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
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
            .help(defaultTool.map { "Open in \($0.displayName)" } ?? "No external open destination available")
            .accessibilityLabel(defaultTool.map { "Open in \($0.displayName)" } ?? "No external open destination available")
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
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(tools.isEmpty)
            .help("Choose external open destination")
            .accessibilityLabel("Choose external open destination")
            .accessibilityIdentifier("external-open-menu-button")
        }
        .background(dracula(.currentLine).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(dracula(.comment).opacity(0.45), lineWidth: 1)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(dracula(.cyan))
        } else {
            Image(systemName: IconRole.openDocument.icon.systemSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(dracula(.comment))
        }
    }
}

private struct AgentCLIIcon: View {
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
            if let url = Bundle.module.url(
                forResource: agentCLI.brandIconResourceName,
                withExtension: fileExtension
            ), let image = NSImage(contentsOf: url) {
                return image
            }

            if let url = Bundle.module.url(
                forResource: agentCLI.brandIconResourceName,
                withExtension: fileExtension,
                subdirectory: "AgentIcons"
            ), let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

private struct SettingsEditorView: View {
    let configuration: YAAWConfiguration
    let fonts: FontSettings
    let settingsPath: URL
    let onLoadText: () throws -> String
    let onValidateText: (String) throws -> YAAWConfiguration
    let onSaveText: (String) throws -> YAAWConfiguration
    let onOpenExternal: () -> Void
    let onReloadConfiguration: () -> Void
    let onBack: () -> Void

    @State private var editorText = ""
    @State private var lastSavedText = ""
    @State private var statusMessage = "Loading settings..."
    @State private var validationError: String?
    @State private var hasLoaded = false
    @State private var pendingDiscardAction: SettingsDiscardAction?
    @State private var isShowingDiscardConfirmation = false
    @State private var selectedThemeID = ThemeCatalog.defaultID
    @State private var selectedSection: SettingsSection = .yaml
    @State private var shortcutSearchText = ""
    @State private var currentConfiguration = YAAWConfiguration()

    private var hasUnsavedChanges: Bool {
        editorText != lastSavedText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings")
                        .font(fonts.interfaceFont(sizeOffset: 8, weight: .semibold))
                        .foregroundStyle(dracula(.purple))

                    Text(settingsPath.path)
                        .font(fonts.editorFont(sizeOffset: -1))
                        .textSelection(.enabled)
                        .foregroundStyle(dracula(.cyan))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    requestBack()
                } label: {
                    Label("Back", systemImage: IconRole.navigateBack.icon.systemSymbolName)
                }
                .help("Back to workspace")
                .accessibilityLabel("Back to workspace")
                .accessibilityIdentifier("settings-back-button")
            }

            Picker("Settings Section", selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings-section-picker")

            switch selectedSection {
            case .appearance:
                appearanceSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .keyBindings:
                keyBindingsSection
            case .yaml:
                yamlSection
            }

            if let validationError {
                Label(validationError, systemImage: IconRole.warning.icon.systemSymbolName)
                    .font(fonts.interfaceFont(sizeOffset: -1))
                    .foregroundStyle(dracula(.red))
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text(statusMessage)
                    .font(fonts.interfaceFont(sizeOffset: -1))
                    .foregroundStyle(dracula(.comment))
            }

            HStack {
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .configuredKeyboardShortcut(currentConfiguration.shortcut(for: .saveSettings))
                .disabled(!hasUnsavedChanges)
                .accessibilityIdentifier("settings-save-button")

                Button {
                    requestReload()
                } label: {
                    Label("Reload", systemImage: IconRole.reload.icon.systemSymbolName)
                }
                .configuredKeyboardShortcut(currentConfiguration.shortcut(for: .reloadSettings))
                .accessibilityIdentifier("settings-reload-button")

                Button {
                    revert()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .configuredKeyboardShortcut(currentConfiguration.shortcut(for: .revertSettings))
                .disabled(!hasUnsavedChanges)
                .accessibilityIdentifier("settings-revert-button")

                Button {
                    onOpenExternal()
                } label: {
                    Label("Open External", systemImage: IconRole.openDocument.icon.systemSymbolName)
                }
                .configuredKeyboardShortcut(currentConfiguration.shortcut(for: .openSettingsExternal))

                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
        .onAppear(perform: loadIfNeeded)
        .onChange(of: configuration.themeName) { _, newThemeID in
            selectedThemeID = ThemeCatalog.theme(id: newThemeID)?.id ?? ThemeCatalog.defaultID
        }
        .confirmationDialog(
            "Discard unsaved settings changes?",
            isPresented: $isShowingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                performPendingDiscardAction()
            }
            Button("Cancel", role: .cancel) {
                pendingDiscardAction = nil
            }
        } message: {
            Text("Unsaved YAML edits will be lost.")
        }
    }

    private var editorHeader: some View {
        HStack {
            Text("YAML")
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                .foregroundStyle(dracula(.comment))

            if hasUnsavedChanges {
                Text("Unsaved")
                    .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                    .foregroundStyle(dracula(.orange))
            }

            Spacer()
        }
    }

    private var yamlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorHeader

            TextEditor(text: $editorText)
                .font(fonts.editorFont())
                .foregroundStyle(dracula(.foreground))
                .scrollContentBackground(.hidden)
                .background(dracula(.currentLine).opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(validationError == nil ? dracula(.currentLine) : dracula(.red), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .accessibilityLabel("Settings YAML editor")
                .accessibilityIdentifier("settings-yaml-editor")
        }
    }

    private var keyBindingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Key Bindings")
                    .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                    .foregroundStyle(dracula(.comment))

                TextField("Search actions", text: $shortcutSearchText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dracula(.currentLine))
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("settings-keybindings-search")

                Spacer()
            }

            HStack(spacing: 10) {
                Text("Action")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Scope")
                    .frame(width: 110, alignment: .leading)
                Text("Shortcut")
                    .frame(width: 180, alignment: .leading)
                Text("Default")
                    .frame(width: 150, alignment: .leading)
                Text("Modifiers")
                    .frame(width: 260, alignment: .leading)
                Text("")
                    .frame(width: 130)
            }
            .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
            .foregroundStyle(dracula(.comment))
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredShortcutActions) { action in
                        SettingsKeyBindingRow(
                            action: action,
                            definition: currentConfiguration.shortcut(for: action),
                            isConflicting: currentConfiguration.keyboardShortcuts.duplicateActions().contains(action),
                            onSetKey: { key in
                                updateShortcut(action, key: key)
                            },
                            onToggleModifier: { modifier in
                                toggleShortcutModifier(modifier, for: action)
                            },
                            onClear: {
                                saveShortcut(.unbound, for: action)
                            },
                            onReset: {
                                saveShortcut(action.defaultShortcut, for: action)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .background(dracula(.background))
            .accessibilityIdentifier("settings-keybindings-list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredShortcutActions: [KeyboardShortcutAction] {
        let query = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return KeyboardShortcutAction.allCases }
        return KeyboardShortcutAction.allCases.filter {
            $0.displayName.lowercased().contains(query)
                || $0.scope.rawValue.lowercased().contains(query)
                || $0.rawValue.lowercased().contains(query)
        }
    }

    private var appearanceSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Appearance")
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                .foregroundStyle(dracula(.comment))

            Picker("Theme", selection: themeSelection) {
                ForEach(ThemeGroup.allCases) { group in
                    Section(group.displayName) {
                        ForEach(ThemeCatalog.themes(in: group)) { theme in
                            Text(theme.displayName).tag(theme.id)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
            .accessibilityLabel("Theme")
            .accessibilityIdentifier("settings-theme-picker")

            Spacer()
        }
    }

    private var themeSelection: Binding<String> {
        Binding(
            get: { selectedThemeID },
            set: { newValue in
                guard selectedThemeID != newValue else { return }
                selectedThemeID = newValue
                saveThemeSelection(newValue)
            }
        )
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reloadFromDisk()
    }

    private func requestBack() {
        guard hasUnsavedChanges else {
            onBack()
            return
        }
        pendingDiscardAction = .back
        isShowingDiscardConfirmation = true
    }

    private func requestReload() {
        guard hasUnsavedChanges else {
            reloadFromDisk()
            return
        }
        pendingDiscardAction = .reload
        isShowingDiscardConfirmation = true
    }

    private func performPendingDiscardAction() {
        switch pendingDiscardAction {
        case .back:
            pendingDiscardAction = nil
            onBack()
        case .reload:
            pendingDiscardAction = nil
            reloadFromDisk()
        case .none:
            break
        }
    }

    private func reloadFromDisk() {
        do {
            let text = try onLoadText()
            editorText = text
            lastSavedText = text
            do {
                let configuration = try onValidateText(text)
                currentConfiguration = configuration
                selectedThemeID = configuration.resolvedTheme.id
                validationError = nil
                onReloadConfiguration()
                statusMessage = "Settings reloaded from disk."
            } catch {
                validationError = "YAML validation failed: \(error)"
                statusMessage = "Settings file loaded with validation errors."
            }
        } catch {
            validationError = "Could not load settings: \(error)"
            statusMessage = "Settings file could not be loaded."
        }
    }

    private func save() {
        do {
            _ = try onSaveText(editorText)
            let configuration = try onValidateText(editorText)
            currentConfiguration = configuration
            selectedThemeID = configuration.resolvedTheme.id
            lastSavedText = editorText
            validationError = nil
            statusMessage = "Settings saved and applied."
        } catch {
            validationError = "YAML validation failed: \(error)"
            statusMessage = "Settings were not saved."
        }
    }

    private func revert() {
        editorText = lastSavedText
        do {
            let configuration = try onValidateText(editorText)
            currentConfiguration = configuration
            selectedThemeID = configuration.resolvedTheme.id
            validationError = nil
            statusMessage = "Unsaved edits reverted."
        } catch {
            validationError = "YAML validation failed: \(error)"
            statusMessage = "Reverted to the last loaded file contents."
        }
    }

    private func saveThemeSelection(_ themeID: String) {
        do {
            var nextConfiguration = try onValidateText(editorText)
            nextConfiguration.theme.active = themeID
            let renderedText = YAMLConfigurationStore.render(nextConfiguration)
            _ = try onSaveText(renderedText)
            editorText = renderedText
            lastSavedText = renderedText
            currentConfiguration = nextConfiguration.validated()
            selectedThemeID = themeID
            validationError = nil
            statusMessage = "Theme saved and applied."
        } catch {
            selectedThemeID = configuration.resolvedTheme.id
            validationError = "YAML validation failed: \(error)"
            statusMessage = "Theme was not changed."
        }
    }

    private func updateShortcut(_ action: KeyboardShortcutAction, key: String) {
        var definition = currentConfiguration.shortcut(for: action)
        definition.key = String(key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
        saveShortcut(definition, for: action)
    }

    private func toggleShortcutModifier(_ modifier: KeyboardShortcutModifier, for action: KeyboardShortcutAction) {
        var definition = currentConfiguration.shortcut(for: action)
        if definition.modifiers.contains(modifier) {
            definition.modifiers.removeAll { $0 == modifier }
        } else {
            definition.modifiers.append(modifier)
        }
        saveShortcut(definition, for: action)
    }

    private func saveShortcut(_ definition: KeyboardShortcutDefinition, for action: KeyboardShortcutAction) {
        do {
            var nextConfiguration = try onValidateText(editorText)
            nextConfiguration.keyboardShortcuts.setDefinition(definition, for: action)
            nextConfiguration = nextConfiguration.validated()
            let conflicts = nextConfiguration.keyboardShortcuts.duplicateActions()
            if conflicts.contains(action) {
                validationError = "Shortcut conflict: \(definition.displayText) is already used by another action."
                statusMessage = "Shortcut was not changed."
                return
            }
            let renderedText = YAMLConfigurationStore.render(nextConfiguration)
            _ = try onSaveText(renderedText)
            editorText = renderedText
            lastSavedText = renderedText
            currentConfiguration = nextConfiguration
            selectedThemeID = nextConfiguration.resolvedTheme.id
            validationError = nil
            statusMessage = "Shortcut saved and applied."
        } catch {
            validationError = "YAML validation failed: \(error)"
            statusMessage = "Shortcut was not changed."
        }
    }
}

private enum SettingsDiscardAction {
    case back
    case reload
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case keyBindings
    case yaml

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance:
            "Appearance"
        case .keyBindings:
            "Key Bindings"
        case .yaml:
            "YAML"
        }
    }
}

private struct SettingsKeyBindingRow: View {
    let action: KeyboardShortcutAction
    let definition: KeyboardShortcutDefinition
    let isConflicting: Bool
    let onSetKey: (String) -> Void
    let onToggleModifier: (KeyboardShortcutModifier) -> Void
    let onClear: () -> Void
    let onReset: () -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                    .font(fonts.interfaceFont(weight: .semibold))
                    .lineLimit(1)
                Text(action.rawValue)
                    .font(fonts.editorFont(sizeOffset: -2))
                    .foregroundStyle(dracula(.comment))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(action.scope.rawValue)
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))
                .frame(width: 110, alignment: .leading)

            HStack(spacing: 6) {
                TextField("Key", text: keyBinding)
                    .textFieldStyle(.plain)
                    .font(fonts.editorFont())
                    .frame(width: 46)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(dracula(.currentLine))
                    .accessibilityLabel("\(action.displayName) key")

                Text(definition.displayText)
                    .font(fonts.interfaceFont(sizeOffset: -1))
                    .foregroundStyle(isConflicting ? dracula(.red) : dracula(.foreground))
                    .lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)

            Text(action.defaultShortcutDescription)
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))
                .frame(width: 150, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(KeyboardShortcutModifier.allCases, id: \.self) { modifier in
                    Toggle(modifier.shortName, isOn: modifierBinding(modifier))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
            .frame(width: 260, alignment: .leading)

            HStack(spacing: 6) {
                Button("Clear", action: onClear)
                Button("Default", action: onReset)
            }
            .controlSize(.small)
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isConflicting ? dracula(.red).opacity(0.18) : dracula(.currentLine).opacity(0.25))
        .accessibilityIdentifier("settings-keybinding-\(action.rawValue)")
    }

    private var keyBinding: Binding<String> {
        Binding(
            get: { definition.key },
            set: { onSetKey($0) }
        )
    }

    private func modifierBinding(_ modifier: KeyboardShortcutModifier) -> Binding<Bool> {
        Binding(
            get: { definition.modifiers.contains(modifier) },
            set: { _ in onToggleModifier(modifier) }
        )
    }
}

private extension KeyboardShortcutModifier {
    var shortName: String {
        switch self {
        case .command:
            "Cmd"
        case .shift:
            "Shift"
        case .option:
            "Opt"
        case .control:
            "Ctrl"
        }
    }
}

private extension View {
    @ViewBuilder
    func configuredKeyboardShortcut(_ definition: KeyboardShortcutDefinition) -> some View {
        if definition.isBound, let character = definition.key.first {
            keyboardShortcut(KeyEquivalent(character), modifiers: definition.eventModifiers)
        } else {
            self
        }
    }
}

private extension KeyboardShortcutDefinition {
    var eventModifiers: EventModifiers {
        var eventModifiers = EventModifiers()
        for modifier in modifiers {
            switch modifier {
            case .command:
                eventModifiers.insert(.command)
            case .shift:
                eventModifiers.insert(.shift)
            case .option:
                eventModifiers.insert(.option)
            case .control:
                eventModifiers.insert(.control)
            }
        }
        return eventModifiers
    }
}

private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var isProjectSheetPresented = false
    @State private var threadSheetProject: Project?
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
                        ForEach(model.projects) { project in
                            ProjectSidebarSection(
                                model: model,
                                project: project,
                                onNewThread: {
                                    threadSheetProject = project
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
                isExpanded: $isArchiveExpanded
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
    }
}

private struct ProjectSidebarSection: View {
    @ObservedObject var model: AppModel
    let project: Project
    let onNewThread: () -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SidebarIconButton(
                    systemImage: (
                        model.isProjectExpanded(project.id) ? IconRole.disclosureExpanded : IconRole.disclosureCollapsed
                    ).icon.systemSymbolName,
                    help: model.isProjectExpanded(project.id) ? "Collapse project" : "Expand project"
                ) {
                    model.setProjectExpanded(project.id, isExpanded: !model.isProjectExpanded(project.id))
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project \(project.displayName)")

                SidebarIconButton(systemImage: IconRole.newThread.icon.systemSymbolName, help: "New thread") {
                    onNewThread()
                }

                SidebarActionsMenu(help: "Project actions") {
                    Button(project.isPinned ? "Unpin Project" : "Pin Project") {
                        model.toggleProjectPinned(id: project.id)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(model.selectedProjectID == project.id ? dracula(.currentLine) : dracula(.background))
            .draggable(project.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let rawID = items.first,
                      let draggedProjectID = UUID(uuidString: rawID) else {
                    return false
                }
                model.reorderProject(id: draggedProjectID, before: project.id)
                return true
            }

            if model.isProjectExpanded(project.id) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.activeThreads(for: project.id)) { thread in
                        ActiveThreadRow(model: model, thread: thread)
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
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        let activity = model.threadActivity(for: thread.id)
        HStack(spacing: 6) {
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
                                .font(fonts.interfaceFont(weight: activity.isUnread ? .semibold : .regular))
                                .lineLimit(1)
                        }

                        if let preview = activity.preview {
                            Text(preview)
                                .font(fonts.interfaceFont(sizeOffset: -2))
                                .foregroundStyle(activity.isUnread ? dracula(.yellow) : dracula(.comment))
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thread \(thread.displayName), \(thread.agentCLI.displayName), \(activity.status.rawValue)")

            SidebarActionsMenu(help: "Thread actions") {
                Button(thread.isPinned ? "Unpin Thread" : "Pin Thread") {
                    model.toggleThreadPinned(id: thread.id)
                }

                Button("Archive Thread") {
                    model.archiveThread(id: thread.id)
                }
            }
        }
        .font(fonts.interfaceFont())
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(model.selectedThreadID == thread.id ? dracula(.currentLine) : dracula(.background))
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
            Image(systemName: activity.isUnread ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(dracula(.yellow))
                .help("Needs input")
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(dracula(.green))
                .help("Complete")
        case .inactive:
            Image(systemName: "circle")
                .font(.system(size: 11, weight: .semibold))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
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
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(dracula(.cyan))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct GlobalArchivedThreadsSection: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: (isExpanded ? IconRole.disclosureExpanded : IconRole.disclosureCollapsed).icon.systemSymbolName)
                        .frame(width: 12)

                    Label("Archived", systemImage: IconRole.archive.icon.systemSymbolName)
                        .labelStyle(.titleAndIcon)

                    Spacer()

                    Text("\(model.archivedThreads.count)")
                        .font(fonts.interfaceFont(sizeOffset: -2))
                        .foregroundStyle(dracula(.comment))
                }
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                .foregroundStyle(dracula(.orange))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived threads")

            if isExpanded {
                if model.archivedThreads.isEmpty {
                    Text("No archived threads")
                        .font(fonts.interfaceFont(sizeOffset: -1))
                        .foregroundStyle(dracula(.comment))
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.archivedThreads) { thread in
                                ArchivedThreadRow(model: model, thread: thread)
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

private struct ArchivedThreadRow: View {
    @ObservedObject var model: AppModel
    let thread: AgentThread
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        HStack(spacing: 8) {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived thread \(thread.displayName)")

            SidebarActionsMenu(help: "Archived thread actions") {
                Button(thread.isPinned ? "Unpin Thread" : "Pin Thread") {
                    model.toggleThreadPinned(id: thread.id)
                }

                Button("Unarchive Thread") {
                    model.unarchiveThread(id: thread.id)
                }
            }
        }
        .font(fonts.interfaceFont(sizeOffset: -1))
        .padding(.vertical, 6)
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
        panel.directoryURL = path.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: path)
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

private struct ThreadChoiceSheet: View {
    @ObservedObject var model: AppModel
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Thread")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            Text(project.displayName)
                .foregroundStyle(dracula(.comment))

            TextField("Optional thread name", text: $displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(dracula(.currentLine))
                .foregroundStyle(dracula(.foreground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Optional thread name")

            HStack(spacing: 12) {
                ForEach(AgentCLIKind.allCases) { agentCLI in
                    Button {
                        createThread(agentCLI: agentCLI)
                    } label: {
                        HStack(spacing: 6) {
                            AgentCLIIcon(agentCLI: agentCLI)
                                .frame(width: 16, height: 16)
                            Text(agentCLI.displayName)
                        }
                    }
                    .keyboardShortcut(agentCLI == model.defaultAgentCLI ? .defaultAction : nil)
                    .accessibilityLabel("Create \(agentCLI.displayName) thread")
                }
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

    private func createThread(agentCLI: AgentCLIKind) {
        do {
            try model.createThread(
                projectID: project.id,
                agentCLI: agentCLI,
                displayName: displayName
            )
            dismiss()
        } catch {
            errorMessage = "Thread could not be created."
        }
    }
}

private struct MainWorkspaceView: View {
    @ObservedObject var model: AppModel
    private let capturePoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .missing(let path) = model.selectedThreadWorkingDirectoryState {
                MissingDirectoryBanner(
                    title: "Working directory is missing",
                    path: path,
                    message: "Project tools are paused until this directory exists again or a new thread uses another path."
                )
            } else if case .missing(let path) = model.selectedProjectDirectoryState {
                MissingDirectoryBanner(
                    title: "Project directory is missing",
                    path: path,
                    message: "Create a new project or restore the directory before creating more threads here."
                )
            }

            TerminalPlaceholderView(
                request: selectedProjectTerminalRequest,
                unavailableMessage: selectedProjectTerminalUnavailableMessage,
                fonts: model.configuration.fonts,
                onTitleChange: { role, title in
                    if case .project(let threadID) = role {
                        model.recordAgentCLITerminalTitle(threadID: threadID, title: title)
                    }
                },
                onDesktopNotification: { role, title, body in
                    if case .project(let threadID) = role {
                        model.recordAgentTerminalNotification(threadID: threadID, title: title, body: body)
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
                        model.recordAgentCommandFinished(threadID: threadID, exitCode: exitCode)
                    }
                }
            )
            .id(model.selectedThreadID)
            .onAppear {
                model.activateSelectedProjectTerminal()
            }
            .onReceive(capturePoll) { _ in
                model.pollSelectedAgentCLICaptureLog()
                model.pollAgentCLIActivityLogs()
            }
        }
        .padding(8)
        .background(dracula(.background))
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
}

private struct RightPanelView: View {
    @ObservedObject var model: AppModel
    let defaultExternalEditorTool: ExternalOpenToolID?
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
                            Label("Files", systemImage: IconRole.rightPanelMode(.files).icon.systemSymbolName)
                        }

                        Button {
                            model.openBrowserTab()
                        } label: {
                            Label("Web Browser", systemImage: IconRole.rightPanelMode(.browser).icon.systemSymbolName)
                        }

                        Button {
                            chooseNvimFile()
                        } label: {
                            Label("nvim File...", systemImage: IconRole.rightPanelMode(.nvim).icon.systemSymbolName)
                        }

                        Button {
                            model.selectRightPanelTab(id: RightPanelTab.gitID)
                        } label: {
                            Label("Git", systemImage: IconRole.rightPanelMode(.git).icon.systemSymbolName)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: IconRole.add.icon.systemSymbolName)
                            Image(systemName: IconRole.disclosureExpanded.icon.systemSymbolName)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 32)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                    .foregroundStyle(dracula(.foreground))
                    .background(dracula(.background))
                    .help("Open a new right panel tab")
                    .accessibilityLabel("Open a new right panel tab")
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
                    selectedRelativePath: model.selectedFileRelativePath,
                    fileIconPack: model.configuration.fileIconPack,
                    onRefresh: model.refreshSelectedFileBrowser,
                    onSelectFile: { entry in
                        model.selectFile(relativePath: entry.relativePath)
                    },
                    onOpenFile: { entry in
                        model.openFileInNvim(relativePath: entry.relativePath)
                    },
                    onOpenInBrowser: { entry in
                        model.openFileInBrowser(relativePath: entry.relativePath)
                    },
                    defaultExternalEditorTool: defaultExternalEditorTool,
                    onOpenExternally: onOpenFileExternally,
                    onCopyPath: onCopyPath
                )
                .onAppear {
                    model.refreshSelectedFileBrowser()
                }
                .onChange(of: model.selectedThreadID) {
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
                .id(browserInstanceID(threadID: model.selectedThreadID, tabID: model.selectedRightPanelTab.id))

            case .nvim:
                TerminalPlaceholderView(
                    request: selectedRightPanelRequest,
                    unavailableMessage: selectedRightPanelUnavailableMessage(tool: "nvim"),
                    fonts: model.configuration.fonts
                )
                    .id("\(model.selectedThreadID?.uuidString ?? "none")-\(model.selectedRightPanelTab.id)")
                    .onAppear {
                        model.activateSelectedRightPanelTerminal()
                    }

            case .git:
                TerminalPlaceholderView(
                    request: selectedRightPanelRequest,
                    unavailableMessage: selectedRightPanelUnavailableMessage(tool: "lazygit"),
                    fonts: model.configuration.fonts
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
        .onDisappear {
            isolatedToolRuntime.shutdownAll()
        }
    }

    private var activeBrowserInstanceID: String? {
        guard model.selectedRightPanelTab.kind == .browser else { return nil }
        return browserInstanceID(threadID: model.selectedThreadID, tabID: model.selectedRightPanelTab.id)
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
        return Button {
            model.selectRightPanelTab(id: tab.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: IconRole.rightPanelMode(mode(for: tab.kind)).icon.systemSymbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 22, height: 32)

                if isSelected, shouldShowTabTitle(tab) {
                    Text(tab.title)
                        .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                }
            }
            .padding(.horizontal, isSelected && shouldShowTabTitle(tab) ? 8 : 6)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? dracula(.currentLine) : dracula(.background))
        .foregroundStyle(isSelected ? dracula(.pink) : dracula(.foreground))
        .help(tab.title)
        .accessibilityLabel("\(tab.title) right panel tab")
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
                    Image(systemName: snapshot.isLoading ? "xmark" : IconRole.reload.icon.systemSymbolName)
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

                    IsolatedToolViewportReporter { frame, visible in
                        runtime.setViewport(instanceID: instanceID, frame: frame, visible: visible)
                    }
                    .allowsHitTesting(false)

                    if let errorMessage = snapshot.errorMessage {
                        isolatedToolMessage(
                            title: snapshot.phase == .crashed ? "Browser renderer crashed" : "Browser unavailable",
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

private struct FileBrowserPanel: View {
    let state: FileBrowserState
    @Binding var searchQuery: String
    let selectedRelativePath: String?
    let fileIconPack: FileIconPack
    let onRefresh: () -> Void
    let onSelectFile: (FileBrowserEntry) -> Void
    let onOpenFile: (FileBrowserEntry) -> Void
    let onOpenInBrowser: (FileBrowserEntry) -> Void
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void
    @State private var expandedFolders: Set<String> = []
    @State private var typedQuery: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var treeRoots: [FileBrowserTreeNode] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search files", text: $typedQuery)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dracula(.currentLine))
                    .foregroundStyle(dracula(.foreground))
                    .accessibilityLabel("Search files")
                    .onAppear { typedQuery = searchQuery }
                    .onChange(of: searchQuery) { _, new in
                        if new != typedQuery { typedQuery = new }
                    }
                    .onChange(of: typedQuery) { _, new in
                        debounceTask?.cancel()
                        let captured = new
                        debounceTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                if searchQuery != captured { searchQuery = captured }
                            }
                        }
                    }

                Button(action: onRefresh) {
                    Image(systemName: IconRole.reload.icon.systemSymbolName)
                }
                .buttonStyle(.plain)
                .foregroundStyle(dracula(.cyan))
                .help("Refresh files")
                .accessibilityLabel("Refresh files")
            }

            HStack(spacing: 6) {
                if state.isIndexing {
                    ProgressView()
                        .scaleEffect(0.55)
                        .controlSize(.small)
                        .accessibilityLabel("Indexing files")
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(dracula(.comment))
                    .lineLimit(1)
            }

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(dracula(.orange))
                    .lineLimit(3)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(treeRoots) { node in
                            FileBrowserTreeRow(
                                node: node,
                                depth: 0,
                                selectedRelativePath: selectedRelativePath,
                                expandedFolders: $expandedFolders,
                                fileIconPack: fileIconPack,
                                onSelectFile: onSelectFile,
                                onOpenFile: onOpenFile,
                                onOpenInBrowser: onOpenInBrowser,
                                defaultExternalEditorTool: defaultExternalEditorTool,
                                onOpenExternally: onOpenExternally,
                                onCopyPath: onCopyPath
                            )
                        }
                    } else {
                        ForEach(state.visibleEntries) { entry in
                            FileBrowserSearchRow(
                                entry: entry,
                                isSelected: selectedRelativePath == entry.relativePath,
                                fileIconPack: fileIconPack,
                                onSelectFile: onSelectFile,
                                onOpenFile: onOpenFile,
                                onOpenInBrowser: onOpenInBrowser,
                                defaultExternalEditorTool: defaultExternalEditorTool,
                                onOpenExternally: onOpenExternally,
                                onCopyPath: onCopyPath
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: state.entries) {
                treeRoots = FileBrowserTreeBuilder.roots(from: state.entries)
            }
            .onChange(of: state.rootPath) {
                expandedFolders.removeAll()
                treeRoots = FileBrowserTreeBuilder.roots(from: state.entries)
            }
            .onAppear {
                treeRoots = FileBrowserTreeBuilder.roots(from: state.entries)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var statusText: String {
        guard let metadata = state.metadata else {
            return state.isIndexing ? "Indexing..." : "No index yet"
        }
        let ignored = metadata.ignoredDirectoryCount == 1 ? "1 ignored directory" : "\(metadata.ignoredDirectoryCount) ignored directories"
        return "\(state.visibleEntries.count) of \(metadata.fileCount) items, \(ignored)"
    }

}

private struct FileBrowserTreeRow: View {
    let node: FileBrowserTreeNode
    let depth: Int
    let selectedRelativePath: String?
    @Binding var expandedFolders: Set<String>
    let fileIconPack: FileIconPack
    let onSelectFile: (FileBrowserEntry) -> Void
    let onOpenFile: (FileBrowserEntry) -> Void
    let onOpenInBrowser: (FileBrowserEntry) -> Void
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onSelectFile(node.entry)
                if node.entry.isDirectory {
                    toggleExpanded()
                } else {
                    onOpenFile(node.entry)
                }
            } label: {
                FileBrowserRowContent(
                    entry: node.entry,
                    displayName: node.displayName,
                    depth: depth,
                    fileIconPack: fileIconPack,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            .help(node.entry.isDirectory ? node.entry.relativePath : "Open in nvim")
            .contextMenu {
                externalOpenMenuItems(for: node.entry)
            }
            .background(selectedRelativePath == node.entry.relativePath ? dracula(.currentLine) : dracula(.background))

            if node.entry.isDirectory && isExpanded {
                ForEach(node.children) { child in
                    FileBrowserTreeRow(
                        node: child,
                        depth: depth + 1,
                        selectedRelativePath: selectedRelativePath,
                        expandedFolders: $expandedFolders,
                        fileIconPack: fileIconPack,
                        onSelectFile: onSelectFile,
                        onOpenFile: onOpenFile,
                        onOpenInBrowser: onOpenInBrowser,
                        defaultExternalEditorTool: defaultExternalEditorTool,
                        onOpenExternally: onOpenExternally,
                        onCopyPath: onCopyPath
                    )
                }
            }
        }
    }

    private var isExpanded: Bool {
        expandedFolders.contains(node.entry.relativePath)
    }

    private func toggleExpanded() {
        if isExpanded {
            expandedFolders.remove(node.entry.relativePath)
        } else {
            expandedFolders.insert(node.entry.relativePath)
        }
    }

    @ViewBuilder
    private func externalOpenMenuItems(for entry: FileBrowserEntry) -> some View {
        Button("Copy Relative Path") {
            onCopyPath(entry, .relative)
        }

        Button("Copy Full Path") {
            onCopyPath(entry, .full)
        }

        if !entry.isDirectory {
            if AppModel.isBrowserPreviewSupported(relativePath: entry.relativePath) {
                Button("Open in Browser") {
                    onOpenInBrowser(entry)
                }
            }
        }

        if let defaultExternalEditorTool {
            Button("Open in Default Editor") {
                onOpenExternally(entry, defaultExternalEditorTool)
            }
        }

        if !entry.isDirectory {
            Button("Open in Built-in Editor") {
                onOpenFile(entry)
            }
        }
    }
}

private struct FileBrowserSearchRow: View {
    let entry: FileBrowserEntry
    let isSelected: Bool
    let fileIconPack: FileIconPack
    let onSelectFile: (FileBrowserEntry) -> Void
    let onOpenFile: (FileBrowserEntry) -> Void
    let onOpenInBrowser: (FileBrowserEntry) -> Void
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void

    var body: some View {
        if entry.isDirectory {
            FileBrowserRowContent(
                entry: entry,
                displayName: entry.relativePath,
                depth: 0,
                fileIconPack: fileIconPack,
                isExpanded: false
            )
            .background(isSelected ? dracula(.currentLine) : dracula(.background))
            .onTapGesture {
                onSelectFile(entry)
            }
            .contextMenu {
                fileMenuItems(for: entry)
            }
        } else {
            Button {
                onSelectFile(entry)
                onOpenFile(entry)
            } label: {
                FileBrowserRowContent(
                    entry: entry,
                    displayName: entry.relativePath,
                    depth: 0,
                    fileIconPack: fileIconPack,
                    isExpanded: false
                )
            }
            .buttonStyle(.plain)
            .background(isSelected ? dracula(.currentLine) : dracula(.background))
            .help("Open in nvim")
            .contextMenu {
                fileMenuItems(for: entry)
            }
        }
    }

    @ViewBuilder
    private func fileMenuItems(for entry: FileBrowserEntry) -> some View {
        Button("Copy Relative Path") {
            onCopyPath(entry, .relative)
        }

        Button("Copy Full Path") {
            onCopyPath(entry, .full)
        }

        if !entry.isDirectory, AppModel.isBrowserPreviewSupported(relativePath: entry.relativePath) {
            Button("Open in Browser") {
                onOpenInBrowser(entry)
            }
        }

        if let defaultExternalEditorTool {
            Button("Open in Default Editor") {
                onOpenExternally(entry, defaultExternalEditorTool)
            }
        }

        if !entry.isDirectory {
            Button("Open in Built-in Editor") {
                onOpenFile(entry)
            }
        }
    }
}

private struct FileBrowserRowContent: View {
    let entry: FileBrowserEntry
    let displayName: String
    let depth: Int
    let fileIconPack: FileIconPack
    var isExpanded = false
    @State private var isHovered = false
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        let fileIcon = FileIconResolver(pack: fileIconPack).icon(for: entry, isExpanded: isExpanded)

        HStack(spacing: 6) {
            Image(systemName: (
                isExpanded ? IconRole.disclosureExpanded : IconRole.disclosureCollapsed
            ).icon.systemSymbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(dracula(.comment))
                .frame(width: 12)
                .opacity(entry.isDirectory ? 1 : 0)

            Image(systemName: fileIcon.systemSymbolName)
                .font(.system(size: 13))
                .foregroundStyle(dracula(fileIcon.draculaRole ?? (entry.isDirectory ? .cyan : .purple)))
                .frame(width: 15)

            Text(displayName)
                .font(fonts.interfaceFont(sizeOffset: -1, weight: entry.isDirectory ? .semibold : .regular))
                .foregroundStyle(dracula(.foreground))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? AnyShapeStyle(dracula(.currentLine).opacity(0.45)) : AnyShapeStyle(Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(entry.isDirectory ? "Folder" : "File") \(entry.relativePath)")
    }
}

private struct TerminalPlaceholderView: View {
    let request: TerminalLaunchRequest?
    let unavailableMessage: String
    let fonts: FontSettings
    var onTitleChange: (TerminalRole, String) -> Void = { _, _ in }
    var onDesktopNotification: (TerminalRole, String, String) -> Void = { _, _, _ in }
    var onFocusChange: (TerminalRole, Bool) -> Void = { _, _ in }
    var onClose: (TerminalRole) -> Void = { _ in }
    var onCommandFinished: (TerminalRole, Int?) -> Void = { _, _ in }
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let request {
                GhosttyTerminalSurfaceView(
                    request: request,
                    theme: appTheme,
                    fonts: fonts,
                    onTitleChange: onTitleChange,
                    onDesktopNotification: onDesktopNotification,
                    onFocusChange: onFocusChange,
                    onClose: onClose,
                    onCommandFinished: onCommandFinished
                )
                    .accessibilityLabel("\(request.title) terminal")
            } else {
                Text(unavailableMessage)
                    .font(fonts.editorFont())
                    .foregroundStyle(dracula(.foreground))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
    }
}

private struct BottomTerminalBar: View {
    let isExpanded: Bool
    let request: TerminalLaunchRequest?
    let fonts: FontSettings
    let onToggle: () -> Void
    let onAppearExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack {
                    Text("Bottom Terminal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(dracula(.purple))

                    Spacer()

                    Text(isExpanded ? "Expanded" : "Collapsed")
                        .font(.caption)
                        .foregroundStyle(dracula(.comment))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse bottom terminal" : "Expand bottom terminal")

            if isExpanded {
                TerminalPlaceholderView(
                    request: request,
                    unavailableMessage: "Terminal unavailable for the selected thread",
                    fonts: fonts
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear(perform: onAppearExpanded)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(dracula(.currentLine))
    }
}

private struct CollapsedPanelRail: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        VStack {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.cyan))
            .help(accessibilityLabel)
            .accessibilityLabel(accessibilityLabel)

            Spacer()
        }
        .padding(.vertical, 14)
        .background(dracula(.background))
    }
}

private struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateTitle(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateTitle(from: nsView)
    }

    private func updateTitle(from view: NSView) {
        DispatchQueue.main.async {
            view.window?.title = title
        }
    }
}

func dracula(_ role: ThemeRole) -> AppThemeColor {
    AppThemeColor(role: role)
}

struct AppThemeColor: ShapeStyle {
    let role: ThemeRole

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(hex: environment.appTheme.hex(for: role)).resolve(in: environment)
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ThemeCatalog.defaultTheme
}

private struct FontSettingsEnvironmentKey: EnvironmentKey {
    static let defaultValue = FontSettings()
}

private extension EnvironmentValues {
    var appTheme: ThemeDefinition {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }

    var fontSettings: FontSettings {
        get { self[FontSettingsEnvironmentKey.self] }
        set { self[FontSettingsEnvironmentKey.self] = newValue }
    }
}

private extension FontSettings {
    func interfaceFont(sizeOffset: Double = 0, weight: Font.Weight = .regular) -> Font {
        swiftUIFont(family: interfaceFamily, size: interfaceSize + sizeOffset, weight: weight, design: .default)
    }

    func editorFont(sizeOffset: Double = 0, weight: Font.Weight = .regular) -> Font {
        swiftUIFont(family: editorFamily, size: editorSize + sizeOffset, weight: weight, design: .monospaced)
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

private extension Double {
    var formattedFontSize: String {
        formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

private extension Color {
    init(hex: String) {
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
