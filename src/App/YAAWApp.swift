import YAAWKit
import AppKit
import SwiftUI

@main
struct YAAWApp: App {
    @StateObject private var model: AppModel
    @State private var isSettingsOpen = false
    private let startupError: Error?
    private let databasePath: URL
    private let configurationPath: URL
    private let configurationStore: YAMLConfigurationStore
    private let updateInstaller = AppUpdateInstaller.shared
    @MainActor private let externalOpenWorkspace = ExternalOpenWorkspace()

    init() {
        var environment = ProcessInfo.processInfo.environment
        let envPrefix = Self.envPrefix()
        let diagnostics = LoggerDiagnosticEventRecorder.shared
        var appliedOverrides: [String] = []
        if let pathOverride = environment["\(envPrefix)PATH"] {
            environment["PATH"] = pathOverride
            appliedOverrides.append("\(envPrefix)PATH")
        }
        let databasePath = Self.databasePath(environment: environment, envPrefix: envPrefix, applied: &appliedOverrides)
        let configurationPath = Self.configurationPath(environment: environment, envPrefix: envPrefix, applied: &appliedOverrides)
        self.databasePath = databasePath
        self.configurationPath = configurationPath
        self.configurationStore = YAMLConfigurationStore(path: configurationPath, diagnosticRecorder: diagnostics)
        diagnostics.record(
            DiagnosticEvent(
                category: "Lifecycle",
                name: "env_override_applied",
                metadata: [
                    "prefix": envPrefix,
                    "applied": appliedOverrides.joined(separator: ",")
                ]
            )
        )
        do {
            diagnostics.record(DiagnosticEvent(category: "Lifecycle", name: "app_starting"))
            let store = try SQLiteYAAWStore(databasePath: databasePath, diagnosticRecorder: diagnostics)
            let configuration = configurationStore.load()
            let agentCLIBindings = AgentCLISessionBindingService(
                environment: environment,
                captureDirectory: Self.captureDirectory(environment: environment, envPrefix: envPrefix, applied: &appliedOverrides)
            )
            _model = StateObject(
                wrappedValue: AppModel(
                    store: store,
                    agentCLIBindings: agentCLIBindings,
                    configuration: configuration,
                    diagnosticRecorder: diagnostics,
                    notificationDispatcher: MacSystemThreadActivityNotificationDispatcher.shared,
                    badgeUpdater: MacDockThreadActivityBadgeUpdater.shared,
                    isApplicationActive: { NSApplication.shared.isActive },
                    environment: environment
                )
            )
            diagnostics.record(DiagnosticEvent(category: "Lifecycle", name: "app_ready"))
            startupError = nil
        } catch {
            diagnostics.record(
                DiagnosticEvent(
                    category: "Lifecycle",
                    name: "app_startup_failed",
                    metadata: ["error": String(describing: error)]
                )
            )
            _model = StateObject(wrappedValue: AppModel(store: InMemoryYAAWStore.helloWorld()))
            startupError = error
        }
    }

