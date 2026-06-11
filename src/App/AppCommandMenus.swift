import AppKit
import SwiftUI
import YAAWKit

/// The app's command menus (App / Project / Thread / Right Panel / Files /
/// External Open / Layout / Navigation / Terminal) with their configurable
/// keyboard shortcuts. Store-only verbs route through `AppCommands`; the
/// panel-driven verbs (new project, nvim file picker, external open) live here
/// because they need an `NSOpenPanel` + the `ExternalOpenWorkspace`.
struct AppCommandMenus: Commands {
    let stores: AppStores
    let externalOpenWorkspace: ExternalOpenWorkspace
    let settingsWindowID: String
    @Environment(\.openWindow) private var openWindow

    private var workspace: WorkspaceStore { stores.workspace }
    private var settings: SettingsStore { stores.settings }

    var body: some Commands {
        CommandMenu("App") {
            shortcutButton(.openSettings, "Settings...") {
                openWindow(id: settingsWindowID)
            }
        }

        CommandMenu("Project") {
            shortcutButton(.newProject, "New Project...") { createProjectFromPanel() }
            shortcutButton(.toggleSelectedProjectPinned, "Pin or Unpin Selected Project") {
                workspace.toggleSelectedProjectPinned()
            }
            shortcutButton(.moveSelectedProjectUp, "Move Selected Project Up") {
                workspace.moveSelectedProject(direction: .up)
            }
            shortcutButton(.moveSelectedProjectDown, "Move Selected Project Down") {
                workspace.moveSelectedProject(direction: .down)
            }
            shortcutButton(.toggleSelectedProjectExpanded, "Expand or Collapse Selected Project") {
                workspace.toggleSelectedProjectExpanded()
            }
            shortcutButton(
                .toggleSelectedProjectArchiveExpanded,
                "Expand or Collapse Selected Project Archive"
            ) {
                workspace.toggleSelectedProjectArchiveExpanded()
            }
        }

        CommandMenu("Thread") {
            shortcutButton(.newThread, "New Thread") {
                _ = try? workspace.createThread(agentCLI: nil)
            }
            shortcutButton(.toggleSelectedThreadPinned, "Pin or Unpin Selected Thread") {
                workspace.toggleSelectedThreadPinned()
            }
            shortcutButton(.archiveSelectedThread, "Archive Selected Thread") {
                workspace.archiveSelectedThread()
            }
            shortcutButton(.unarchiveSelectedThread, "Unarchive Selected Thread") {
                workspace.unarchiveSelectedThread()
            }
        }

        CommandMenu("Right Panel") {
            shortcutButton(.previousRightPanelMode, "Previous Right Panel Mode") {
                stores.rightPanel.cycleRightPanelModeBackward()
            }
            shortcutButton(.nextRightPanelMode, "Next Right Panel Mode") {
                stores.rightPanel.cycleRightPanelModeForward()
            }
            shortcutButton(.selectFilesRightPanelMode, "Files") {
                stores.rightPanel.selectRightPanelMode(.files)
            }
            shortcutButton(.selectGitRightPanelMode, "Git") {
                stores.rightPanel.selectRightPanelMode(.git)
            }
            shortcutButton(.selectNvimRightPanelMode, "nvim") {
                stores.rightPanel.selectRightPanelMode(.nvim)
            }
            shortcutButton(.openNvimFilePicker, "Open File in New nvim Tab...") {
                openNvimFileFromPanel()
            }
        }

        CommandMenu("Files") {
            shortcutButton(.refreshFiles, "Refresh Files") {
                stores.activity.refreshSelectedFileBrowser()
            }
            shortcutButton(.openSelectedFileInNvim, "Open Selected File in nvim") {
                stores.rightPanel.openSelectedFileInNvim()
            }
        }

        CommandMenu("External Open") {
            shortcutButton(
                .openSelectedDirectoryExternalDefault, "Open Selected Directory with Default Tool"
            ) {
                openSelectedDirectoryWithDefaultExternalTool()
            }
            ForEach(ExternalOpenToolID.allCases) { tool in
                shortcutButton(
                    directoryAction(for: tool),
                    "Open Selected Directory in \(tool.displayName)"
                ) {
                    openSelectedDirectoryExternally(tool)
                }
            }
            Divider()
            shortcutButton(.openSelectedFileExternalDefault, "Open Selected File with Default Tool")
            {
                openSelectedFileWithDefaultExternalTool()
            }
            ForEach(ExternalOpenToolID.allCases) { tool in
                shortcutButton(fileAction(for: tool), "Open Selected File in \(tool.displayName)") {
                    openSelectedFileExternally(tool)
                }
            }
        }

        CommandMenu("Layout") {
            shortcutButton(.toggleSidebar, "Toggle Sidebar") {
                stores.layout.toggleSidebarCollapsed()
            }
            shortcutButton(.toggleRightPanel, "Toggle Right-Side Area") {
                stores.layout.toggleRightPanelCollapsed()
            }
            shortcutButton(.swapMainAndRightPanels, "Swap Main and Right Panels") {
                stores.layout.toggleWorkspaceSwap()
            }
        }

        CommandMenu("Navigation") {
            shortcutButton(.navigateBack, "Back") { workspace.navigateBack() }
            shortcutButton(.navigateForward, "Forward") { workspace.navigateForward() }
        }

        CommandMenu("Terminal") {
            shortcutButton(.toggleBottomTerminal, "Toggle Bottom Terminal") {
                stores.layout.toggleBottomTerminal()
            }
        }
    }

