import AppKit
import SwiftUI
import YAAWKit

/// Central dispatch from a `KeyboardShortcutAction` to the store mutations it
/// drives. Shared by the chrome command menus (`YAAWApp`) and the
/// terminal-forwarded shortcut path (`RootView`) so both routes stay in lockstep.
///
/// Panel-driven actions (new project / open nvim file / external open) are NOT
/// handled here — they need an `NSOpenPanel` and the `ExternalOpenWorkspace`, so
/// `YAAWApp` owns them; this dispatches the store-only verbs. The dispatch is
/// split by scope so each switch stays under the complexity ceiling.
enum AppCommands {
    @MainActor
    static func perform(
        _ action: KeyboardShortcutAction,
        stores: AppStores,
        onOpenSettings: () -> Void
    ) {
        switch action.scope {
        case .app:
            if action == .openSettings { onOpenSettings() }
        case .project:
            performProject(action, workspace: stores.workspace)
        case .thread:
            performThread(action, workspace: stores.workspace)
        case .navigation:
            performNavigation(action, workspace: stores.workspace)
        case .rightPanel:
            performRightPanel(action, rightPanel: stores.rightPanel)
        case .files:
            performFiles(action, activity: stores.activity, rightPanel: stores.rightPanel)
        case .layout:
            performLayout(action, layout: stores.layout)
        case .terminal:
            if action == .toggleBottomTerminal { stores.layout.toggleBottomTerminal() }
        case .externalOpen, .settings:
            break  // Panel-driven / settings-window scoped — handled elsewhere.
        }
    }

    @MainActor
    private static func performProject(_ action: KeyboardShortcutAction, workspace: WorkspaceStore)
    {
        switch action {
        case .newThread:
            _ = try? workspace.createThread(agentCLI: nil)
        case .toggleSelectedProjectPinned:
            workspace.toggleSelectedProjectPinned()
        case .moveSelectedProjectUp:
            workspace.moveSelectedProject(direction: .up)
        case .moveSelectedProjectDown:
            workspace.moveSelectedProject(direction: .down)
        case .toggleSelectedProjectExpanded:
            workspace.toggleSelectedProjectExpanded()
        case .toggleSelectedProjectArchiveExpanded:
            workspace.toggleSelectedProjectArchiveExpanded()
        default:
            break
        }
    }

    @MainActor
    private static func performThread(_ action: KeyboardShortcutAction, workspace: WorkspaceStore) {
        switch action {
        case .toggleSelectedThreadPinned:
            workspace.toggleSelectedThreadPinned()
        case .archiveSelectedThread:
            workspace.archiveSelectedThread()
        case .unarchiveSelectedThread:
            workspace.unarchiveSelectedThread()
        default:
            break
        }
    }

    @MainActor
    private static func performNavigation(
        _ action: KeyboardShortcutAction, workspace: WorkspaceStore
    ) {
        switch action {
        case .navigateBack:
            workspace.navigateBack()
        case .navigateForward:
            workspace.navigateForward()
        default:
            break
        }
    }

    @MainActor
    private static func performRightPanel(
        _ action: KeyboardShortcutAction, rightPanel: RightPanelStore
    ) {
        switch action {
        case .previousRightPanelMode:
            rightPanel.cycleRightPanelModeBackward()
        case .nextRightPanelMode:
            rightPanel.cycleRightPanelModeForward()
        case .selectFilesRightPanelMode:
            rightPanel.selectRightPanelMode(.files)
        case .selectGitRightPanelMode:
            rightPanel.selectRightPanelMode(.git)
        case .selectNvimRightPanelMode:
            rightPanel.selectRightPanelMode(.nvim)
        default:
            break
        }
    }

    @MainActor
    private static func performFiles(
        _ action: KeyboardShortcutAction, activity: ActivityStore, rightPanel: RightPanelStore
    ) {
        switch action {
        case .refreshFiles:
            activity.refreshSelectedFileBrowser()
        case .openSelectedFileInNvim:
            rightPanel.openSelectedFileInNvim()
        default:
            break
        }
    }

    @MainActor
    private static func performLayout(_ action: KeyboardShortcutAction, layout: LayoutStore) {
        switch action {
        case .toggleSidebar:
            layout.toggleSidebarCollapsed()
        case .toggleRightPanel:
            layout.toggleRightPanelCollapsed()
        case .swapMainAndRightPanels:
            layout.toggleWorkspaceSwap()
        default:
            break
        }
    }
}