    var body: some Scene {
        WindowGroup("Agent IDE") {
            Group {
                if let startupError {
                    PersistenceStartupFailureView(
                        error: startupError,
                        databasePath: databasePath
                    )
                } else {
                    RootView(
                        model: model,
                        isSettingsOpen: $isSettingsOpen,
                        externalOpenWorkspace: externalOpenWorkspace,
                        settingsPath: configurationPath,
                        onLoadSettingsText: loadSettingsText,
                        onValidateSettingsText: validateSettingsText,
                        onSaveSettingsText: saveSettingsText,
                        onOpenSettingsFile: openSettingsFile,
                        onReloadSettings: reloadSettings,
                        onInstallLatestRelease: installLatestRelease
                    )
                }
            }
            .frame(minWidth: 1100, minHeight: 700)
            .toolbar(removing: .title)
        }
        .defaultSize(width: 1400, height: 900)
        .restorationBehavior(.disabled)
        .commands {
            if startupError == nil {
                CommandMenu("App") {
                    ShortcutCommandButton(model: model, action: .openSettings, title: "Settings...") {
                        isSettingsOpen = true
                    }
                }

                CommandMenu("Project") {
                    ShortcutCommandButton(model: model, action: .newProject, title: "New Project...") {
                        createProjectFromPanel()
                    }

                    ShortcutCommandButton(model: model, action: .toggleSelectedProjectPinned, title: "Pin or Unpin Selected Project") {
                        model.toggleSelectedProjectPinned()
                    }

                    ShortcutCommandButton(model: model, action: .moveSelectedProjectUp, title: "Move Selected Project Up") {
                        model.moveSelectedProject(direction: .up)
                    }

                    ShortcutCommandButton(model: model, action: .moveSelectedProjectDown, title: "Move Selected Project Down") {
                        model.moveSelectedProject(direction: .down)
                    }

                    ShortcutCommandButton(model: model, action: .toggleSelectedProjectExpanded, title: "Expand or Collapse Selected Project") {
                        model.toggleSelectedProjectExpanded()
                    }

                    ShortcutCommandButton(
                        model: model,
                        action: .toggleSelectedProjectArchiveExpanded,
                        title: "Expand or Collapse Selected Project Archive"
                    ) {
                        model.toggleSelectedProjectArchiveExpanded()
                    }
                }

                CommandMenu("Thread") {
                    ShortcutCommandButton(model: model, action: .newThread, title: "New Thread") {
                        try? model.createThread(agentCLI: nil)
                    }

                    ShortcutCommandButton(model: model, action: .toggleSelectedThreadPinned, title: "Pin or Unpin Selected Thread") {
                        model.toggleSelectedThreadPinned()
                    }

                    ShortcutCommandButton(model: model, action: .archiveSelectedThread, title: "Archive Selected Thread") {
                        model.archiveSelectedThread()
                    }

                    ShortcutCommandButton(model: model, action: .unarchiveSelectedThread, title: "Unarchive Selected Thread") {
                        model.unarchiveSelectedThread()
                    }
                }

                CommandMenu("Right Panel") {
                    ShortcutCommandButton(model: model, action: .previousRightPanelMode, title: "Previous Right Panel Mode") {
                        model.cycleRightPanelModeBackward()
                    }

                    ShortcutCommandButton(model: model, action: .nextRightPanelMode, title: "Next Right Panel Mode") {
                        model.cycleRightPanelModeForward()
                    }

                    ShortcutCommandButton(model: model, action: .selectFilesRightPanelMode, title: "Files") {
                        model.selectRightPanelMode(.files)
                    }

                    ShortcutCommandButton(model: model, action: .selectGitRightPanelMode, title: "Git") {
                        model.selectRightPanelMode(.git)
                    }

                    ShortcutCommandButton(model: model, action: .selectNvimRightPanelMode, title: "nvim") {
                        model.selectRightPanelMode(.nvim)
                    }

                    ShortcutCommandButton(model: model, action: .openNvimFilePicker, title: "Open File in New nvim Tab...") {
                        openNvimFileFromPanel()
                    }
                }

                CommandMenu("Files") {
                    ShortcutCommandButton(model: model, action: .refreshFiles, title: "Refresh Files") {
                        model.refreshSelectedFileBrowser()
                    }

                    ShortcutCommandButton(model: model, action: .openSelectedFileInNvim, title: "Open Selected File in nvim") {
                        model.openSelectedFileInNvim()
                    }
                    .disabled(model.selectedExternalOpenFileTarget == nil)
                }

                CommandMenu("External Open") {
                    ShortcutCommandButton(
                        model: model,
                        action: .openSelectedDirectoryExternalDefault,
                        title: "Open Selected Directory with Default Tool"
                    ) {
                        openSelectedDirectoryWithDefaultExternalTool()
                    }
                    .disabled(model.selectedExternalOpenDirectoryTarget == nil)

                    ForEach(ExternalOpenToolID.allCases) { tool in
                        ShortcutCommandButton(
                            model: model,
                            action: KeyboardShortcutAction.directoryExternalOpenAction(for: tool),
                            title: "Open Selected Directory in \(tool.displayName)"
                        ) {
                            openSelectedDirectoryExternally(tool)
                        }
                        .disabled(model.selectedExternalOpenDirectoryTarget == nil)
                    }

                    Divider()

                    ShortcutCommandButton(
                        model: model,
                        action: .openSelectedFileExternalDefault,
                        title: "Open Selected File with Default Tool"
                    ) {
                        openSelectedFileWithDefaultExternalTool()
                    }
                    .disabled(model.selectedExternalOpenFileTarget == nil)

                    ForEach(ExternalOpenToolID.allCases) { tool in
                        ShortcutCommandButton(
                            model: model,
                            action: KeyboardShortcutAction.fileExternalOpenAction(for: tool),
                            title: "Open Selected File in \(tool.displayName)"
                        ) {
                            openSelectedFileExternally(tool)
                        }
                        .disabled(model.selectedExternalOpenFileTarget == nil)
                    }
                }

                CommandMenu("Layout") {
                    ShortcutCommandButton(model: model, action: .toggleSidebar, title: "Toggle Sidebar") {
                        model.toggleSidebarCollapsed()
                    }

                    ShortcutCommandButton(model: model, action: .toggleRightPanel, title: "Toggle Right Panel") {
                        model.toggleRightPanelCollapsed()
                    }
                }

                CommandMenu("Navigation") {
                    ShortcutCommandButton(model: model, action: .navigateBack, title: "Back") {
                        model.navigateBack()
                    }

                    ShortcutCommandButton(model: model, action: .navigateForward, title: "Forward") {
                        model.navigateForward()
                    }
                }

                CommandMenu("Terminal") {
                    ShortcutCommandButton(model: model, action: .toggleBottomTerminal, title: "Toggle Bottom Terminal") {
                        model.toggleBottomTerminal()
                    }
                }
            }
        }
    }