    // MARK: - Shortcut button

    @ViewBuilder
    private func shortcutButton(
        _ action: KeyboardShortcutAction, _ title: String, perform: @escaping () -> Void
    ) -> some View {
        Button(title, action: perform)
            .keyboardShortcut(shortcut(for: action))
    }

    private func shortcut(for action: KeyboardShortcutAction) -> KeyboardShortcut? {
        guard settings.isKeyboardShortcutEnabled(for: action) else { return nil }
        let definition = settings.keyboardShortcutDefinition(for: action)
        guard let character = definition.key.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: definition.eventModifiers)
    }

    // MARK: - Panel-driven actions

    private func createProjectFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            _ = try? workspace.createProject(displayName: url.lastPathComponent, rootDirectory: url)
        }
    }

    private func openNvimFileFromPanel() {
        guard let root = workspace.selectedThread?.workingDirectory else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url {
            let rootPath = root.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { return }
            stores.rightPanel.openFileInNvim(
                relativePath: String(filePath.dropFirst(rootPath.count + 1)))
        }
    }

    private func openSelectedDirectoryWithDefaultExternalTool() {
        guard
            let tool = externalOpenWorkspace.defaultTool(
                settings: settings.configuration.tools.externalOpen)
        else { return }
        openSelectedDirectoryExternally(tool)
    }

    private func openSelectedDirectoryExternally(_ tool: ExternalOpenToolID) {
        guard let target = workspace.selectedExternalOpenDirectoryTarget else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private func openSelectedFileWithDefaultExternalTool() {
        guard
            let tool = externalOpenWorkspace.defaultTool(
                settings: settings.configuration.tools.externalOpen)
        else { return }
        openSelectedFileExternally(tool)
    }

    private func openSelectedFileExternally(_ tool: ExternalOpenToolID) {
        guard let target = stores.rightPanel.selectedExternalOpenFileTarget else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private func directoryAction(for tool: ExternalOpenToolID) -> KeyboardShortcutAction {
        switch tool {
        case .vscode: .openSelectedDirectoryInVSCode
        case .vscodeInsiders: .openSelectedDirectoryInVSCodeInsiders
        case .sublimeText: .openSelectedDirectoryInSublimeText
        case .zed: .openSelectedDirectoryInZed
        case .finder: .openSelectedDirectoryInFinder
        case .terminal: .openSelectedDirectoryInTerminal
        case .ghostty: .openSelectedDirectoryInGhostty
        case .xcode: .openSelectedDirectoryInXcode
        case .webstorm: .openSelectedDirectoryInWebStorm
        }
    }

    private func fileAction(for tool: ExternalOpenToolID) -> KeyboardShortcutAction {
        switch tool {
        case .vscode: .openSelectedFileInVSCode
        case .vscodeInsiders: .openSelectedFileInVSCodeInsiders
        case .sublimeText: .openSelectedFileInSublimeText
        case .zed: .openSelectedFileInZed
        case .finder: .openSelectedFileInFinder
        case .terminal: .openSelectedFileInTerminal
        case .ghostty: .openSelectedFileInGhostty
        case .xcode: .openSelectedFileInXcode
        case .webstorm: .openSelectedFileInWebStorm
        }
    }
}
