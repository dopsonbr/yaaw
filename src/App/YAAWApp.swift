import AppKit
import Darwin
import SwiftUI
import YAAWKit

@main
struct YAAWApp: App {
    static let settingsWindowID = "yaaw-settings"

    @NSApplicationDelegateAdaptor(YAAWApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @State private var settingsModel: SettingsModel
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
        BundledFontCatalog.registerBundledFonts(diagnosticRecorder: diagnostics)
        var appliedOverrides: [String] = []
        if let pathOverride = environment["\(envPrefix)PATH"] {
            environment["PATH"] = pathOverride
            appliedOverrides.append("\(envPrefix)PATH")
        }
        let databasePath = Self.databasePath(
            environment: environment, envPrefix: envPrefix, applied: &appliedOverrides)
        let configurationPath = Self.configurationPath(
            environment: environment, envPrefix: envPrefix, applied: &appliedOverrides)
        self.databasePath = databasePath
        self.configurationPath = configurationPath
        self.configurationStore = YAMLConfigurationStore(
            path: configurationPath, diagnosticRecorder: diagnostics)
        diagnostics.record(
            DiagnosticEvent(
                category: "Lifecycle",
                name: "env_override_applied",
                metadata: [
                    "prefix": envPrefix,
                    "applied": appliedOverrides.joined(separator: ","),
                ]
            )
        )
        let appModel: AppModel
        do {
            diagnostics.record(DiagnosticEvent(category: "Lifecycle", name: "app_starting"))
            let store = try SQLiteYAAWStore(
                databasePath: databasePath, diagnosticRecorder: diagnostics)
            let configuration = configurationStore.load()
            let externalToolResolver = PATHAgentCLIExecutableResolver(
                fallbackSearchPaths: envPrefix == "YAAW_E2E_"
                    ? []
                    : PATHAgentCLIExecutableResolver.defaultFallbackSearchPaths
            )
            let agentCLIBindings = AgentCLISessionBindingService(
                environment: environment,
                captureDirectory: Self.captureDirectory(
                    environment: environment, envPrefix: envPrefix, applied: &appliedOverrides)
            )
            appModel = AppModel(
                store: store,
                agentCLIBindings: agentCLIBindings,
                externalToolResolver: externalToolResolver,
                configuration: configuration,
                systemAppearanceIsDark: Self.seededSystemAppearanceIsDark(),
                diagnosticRecorder: diagnostics,
                // Headless e2e never activates the app, so the active-app
                // suppression can't kick in and real Notification Center
                // banners (plus the authorization prompt) would fire mid-run.
                notificationDispatcher: environment["YAAW_E2E_HEADLESS"] == "1"
                    ? NoopThreadActivityNotificationDispatcher()
                    : MacSystemThreadActivityNotificationDispatcher.shared,
                badgeUpdater: MacDockThreadActivityBadgeUpdater.shared,
                isApplicationActive: { NSApplication.shared.isActive },
                environment: environment
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
            appModel = AppModel(
                store: InMemoryYAAWStore.helloWorld(),
                systemAppearanceIsDark: Self.seededSystemAppearanceIsDark())
            startupError = error
        }
        _model = StateObject(wrappedValue: appModel)
        _settingsModel = State(
            initialValue: Self.makeSettingsModel(
                configurationStore: configurationStore,
                configurationPath: configurationPath,
                appModel: appModel
            )
        )
    }

    /// Pre-AppKit guess at the system appearance so the first frame renders the
    /// right pairing; the KVO observer corrects it within the first runloop.
    private static func seededSystemAppearanceIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private static func makeSettingsModel(
        configurationStore: YAMLConfigurationStore,
        configurationPath: URL,
        appModel: AppModel
    ) -> SettingsModel {
        SettingsModel(
            dependencies: SettingsModel.Dependencies(
                settingsPath: configurationPath,
                loadText: { try configurationStore.loadText() },
                validateText: { try configurationStore.validate(text: $0) },
                saveText: { text in
                    try configurationStore.saveText(text)
                    let configuration = try configurationStore.validate(text: text)
                    appModel.reloadConfiguration(configuration)
                    return configuration
                },
                openExternal: {
                    try? configurationStore.ensureFileExists()
                    NSWorkspace.shared.open(configurationPath)
                },
                reloadConfiguration: {
                    appModel.reloadConfiguration(configurationStore.load())
                },
                refreshAgentCLIOptions: {
                    appModel.refreshAgentCLIOptionCatalog()
                }
            )
        )
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
                        externalOpenWorkspace: externalOpenWorkspace,
                        onInstallLatestRelease: installLatestRelease
                    )
                }
            }
            .frame(minWidth: 1100, minHeight: 700)
            // Drives NSWindow.appearance so the native titlebar and other
            // window chrome render in the active theme's light/dark style.
            .preferredColorScheme(model.resolvedTheme.swiftUIColorScheme)
            .onAppear {
                if startupError == nil {
                    appDelegate.updateShortcutPreflightModel(model)
                    appDelegate.installSystemAppearanceObserver(for: model)
                }
            }
        }
        .defaultSize(width: 1400, height: 900)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            if startupError == nil {
                CommandMenu("App") {
                    OpenSettingsCommandButton(model: model)
                }

                CommandMenu("Project") {
                    ShortcutCommandButton(
                        model: model, action: .newProject, title: "New Project..."
                    ) {
                        createProjectFromPanel()
                    }

                    ShortcutCommandButton(
                        model: model, action: .toggleSelectedProjectPinned,
                        title: "Pin or Unpin Selected Project"
                    ) {
                        model.toggleSelectedProjectPinned()
                    }

                    ShortcutCommandButton(
                        model: model, action: .moveSelectedProjectUp,
                        title: "Move Selected Project Up"
                    ) {
                        model.moveSelectedProject(direction: .up)
                    }

                    ShortcutCommandButton(
                        model: model, action: .moveSelectedProjectDown,
                        title: "Move Selected Project Down"
                    ) {
                        model.moveSelectedProject(direction: .down)
                    }

                    ShortcutCommandButton(
                        model: model, action: .toggleSelectedProjectExpanded,
                        title: "Expand or Collapse Selected Project"
                    ) {
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
                        _ = try? model.createThread(agentCLI: nil)
                    }

                    ShortcutCommandButton(
                        model: model, action: .toggleSelectedThreadPinned,
                        title: "Pin or Unpin Selected Thread"
                    ) {
                        model.toggleSelectedThreadPinned()
                    }

                    ShortcutCommandButton(
                        model: model, action: .archiveSelectedThread,
                        title: "Archive Selected Thread"
                    ) {
                        model.archiveSelectedThread()
                    }

                    ShortcutCommandButton(
                        model: model, action: .unarchiveSelectedThread,
                        title: "Unarchive Selected Thread"
                    ) {
                        model.unarchiveSelectedThread()
                    }
                }

                CommandMenu("Right Panel") {
                    ShortcutCommandButton(
                        model: model, action: .previousRightPanelMode,
                        title: "Previous Right Panel Mode"
                    ) {
                        model.cycleRightPanelModeBackward()
                    }

                    ShortcutCommandButton(
                        model: model, action: .nextRightPanelMode, title: "Next Right Panel Mode"
                    ) {
                        model.cycleRightPanelModeForward()
                    }

                    ShortcutCommandButton(
                        model: model, action: .selectFilesRightPanelMode, title: "Files"
                    ) {
                        model.selectRightPanelMode(.files)
                    }

                    ShortcutCommandButton(
                        model: model, action: .selectGitRightPanelMode, title: "Git"
                    ) {
                        model.selectRightPanelMode(.git)
                    }

                    ShortcutCommandButton(
                        model: model, action: .selectNvimRightPanelMode, title: "nvim"
                    ) {
                        model.selectRightPanelMode(.nvim)
                    }

                    ShortcutCommandButton(
                        model: model, action: .openNvimFilePicker,
                        title: "Open File in New nvim Tab..."
                    ) {
                        openNvimFileFromPanel()
                    }
                }

                CommandMenu("Files") {
                    ShortcutCommandButton(
                        model: model, action: .refreshFiles, title: "Refresh Files"
                    ) {
                        model.refreshSelectedFileBrowser()
                    }

                    ShortcutCommandButton(
                        model: model, action: .openSelectedFileInNvim,
                        title: "Open Selected File in nvim"
                    ) {
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
                    ShortcutCommandButton(
                        model: model, action: .toggleSidebar, title: "Toggle Sidebar"
                    ) {
                        model.toggleSidebarCollapsed()
                    }

                    ShortcutCommandButton(
                        model: model, action: .toggleRightPanel, title: "Toggle Right-Side Area"
                    ) {
                        model.toggleRightPanelCollapsed()
                    }

                    ShortcutCommandButton(
                        model: model,
                        action: .swapMainAndRightPanels,
                        title: "Swap Main and Right Panels"
                    ) {
                        model.toggleWorkspaceSwap()
                    }
                }

                CommandMenu("Navigation") {
                    ShortcutCommandButton(model: model, action: .navigateBack, title: "Back") {
                        model.navigateBack()
                    }

                    ShortcutCommandButton(model: model, action: .navigateForward, title: "Forward")
                    {
                        model.navigateForward()
                    }
                }

                CommandMenu("Terminal") {
                    ShortcutCommandButton(
                        model: model, action: .toggleBottomTerminal, title: "Toggle Bottom Terminal"
                    ) {
                        model.toggleBottomTerminal()
                    }
                }
            }
        }

        Window("Settings", id: Self.settingsWindowID) {
            if startupError == nil {
                SettingsWindowView(model: settingsModel, appModel: model)
                    .preferredColorScheme(model.resolvedTheme.swiftUIColorScheme)
            }
        }
        .defaultSize(width: 980, height: 680)
        .restorationBehavior(.disabled)
    }

    private func createProjectFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            _ = try? model.createProject(displayName: url.lastPathComponent, rootDirectory: url)
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
        guard
            let tool = externalOpenWorkspace.defaultTool(
                settings: model.configuration.tools.externalOpen)
        else { return }
        openSelectedDirectoryExternally(tool)
    }

    private func openSelectedDirectoryExternally(_ tool: ExternalOpenToolID) {
        guard let target = model.selectedExternalOpenDirectoryTarget else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private func openSelectedFileWithDefaultExternalTool() {
        guard
            let tool = externalOpenWorkspace.defaultTool(
                settings: model.configuration.tools.externalOpen)
        else { return }
        openSelectedFileExternally(tool)
    }

    private func openSelectedFileExternally(_ tool: ExternalOpenToolID) {
        guard let target = model.selectedExternalOpenFileTarget else { return }
        externalOpenWorkspace.open(target: target, with: tool)
    }

    private static func envPrefix() -> String {
        Bundle.main.bundleIdentifier == "dev.dopsonbr.YAAW.E2E" ? "YAAW_E2E_" : "YAAW_"
    }

    private static func databasePath(
        environment: [String: String], envPrefix: String, applied: inout [String]
    ) -> URL {
        let key = "\(envPrefix)DATABASE_PATH"
        if let value = environment[key] {
            applied.append(key)
            return URL(fileURLWithPath: value)
        }
        return SQLiteYAAWStore.defaultDatabasePath()
    }

    private static func configurationPath(
        environment: [String: String], envPrefix: String, applied: inout [String]
    ) -> URL {
        let key = "\(envPrefix)CONFIG_PATH"
        if let value = environment[key] {
            applied.append(key)
            return URL(fileURLWithPath: value)
        }
        return YAMLConfigurationStore.defaultPath()
    }

    private static func captureDirectory(
        environment: [String: String], envPrefix: String, applied: inout [String]
    ) -> URL? {
        let key = "\(envPrefix)CAPTURE_DIRECTORY"
        if let value = environment[key] {
            applied.append(key)
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return AgentCLISessionBindingService.defaultCaptureDirectory()
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

extension AppModel {
    fileprivate func keyEquivalent(for action: KeyboardShortcutAction) -> KeyEquivalent {
        let definition = keyboardShortcutDefinition(for: action)
        guard let character = definition.key.first else {
            return KeyEquivalent(" ")
        }
        return KeyEquivalent(character)
    }

    fileprivate func eventModifiers(for action: KeyboardShortcutAction) -> EventModifiers {
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

@MainActor
private final class YAAWApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private let shortcutPreflightMonitor = AppShortcutPreflightMonitor()
    @MainActor private let systemAppearanceObserver = SystemAppearanceObserver()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Headless e2e runs must never take focus or appear in the Dock; the
        // accessory policy is applied before any window shows to avoid an
        // activation flash.
        if Bundle.main.bundleIdentifier == "dev.dopsonbr.YAAW.E2E",
            ProcessInfo.processInfo.environment["YAAW_E2E_HEADLESS"] == "1"
        {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandlers()
        shortcutPreflightMonitor.installIfNeeded()
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            _ = Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    NSApplication.shared.terminate(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        Darwin.exit(0)
                    }
                }
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    func updateShortcutPreflightModel(_ model: AppModel) {
        shortcutPreflightMonitor.updateModel(model)
    }

    /// Delegate-owned so appearance flips keep flowing to the model even if the
    /// main window closes while the settings window stays open.
    @MainActor
    func installSystemAppearanceObserver(for model: AppModel) {
        systemAppearanceObserver.install { isDark in
            model.updateSystemAppearance(isDark: isDark)
        }
    }
}

private struct OpenSettingsCommandButton: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ShortcutCommandButton(model: model, action: .openSettings, title: "Settings...") {
            openWindow(id: YAAWApp.settingsWindowID)
        }
    }
}

private struct ShortcutCommandButton: View {
    @ObservedObject var model: AppModel
    let action: KeyboardShortcutAction
    let title: String
    let perform: () -> Void

    var body: some View {
        Button(title, action: perform)
            .keyboardShortcut(shortcut)
    }

    private var shortcut: KeyboardShortcut? {
        guard model.isKeyboardShortcutEnabled(for: action) else { return nil }
        return KeyboardShortcut(
            model.keyEquivalent(for: action),
            modifiers: model.eventModifiers(for: action)
        )
    }
}

extension KeyboardShortcutAction {
    fileprivate static func directoryExternalOpenAction(for tool: ExternalOpenToolID)
        -> KeyboardShortcutAction
    {
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

    fileprivate static func fileExternalOpenAction(for tool: ExternalOpenToolID)
        -> KeyboardShortcutAction
    {
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

            Text(
                "The app did not open an in-memory fallback because doing so could hide existing projects or threads."
            )
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