    private func createProjectFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            try? model.createProject(displayName: url.lastPathComponent, rootDirectory: url)
        }
    }

    private func openNvimFileFromPanel() {
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

    private func openSelectedDirectoryWithDefaultExternalTool() {
        guard let tool = externalOpenWorkspace.defaultTool(settings: model.configuration.tools.externalOpen) else { return }
        openSelectedDirectoryExternally(tool)
    }

    private func openSelectedDirectoryExternally(_ tool: ExternalOpenToolID) {
        guard let target = model.selectedExternalOpenDirectoryTarget else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private func openSelectedFileWithDefaultExternalTool() {
        guard let tool = externalOpenWorkspace.defaultTool(settings: model.configuration.tools.externalOpen) else { return }
        openSelectedFileExternally(tool)
    }

    private func openSelectedFileExternally(_ tool: ExternalOpenToolID) {
        guard let target = model.selectedExternalOpenFileTarget else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private static func envPrefix() -> String {
        Bundle.main.bundleIdentifier == "dev.dopsonbr.YAAW.E2E" ? "YAAW_E2E_" : "YAAW_"
    }

    private static func databasePath(environment: [String: String], envPrefix: String, applied: inout [String]) -> URL {
        let key = "\(envPrefix)DATABASE_PATH"
        if let value = environment[key] {
            applied.append(key)
            return URL(fileURLWithPath: value)
        }
        return SQLiteYAAWStore.defaultDatabasePath()
    }

    private static func configurationPath(environment: [String: String], envPrefix: String, applied: inout [String]) -> URL {
        let key = "\(envPrefix)CONFIG_PATH"
        if let value = environment[key] {
            applied.append(key)
            return URL(fileURLWithPath: value)
        }
        return YAMLConfigurationStore.defaultPath()
    }

    private static func captureDirectory(environment: [String: String], envPrefix: String, applied: inout [String]) -> URL? {
        let key = "\(envPrefix)CAPTURE_DIRECTORY"
        if let value = environment[key] {
            applied.append(key)
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return AgentCLISessionBindingService.defaultCaptureDirectory()
    }

    private func openSettingsFile() {
        try? configurationStore.ensureFileExists()
        NSWorkspace.shared.open(configurationPath)
    }

    private func loadSettingsText() throws -> String {
        try configurationStore.loadText()
    }

    private func validateSettingsText(_ text: String) throws -> YAAWConfiguration {
        try configurationStore.validate(text: text)
    }

    @discardableResult
    private func saveSettingsText(_ text: String) throws -> YAAWConfiguration {
        try configurationStore.saveText(text)
        let configuration = try configurationStore.validate(text: text)
        model.reloadConfiguration(configuration)
        return configuration
    }

    private func reloadSettings() {
        model.reloadConfiguration(configurationStore.load())
    }

    private func installLatestRelease() {
        do {
            try updateInstaller.installLatestRelease()
            NSApplication.shared.terminate(nil)
        } catch {
            LoggerDiagnosticEventRecorder.shared.record(
                DiagnosticEvent(
                    category: "Lifecycle",
                    name: "update_install_failed",
                    metadata: ["error": String(describing: error)]
                )
            )
        }
    }
}

private extension AppModel {
    func keyEquivalent(for action: KeyboardShortcutAction) -> KeyEquivalent {
        let definition = keyboardShortcutDefinition(for: action)
        guard let character = definition.key.first else {
            return KeyEquivalent(" ")
        }
        return KeyEquivalent(character)
    }

    func eventModifiers(for action: KeyboardShortcutAction) -> EventModifiers {
        var eventModifiers = EventModifiers()
        for modifier in keyboardShortcutDefinition(for: action).modifiers {
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

private struct ShortcutCommandButton: View {
    @ObservedObject var model: AppModel
    let action: KeyboardShortcutAction
    let title: String
    let perform: () -> Void

    var body: some View {
        commandButton
    }

    @ViewBuilder
    private var commandButton: some View {
        let button = Button(title, action: perform)
        if model.isKeyboardShortcutEnabled(for: action) {
            button.keyboardShortcut(model.keyEquivalent(for: action), modifiers: model.eventModifiers(for: action))
        } else {
            button
        }
    }
}

private extension KeyboardShortcutAction {
    static func directoryExternalOpenAction(for tool: ExternalOpenToolID) -> KeyboardShortcutAction {
        switch tool {
        case .vscode:
            .openSelectedDirectoryInVSCode
        case .vscodeInsiders:
            .openSelectedDirectoryInVSCodeInsiders
        case .sublimeText:
            .openSelectedDirectoryInSublimeText
        case .zed:
            .openSelectedDirectoryInZed
        case .finder:
            .openSelectedDirectoryInFinder
        case .terminal:
            .openSelectedDirectoryInTerminal
        case .ghostty:
            .openSelectedDirectoryInGhostty
        case .xcode:
            .openSelectedDirectoryInXcode
        case .webstorm:
            .openSelectedDirectoryInWebStorm
        }
    }

    static func fileExternalOpenAction(for tool: ExternalOpenToolID) -> KeyboardShortcutAction {
        switch tool {
        case .vscode:
            .openSelectedFileInVSCode
        case .vscodeInsiders:
            .openSelectedFileInVSCodeInsiders
        case .sublimeText:
            .openSelectedFileInSublimeText
        case .zed:
            .openSelectedFileInZed
        case .finder:
            .openSelectedFileInFinder
        case .terminal:
            .openSelectedFileInTerminal
        case .ghostty:
            .openSelectedFileInGhostty
        case .xcode:
            .openSelectedFileInXcode
        case .webstorm:
            .openSelectedFileInWebStorm
        }
    }
}

private struct PersistenceStartupFailureView: View {
    let error: Error
    let databasePath: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Persistence needs attention")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.red))

            Text("The app did not open an in-memory fallback because doing so could hide existing projects or threads.")
                .foregroundStyle(dracula(.foreground))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Database")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.comment))

                Text(databasePath.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(dracula(.cyan))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Error")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.comment))

                Text(String(describing: error))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(dracula(.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
    }
}
